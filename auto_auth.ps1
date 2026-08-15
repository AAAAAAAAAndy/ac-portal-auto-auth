# ============================================================
# 宣武医院网络自动认证系统 v2
# 功能: 自动登录 + 心跳保活 + 断网检测 + 断线重连
# ============================================================

param(
    [switch]$Install,   # 安装为开机自启任务
    [switch]$Uninstall, # 卸载自启任务
    [switch]$Once       # 只执行一次登录，不循环
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $ScriptDir "config.json"

# ---- 加载配置 ----
function Load-Config {
    if (-not (Test-Path $ConfigPath)) {
        Write-Log "ERROR" "配置文件不存在: $ConfigPath"
        exit 1
    }
    $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    if ([string]::IsNullOrEmpty($cfg.password)) {
        Write-Log "ERROR" "密码未配置，请在 config.json 中填写 password 字段"
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
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}

# ---- 检测1: Ping 网关/认证服务器（快速，不依赖外网）----
function Test-PingAlive {
    try {
        $result = Test-Connection -ComputerName "192.168.64.21" -Count 1 -Quiet -TimeoutSeconds 2
        return $result
    }
    catch {
        return $false
    }
}

# ---- 检测2: HTTP 外网连通性（判断是否真正通过认证）----
function Test-InternetAlive {
    param([string]$TestUrl)
    try {
        $resp = Invoke-WebRequest -Uri $TestUrl -UseBasicParsing -TimeoutSec 5 -MaximumRedirection 0 -ErrorAction SilentlyContinue
        return $true
    }
    catch {
        if ($_.Exception.Response.StatusCode.value__ -in @(301, 302, 303, 307, 308)) {
            # 被重定向到认证页面 = 需要认证
            return $false
        }
        return $false
    }
}

# ---- 综合断网检测 ----
function Test-NetworkStatus {
    <#
    返回值:
      "online"       - 网络正常，已认证
      "need_auth"    - 能ping通网关但需要认证
      "offline"      - 完全断网（ping不通）
    #>
    param([string]$TestUrl)

    # 第一步: Ping 认证服务器
    $pingOk = Test-PingAlive
    if (-not $pingOk) {
        return "offline"
    }

    # 第二步: 检测外网是否通
    $inetOk = Test-InternetAlive -TestUrl $TestUrl
    if ($inetOk) {
        return "online"
    }
    else {
        return "need_auth"
    }
}

# ---- 执行登录 ----
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
            return $true
        }
        else {
            Write-Log "WARN" "登录失败: $($json.msg)"
            return $false
        }
    }
    catch {
        Write-Log "ERROR" "登录请求异常: $($_.Exception.Message)"
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
    catch {
        return $false
    }
}

# ---- 等待网络恢复（断网时用）----
function Wait-NetworkBack {
    param([string]$PortalUrl, [int]$MaxWait = 300)
    $waited = 0
    $interval = 3
    while ($waited -lt $MaxWait) {
        $pingOk = Test-PingAlive
        if ($pingOk) {
            Write-Log "OK" "网络恢复连通 (等待了${waited}秒)"
            return $true
        }
        Start-Sleep -Seconds $interval
        $waited += $interval
    }
    Write-Log "ERROR" "等待网络恢复超时 (${MaxWait}秒)"
    return $false
}

# ---- 安装/卸载开机自启 ----
function Install-AutoStart {
    $taskName = "XuanwuNetworkAuth"
    $scriptPath = $MyInvocation.MyCommand.Path
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Description "宣武医院网络自动认证" -Force
    Write-Log "OK" "已安装开机自启任务: $taskName"
}

function Uninstall-AutoStart {
    $taskName = "XuanwuNetworkAuth"
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Log "OK" "已卸载开机自启任务: $taskName"
}

