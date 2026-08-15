# AC Portal Auto Authentication System

宣武医院网络自动认证系统 — 自动登录 + 心跳保活 + 断网检测 + 断线重连

## 功能特性

| 功能 | 说明 |
|------|------|
| 自动登录 | 检测到未认证时自动提交账号密码登录 |
| 心跳保活 | 每 3 分钟发送心跳，防止 2 小时超时断线 |
| 断网检测 | 三层检测架构：Ping → HTTP → 心跳 |
| 断线重连 | 网络断开后自动等待恢复并重新认证 |
| 登录冷却 | 登录后 60 秒内跳过检测，防止重复登录 |
| 指数退避 | 登录失败时 5s → 10s → 20s → 40s → 60s 递增重试 |
| 开机自启 | 支持安装为 Windows 计划任务，后台静默运行 |
| 日志记录 | 控制台彩色输出 + auth_log.txt 文件日志 |

## 三层检测架构

```
Layer 1: Ping (every 5s)
  Ping portal server 192.168.64.21
  fail = completely offline -> wait for recovery -> reconnect immediately
  pass = network OK -> go to Layer 2

Layer 2: HTTP Auth Check (every 30s)
  Probe baidu.com / sina.com
  redirect to portal = need auth -> auto login
  200 OK = authenticated -> go to Layer 3
  (skipped within 60s after login to prevent duplicate)

Layer 3: Heartbeat (every 3 min)
  GET /out.htm to keep session alive
  fail = maybe dropped -> trigger Layer 2 check immediately
  pass = keep alive
```

### Disconnect Scenario Handling

| Scenario | Detection Time | Action |
|----------|---------------|--------|
| Network drops at 20min | <= 5s | Ping fails -> wait for recovery -> auto reconnect |
| 2-hour timeout logout | <= 30s | HTTP check fails -> auto re-login |
| Portal server restart | <= 5s | Ping/HTTP fail -> wait recovery -> reconnect |
| WiFi disconnect/reconnect | <= 5s | Ping recovers -> immediate auth |

## Quick Start

### 1. Copy config template

```powershell
Copy-Item config.example.json config.json
```

### 2. Edit config.json

Fill in your username and password:

```json
{
  "portal_url": "http://192.168.64.21",
  "login_path": "/ac_portal/login.php",
  "heartbeat_path": "/out.htm",
  "username": "YOUR_USERNAME",
  "password": "YOUR_PASSWORD",
  "heartbeat_interval_sec": 180,
  "check_interval_sec": 30,
  "max_retries": 5,
  "log_file": "auth_log.txt"
}
```

### 3. Run

```powershell
# Foreground (with console output, good for debugging)
.\auto_auth.ps1

# Single login only
.\auto_auth.ps1 -Once

# Background (silent, no window)
Start-Process powershell -ArgumentList "-WindowStyle Hidden -ExecutionPolicy Bypass -File .\auto_auth.ps1" -WindowStyle Hidden
```

### 4. Auto-start on boot

**Must run as Administrator** (right-click Start Menu -> Terminal Admin / PowerShell Admin):

```powershell
cd "D:\Code_workspace\network auth"
.\auto_auth.ps1 -Install      # Install scheduled task
.\auto_auth.ps1 -Uninstall    # Remove scheduled task
```

After install, the script runs automatically in background on every login.

## Config Reference

| Field | Description | Default |
|-------|-------------|---------|
| `portal_url` | Portal server address | `http://192.168.64.21` |
| `login_path` | Login API path | `/ac_portal/login.php` |
| `heartbeat_path` | Heartbeat endpoint | `/out.htm` |
| `username` | Login username | (required) |
| `password` | Login password | (required) |
| `heartbeat_interval_sec` | Heartbeat interval (seconds) | `180` |
| `check_interval_sec` | HTTP check interval (seconds) | `30` |
| `max_retries` | Max retry count | `5` |
| `log_file` | Log file name | `auth_log.txt` |

## Manage Scheduled Task

```powershell
# Check task status
Get-ScheduledTask -TaskName XuanwuNetworkAuth

# Stop background task
Stop-ScheduledTask -TaskName XuanwuNetworkAuth

# Start background task
Start-ScheduledTask -TaskName XuanwuNetworkAuth

# Remove scheduled task (run as admin)
.\auto_auth.ps1 -Uninstall
```

## View Logs

```powershell
# Real-time log
Get-Content auth_log.txt -Tail 20 -Wait

# Or open the file directly
notepad auth_log.txt
```

## Tech Details

- **Protocol**: Huawei AC Portal (POST to `/ac_portal/login.php`)
- **Login params**: `opr=pwdLogin`, `userName=xxx`, `pwd=xxx`
- **Response**: JSON `{success, msg, action, location, userName}`
- **Heartbeat**: GET `/out.htm` every 3 minutes
- **Session timeout**: 2 hours with no traffic
- **Test URLs**: `www.baidu.com`, `www.sina.com` (proven reachable after auth in hospital network)

## License

MIT
