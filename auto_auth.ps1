# ============================================================
# AC Portal Auto Authentication System v3
# Features: Auto Login + Heartbeat + Disconnect Detection + Reconnect
# ============================================================

param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Once
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $ScriptDir "config.json"

# ---- Load Config ----
function Load-Config {
    if (-not (Test-Path $ConfigPath)) {
        Write-Log "ERROR" "Config file not found: $ConfigPath"
        exit 1
    }
    $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    if ([string]::IsNullOrEmpty($cfg.password)) {
        Write-Log "ERROR" "Password not set in config.json"
        exit 1
    }
    return $cfg
}

# ---- Logger ----
function Write-Log {
    param([string]$Level, [string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Write-Host $line -ForegroundColor $(
        switch ($Level) {
            "ERROR" { "Red" }
            "WARN"  { "Yellow" }
            "OK"    { "Green" }
            "INFO"  { "Cyan" }
            default { "White" }
        }
    )
    $logFile = Join-Path $ScriptDir "auth_log.txt"
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}

# ---- Ping Portal Server ----
function Test-PingAlive {
    try {
        return Test-Connection -ComputerName "192.168.64.21" -Count 1 -Quiet -TimeoutSeconds 2
    }
    catch { return $false }
}

# ---- HTTP Auth Check (multi-URL probe) ----
function Test-InternetAlive {
    $testUrls = @(
        "https://www.qq.com",
        "https://www.baidu.com"
    )
    foreach ($url in $testUrls) {
        try {
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5 -MaximumRedirection 0 -ErrorAction SilentlyContinue
            if ($resp.StatusCode -in @(200, 204)) {
                return $true
            }
        }
        catch {
            if ($_.Exception.Response.StatusCode.value__ -in @(301, 302, 303, 307, 308)) {
                return $false
            }
            continue
        }
    }
    return $false
}

# ---- Login ----
function Invoke-Login {
    param($Config)
    $loginUrl = "$($Config.portal_url)$($Config.login_path)"
    $body = @{
        opr      = "pwdLogin"
        userName = $Config.username
        pwd      = $Config.password
    }
    try {
        $resp = Invoke-WebRequest -Uri $loginUrl -Method POST -Body $body -UseBasicParsing -TimeoutSec 10
        $json = $resp.Content | ConvertFrom-Json
        if ($json.success -eq $true -or $json.success -eq "true") {
            Write-Log "OK" "Login success! User: $($json.userName)"
            Start-Sleep -Seconds 3
            return $true
        }
        else {
            Write-Log "WARN" "Login failed: $($json.msg)"
            return $false
        }
    }
    catch {
        Write-Log "ERROR" "Login request error: $($_.Exception.Message)"
        return $false
    }
}

# ---- Heartbeat ----
function Send-Heartbeat {
    param($Config)
    $hbUrl = "$($Config.portal_url)$($Config.heartbeat_path)"
    try {
        $null = Invoke-WebRequest -Uri $hbUrl -UseBasicParsing -TimeoutSec 5
        return $true
    }
    catch { return $false }
}

# ---- Wait for Network Recovery ----
function Wait-NetworkBack {
    param([int]$MaxWait = 300)
    $waited = 0
    $interval = 3
    while ($waited -lt $MaxWait) {
        if (Test-PingAlive) {
            Write-Log "OK" "Network recovered (waited ${waited}s)"
            return $true
        }
        Start-Sleep -Seconds $interval
        $waited += $interval
    }
    Write-Log "ERROR" "Network recovery timeout (${MaxWait}s)"
    return $false
}

# ---- Install/Uninstall Scheduled Task ----
function Install-AutoStart {
    $taskName = "XuanwuNetworkAuth"
    $scriptPath = $MyInvocation.MyCommand.Path
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Description "Xuanwu Hospital Network Auto Auth" -Force
    Write-Log "OK" "Installed scheduled task: $taskName"
}

function Uninstall-AutoStart {
    $taskName = "XuanwuNetworkAuth"
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Log "OK" "Uninstalled scheduled task: $taskName"
}

# ============================================================
# Main Loop
# ============================================================
function Main {
    if ($Install) { Install-AutoStart; return }
    if ($Uninstall) { Uninstall-AutoStart; return }

    $Config = Load-Config
    Write-Log "OK" "===== Auto Auth System v3 Started ====="
    Write-Log "OK" "User: $($Config.username)"
    Write-Log "OK" "Portal: $($Config.portal_url)"
    Write-Log "OK" "Heartbeat interval: $($Config.heartbeat_interval_sec)s"
    Write-Log "INFO" "----------------------------------------"

    $retryCount = 0
    $lastHeartbeat = [datetime]::MinValue
    $lastHttpCheck = [datetime]::MinValue
    $lastLoginTime = [datetime]::MinValue
    $isAuthenticated = $false

    if ($Once) {
        $inetOk = Test-InternetAlive
        if ($inetOk) {
            Write-Log "OK" "Already authenticated"
        }
        else {
            Invoke-Login -Config $Config
        }
        return
    }

    while ($true) {
        try {
            $now = Get-Date

            # Layer 1: Ping check (every 5s)
            $pingOk = Test-PingAlive
            if (-not $pingOk) {
                if ($isAuthenticated) {
                    Write-Log "WARN" "Network down! (Ping failed)"
                    $isAuthenticated = $false
                }
                $backOk = Wait-NetworkBack
                if ($backOk) {
                    Write-Log "INFO" "Network back, authenticating..."
                    $success = Invoke-Login -Config $Config
                    if ($success) {
                        $isAuthenticated = $true
                        $lastHeartbeat = Get-Date
                        $lastHttpCheck = Get-Date
                        $lastLoginTime = Get-Date
                        $retryCount = 0
                    }
                }
                Start-Sleep -Seconds 3
                continue
            }

            # Layer 2: HTTP auth check (every 30s)
            $httpElapsed = ($now - $lastHttpCheck).TotalSeconds
            $loginCooldown = ($now - $lastLoginTime).TotalSeconds

            if ($httpElapsed -ge $Config.check_interval_sec) {
                $lastHttpCheck = Get-Date

                # Skip check within 60s after login
                if ($loginCooldown -lt 60) {
                    $remain = [int](60 - $loginCooldown)
                    Write-Log "INFO" "Login cooldown (${remain}s left), skip check"
                    $isAuthenticated = $true
                }
                else {
                    $inetOk = Test-InternetAlive
                    if (-not $inetOk) {
                        $isAuthenticated = $false
                        $retryCount++
                        Write-Log "WARN" "No internet, authenticating (attempt $retryCount)"

                        if ($retryCount -gt 1) {
                            $waitSec = [Math]::Min(60, [Math]::Pow(2, $retryCount - 1) * 5)
                            Write-Log "INFO" "Waiting ${waitSec}s before retry..."
                            Start-Sleep -Seconds $waitSec
                        }

                        $success = Invoke-Login -Config $Config
                        if ($success) {
                            $isAuthenticated = $true
                            $lastHeartbeat = Get-Date
                            $lastLoginTime = Get-Date
                            $retryCount = 0
                        }
                    }
                    else {
                        if (-not $isAuthenticated) {
                            Write-Log "OK" "Authenticated, internet OK"
                        }
                        $isAuthenticated = $true
                        $retryCount = 0
                    }
                }
            }

            # Layer 3: Heartbeat (every 3 min)
            if ($isAuthenticated) {
                $hbElapsed = ($now - $lastHeartbeat).TotalSeconds
                if ($hbElapsed -ge $Config.heartbeat_interval_sec) {
                    $hbOk = Send-Heartbeat -Config $Config
                    if ($hbOk) {
                        Write-Log "OK" "Heartbeat OK"
                        $lastHeartbeat = Get-Date
                    }
                    else {
                        Write-Log "WARN" "Heartbeat failed, re-checking auth"
                        $isAuthenticated = $false
                        $inetOk = Test-InternetAlive
                        if (-not $inetOk) {
                            Invoke-Login -Config $Config | Out-Null
                            $isAuthenticated = $true
                            $lastHeartbeat = Get-Date
                            $lastLoginTime = Get-Date
                        }
                    }
                }
            }
        }
        catch {
            Write-Log "ERROR" "Main loop error: $($_.Exception.Message)"
            $retryCount++
        }

        Start-Sleep -Seconds 5
    }
}

Main