# ============================================================
# 主循环 - 三层检测架构
# ============================================================
function Main {
    # 处理安装/卸载参数
    if ($Install) { Install-AutoStart; return }
    if ($Uninstall) { Uninstall-AutoStart; return }

    $Config = Load-Config
    Write-Log "OK" "===== 自动认证系统 v2 启动 ====="
    Write-Log "OK" "用户: $($Config.username)"
    Write-Log "OK" "认证服务器: $($Config.portal_url)"
    Write-Log "OK" "心跳间隔: $($Config.heartbeat_interval_sec)秒"
    Write-Log "OK" "检测策略: Ping(5秒) + HTTP(30秒) + 心跳($($Config.heartbeat_interval_sec)秒)"
    Write-Log "INFO" "----------------------------------------"

    $retryCount = 0
    $lastHeartbeat = [datetime]::MinValue
    $lastHttpCheck = [datetime]::MinValue
    $isAuthenticated = $false
    $consecutiveFail = 0

    # 单次模式
    if ($Once) {
        $status = Test-NetworkStatus -TestUrl $Config.test_url
        if ($status -eq "online") {
            Write-Log "OK" "网络已认证，无需重复登录"
        }
        else {
            Invoke-Login -Config $Config
        }
        return
    }

    # ========== 持续监控模式 ==========
    while ($true) {
        try {
            $now = Get-Date

            # ──────────────────────────────────────
            # 第1层: 快速 Ping 检测 (每5秒)
            # 检测到断网时立即进入等待恢复流程
            # ──────────────────────────────────────
            $pingOk = Test-PingAlive

            if (-not $pingOk) {
                # Ping 失败 = 完全断网
                if ($isAuthenticated) {
                    Write-Log "WARN" "检测到断网! (Ping 认证服务器失败)"
                    $isAuthenticated = $false
                    $consecutiveFail++
                }

                # 等待网络恢复
                $backOk = Wait-NetworkBack -PortalUrl $Config.portal_url
                if ($backOk) {
                    # 网络恢复后立即尝试认证
                    Write-Log "INFO" "网络恢复，立即尝试认证..."
                    $success = Invoke-Login -Config $Config
                    if ($success) {
                        $isAuthenticated = $true
                        $lastHeartbeat = Get-Date
                        $lastHttpCheck = Get-Date
                        $retryCount = 0
                        $consecutiveFail = 0
                    }
                }
                # 不管成功与否，短暂等待后继续循环
                Start-Sleep -Seconds 3
                continue
            }

            # Ping 通了，网络物理层正常
            # ──────────────────────────────────────
            # 第2层: HTTP 认证状态检测 (每30秒)
            # 判断是否需要重新认证
            # ──────────────────────────────────────
            $httpElapsed = ($now - $lastHttpCheck).TotalSeconds
            if ($httpElapsed -ge $Config.check_interval_sec) {
                $inetOk = Test-InternetAlive -TestUrl $Config.test_url
                $lastHttpCheck = Get-Date

                if (-not $inetOk) {
                    # 能 Ping 通但外网不通 = 需要认证
                    $isAuthenticated = $false
                    $consecutiveFail++
                    Write-Log "WARN" "外网不通，需要认证 (连续失败: $consecutiveFail 次)"

                    $success = Invoke-Login -Config $Config
                    if ($success) {
                        $isAuthenticated = $true
                        $lastHeartbeat = Get-Date
                        $retryCount = 0
                        $consecutiveFail = 0
                    }
                    else {
                        $retryCount++
                        $waitSec = [Math]::Min(60, [Math]::Pow(2, $retryCount) * 2)
                        Write-Log "WARN" "登录失败，${waitSec}秒后重试"
                        Start-Sleep -Seconds $waitSec
                        continue
                    }
                }
                else {
                    # 一切正常
                    if (-not $isAuthenticated) {
                        Write-Log "OK" "网络已认证，外网连通"
                        $isAuthenticated = $true
                    }
                    $consecutiveFail = 0
                }
            }

            # ──────────────────────────────────────
            # 第3层: 心跳保活 (每3分钟)
            # 保持认证会话不过期
            # ──────────────────────────────────────
            if ($isAuthenticated) {
                $hbElapsed = ($now - $lastHeartbeat).TotalSeconds
                if ($hbElapsed -ge $Config.heartbeat_interval_sec) {
                    $hbOk = Send-Heartbeat -Config $Config
                    if ($hbOk) {
                        Write-Log "OK" "心跳保活成功"
                        $lastHeartbeat = Get-Date
                    }
                    else {
                        Write-Log "WARN" "心跳失败，可能已掉线，立即重新检测"
                        $isAuthenticated = $false
                        # 心跳失败后不等下一轮，立即检测
                        $inetOk = Test-InternetAlive -TestUrl $Config.test_url
                        if (-not $inetOk) {
                            Invoke-Login -Config $Config | Out-Null
                            $isAuthenticated = $true
                            $lastHeartbeat = Get-Date
                        }
                    }
                }
            }

            $retryCount = 0
        }
        catch {
            Write-Log "ERROR" "主循环异常: $($_.Exception.Message)"
            $retryCount++
        }

        # 快速 Ping 间隔: 5秒
        Start-Sleep -Seconds 5
    }
}

# 运行
Main
