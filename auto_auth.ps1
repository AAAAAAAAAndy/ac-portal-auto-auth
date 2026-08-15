# ============================================================
# 宣武医院网络自动认证系统 v3
# 功能: 自动登录 + 心跳保活 + 断网检测 + 断线重连
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

# ---- 单实例检测 ----
function Test-SingleInstance {
    if ($Once -or $Install -or $Uninstall) { return $true }
    if (Test-Path $LockFile) {
        $lockPid = Get-Content $LockFile -ErrorAction SilentlyContinue
        $proc = Get-Process -Id $lockPid -ErrorAction SilentlyContinue
        if ($proc) {
            Write-Host "[WARN] 已有实例运行中 (PID: $lockPid)，退出" -ForegroundColor Yellow
            return $false
        }
    }
    $PID | Set-Content $LockFile -Force
    return $true
}

function Remove-Lock {
    if (Test-Path $LockFile) { Remove-Item $LockFile -Force -ErrorAction SilentlyContinue }
}

# ---- 加载配置 ----
function Load-Config {
    if (-not (Test-Path $ConfigPath)) {
        Write-Log "ERROR" "配置文件不存在: $ConfigPath"
        exit 1
    }
    $cfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]::IsNullOrEmpty($cfg.password)) {
        Write-Log "ERROR" "密码未配置，请在 config.json 中填写 password"
        exit 1
    }
    return $cfg
}

# ---- 日志 ----
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

# ---- Ping 认证服务器 ----
function Test-PingAlive {
    try {
        return Test-Connection -ComputerName "192.168.64.21" -Count 1 -Quiet -TimeoutSeconds 2
    }
    catch { return $false }
}

# ---- HTTPS 外网检测 ----
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

# ---- 登录 ----
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
            Write-Log "OK" "登录成功! 用户: $($json.userName)"
            Start-Sleep -Seconds 3
            return $true
        }
        else {
            Write-Log "WARN" "登录失败: $($json.msg)"
            return $false
        }
    }
    catch {
        Write-Log "ERROR" "登录异常: $($_.Exception.Message)"
        return $false
    }
}

# ---- 心跳保活 ----
function Send-Heartbeat {
    param($Config)
    $hbUrl = "$($Config.portal_url)$($Config.heartbeat_path)"
    try {
        $null = Invoke-WebRequest -Uri $hbUrl -UseBasicParsing -TimeoutSec 5
        return $true
    }
    catch { return $false }
}

# ---- 等待网络恢复 ----
function Wait-NetworkBack {
    param([int]$MaxWait = 60)
    $waited = 0
    $interval = 3
    while ($waited -lt $MaxWait) {
        if (Test-PingAlive) {
            Write-Log "OK" "网络恢复连通 (等待了${waited}秒)"
            return $true
        }
        Start-Sleep -Seconds $interval
        $waited += $interval
    }
    Write-Log "WARN" "等待网络恢复超时 (${MaxWait}秒)，下轮重试"
    return $false
}

# ---- 安装/卸载开机自启 ----
function Install-AutoStart {
    $taskName = "WUxuan"
    $scriptPath = $MyInvocation.MyCommand.Path
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Description "宣武医院网络自动认证" -Force
    Write-Log "OK" "已安装开机自启任务: $taskName"
}

function Uninstall-AutoStart {
    $taskName = "WUxuan"
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Lock
    Write-Log "OK" "已卸载开机自启任务: $taskName"
}

# ============================================================
# 主循环
# ============================================================
function Main {
    if ($Install) { Install-AutoStart; return }
    if ($Uninstall) { Uninstall-AutoStart; return }

    if (-not (Test-SingleInstance)) { return }

    try {
        $Config = Load-Config
        Write-Log "OK" "===== 自动认证系统 v3 启动 (PID: $PID) ====="
        Write-Log "OK" "用户: $($Config.username)"
        Write-Log "OK" "认证服务器: $($Config.portal_url)"
        Write-Log "OK" "心跳间隔: $($Config.heartbeat_interval_sec)秒"
        Write-Log "INFO" "----------------------------------------"

        $retryCount = 0
        $lastHeartbeat = [datetime]::MinValue
        $lastHttpCheck = [datetime]::MinValue
        $lastLoginTime = [datetime]::MinValue
        $isAuthenticated = $false

        # 单次模式
        if ($Once) {
            $inetOk = Test-InternetAlive
            if ($inetOk) {
                Write-Log "OK" "网络已认证，无需重复登录"
            }
            else {
                Invoke-Login -Config $Config
            }
            return
        }

        # 持续监控模式
        while ($true) {
            try {
                $now = Get-Date

                # ── 第1层: Ping 检测 (每5秒) ──
                $pingOk = Test-PingAlive
                if (-not $pingOk) {
                    if ($isAuthenticated) {
                        Write-Log "WARN" "检测到断网! (Ping 失败)"
                        $isAuthenticated = $false
                    }
                    $backOk = Wait-NetworkBack
                    if ($backOk) {
                        Write-Log "INFO" "网络恢复，立即认证..."
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

                # ── 第2层: HTTPS 认证检测 (每30秒) ──
                $httpElapsed = ($now - $lastHttpCheck).TotalSeconds
                $loginCooldown = ($now - $lastLoginTime).TotalSeconds

                if ($httpElapsed -ge $Config.check_interval_sec) {
                    $lastHttpCheck = Get-Date

                    # 登录后60秒内跳过检测
                    if ($loginCooldown -lt 60) {
                        $remain = [int](60 - $loginCooldown)
                        Write-Log "INFO" "登录冷却中 (${remain}秒)，跳过检测"
                        $isAuthenticated = $true
                    }
                    else {
                        $inetOk = Test-InternetAlive
                        if (-not $inetOk) {
                            $isAuthenticated = $false
                            $retryCount++
                            Write-Log "WARN" "外网不通，尝试认证 (第${retryCount}次)"

                            if ($retryCount -gt 1) {
                                $waitSec = [Math]::Min(60, [Math]::Pow(2, $retryCount - 1) * 5)
                                Write-Log "INFO" "等待 ${waitSec} 秒后重试..."
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
                                Write-Log "OK" "网络已认证，外网连通"
                            }
                            $isAuthenticated = $true
                            $retryCount = 0
                        }
                    }
                }

                # ── 第3层: 心跳保活 (每3分钟) ──
                if ($isAuthenticated) {
                    $hbElapsed = ($now - $lastHeartbeat).TotalSeconds
                    if ($hbElapsed -ge $Config.heartbeat_interval_sec) {
                        $hbOk = Send-Heartbeat -Config $Config
                        if ($hbOk) {
                            Write-Log "OK" "心跳保活成功"
                            $lastHeartbeat = Get-Date
                        }
                        else {
                            Write-Log "WARN" "心跳失败，重新检测认证状态"
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
                Write-Log "ERROR" "主循环异常: $($_.Exception.Message)"
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
