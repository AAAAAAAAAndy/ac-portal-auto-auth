# ============================================================
# ?????????????????? v3
# ????: ?????? + ???????? + ??????? + ????????
# ============================================================

param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Once
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $ScriptDir "config.json"
$LockFile = Join-Path $ScriptDir ".lock"

function Test-SingleInstance {
    if ($Once -or $Install -or $Uninstall) { return $true }
    if (Test-Path $LockFile) {
        $lockPid = Get-Content $LockFile -ErrorAction SilentlyContinue
        $proc = Get-Process -Id $lockPid -ErrorAction SilentlyContinue
        if ($proc) {
            Write-Host "[WARN] ????????????? (PID: $lockPid)?????" -ForegroundColor Yellow
            return $false
        }
    }
    $PID | Set-Content $LockFile -Force
    return $true
}

function Remove-Lock {
    if (Test-Path $LockFile) { Remove-Item $LockFile -Force -ErrorAction SilentlyContinue }
}

function Load-Config {
    if (-not (Test-Path $ConfigPath)) {
        Write-Log "ERROR" "?????????????: $ConfigPath"
        exit 1
    }
    $cfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]::IsNullOrEmpty($cfg.password)) {
        Write-Log "ERROR" "????¦Ä????"
        exit 1
    }
    return $cfg
}

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
    [System.IO.File]::AppendAllText($logFile, "$line`r`n", [System.Text.Encoding]::GetEncoding("GBK"))
}

function Test-PingAlive {
    try {
        return Test-Connection -ComputerName "192.168.64.21" -Count 1 -Quiet -TimeoutSeconds 2
    }
    catch { return $false }
}

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
            Write-Log "OK" "??????! ???: $($json.userName)"
            Start-Sleep -Seconds 3
            return $true
        }
        else {
            Write-Log "WARN" "??????: $($json.msg)"
            return $false
        }
    }
    catch {
        Write-Log "ERROR" "?????: $($_.Exception.Message)"
        return $false
    }
}

function Send-Heartbeat {
    param($Config)
    $hbUrl = "$($Config.portal_url)$($Config.heartbeat_path)"
    try {
        $null = Invoke-WebRequest -Uri $hbUrl -UseBasicParsing -TimeoutSec 5
        return $true
    }
    catch { return $false }
}

function Wait-NetworkBack {
    param([int]$MaxWait = 60)
    $waited = 0
    $interval = 3
    while ($waited -lt $MaxWait) {
        if (Test-PingAlive) {
            Write-Log "OK" "????????? (?????${waited}??)"
            return $true
        }
        Start-Sleep -Seconds $interval
        $waited += $interval
    }
    Write-Log "WARN" "????????????, ????????"
    return $false
}

function Install-AutoStart {
    $taskName = "WuxuanNetworkAuth"
    $scriptPath = $MyInvocation.MyCommand.Path
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Description "????????????????" -Force
    Write-Log "OK" "????????????????: $taskName"
}

function Uninstall-AutoStart {
    $taskName = "WuxuanNetworkAuth"
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Lock
    Write-Log "OK" "??§Ø?????????????: $taskName"
}

function Main {
    if ($Install) { Install-AutoStart; return }
    if ($Uninstall) { Uninstall-AutoStart; return }

    if (-not (Test-SingleInstance)) { return }

    try {
        $Config = Load-Config
        Write-Log "OK" "===== ???????? v3 ???? (PID: $PID) ====="
        Write-Log "OK" "???: $($Config.username)"
        Write-Log "OK" "?????????: $($Config.portal_url)"
        Write-Log "OK" "???????: $($Config.heartbeat_interval_sec)??"
        Write-Log "INFO" "----------------------------------------"

        $retryCount = 0
        $lastHeartbeat = [datetime]::MinValue
        $lastHttpCheck = [datetime]::MinValue
        $lastLoginTime = [datetime]::MinValue
        $isAuthenticated = $false

        if ($Once) {
            $inetOk = Test-InternetAlive
            if ($inetOk) {
                Write-Log "OK" "?????????????????????"
            }
            else {
                Invoke-Login -Config $Config
            }
            return
        }

        while ($true) {
            try {
                $now = Get-Date

                # Ping ??? (?5??)
                $pingOk = Test-PingAlive
                if (-not $pingOk) {
                    if ($isAuthenticated) {
                        Write-Log "WARN" "???????! (Ping ???)"
                        $isAuthenticated = $false
                    }
                    $backOk = Wait-NetworkBack
                    if ($backOk) {
                        Write-Log "INFO" "???????????????..."
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

                # HTTPS ?????? (?30??)
                $httpElapsed = ($now - $lastHttpCheck).TotalSeconds
                $loginCooldown = ($now - $lastLoginTime).TotalSeconds

                if ($httpElapsed -ge $Config.check_interval_sec) {
                    $lastHttpCheck = Get-Date

                    if ($loginCooldown -lt 60) {
                        $remain = [int](60 - $loginCooldown)
                        Write-Log "INFO" "????????, ???????"
                        $isAuthenticated = $true
                    }
                    else {
                        $inetOk = Test-InternetAlive
                        if (-not $inetOk) {
                            $isAuthenticated = $false
                            $retryCount++
                            Write-Log "WARN" "???????????????? (??${retryCount}??)"

                            if ($retryCount -gt 1) {
                                $waitSec = [Math]::Min(60, [Math]::Pow(2, $retryCount - 1) * 5)
                                Write-Log "INFO" "???${waitSec}???????..."
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
                                Write-Log "OK" "??????????????????"
                            }
                            $isAuthenticated = $true
                            $retryCount = 0
                        }
                    }
                }

                # ???????? (?3????)
                if ($isAuthenticated) {
                    $hbElapsed = ($now - $lastHeartbeat).TotalSeconds
                    if ($hbElapsed -ge $Config.heartbeat_interval_sec) {
                        $hbOk = Send-Heartbeat -Config $Config
                        if ($hbOk) {
                            Write-Log "OK" "??????????"
                            $lastHeartbeat = Get-Date
                        }
                        else {
                            Write-Log "WARN" "???????????????????"
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
                Write-Log "ERROR" "???????: $($_.Exception.Message)"
                $retryCount++
            }

            Start-Sleep -Seconds 5
        }
    }
    finally {
        Remove-Lock
    }
}

Main
