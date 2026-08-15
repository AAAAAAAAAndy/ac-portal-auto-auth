# 宣武医院网络自动认证系统

自动完成宣武医院内网认证登录、心跳保活、断网检测、断线重连。

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
第1层: Ping 检测 (每5秒)
  → Ping 认证服务器 192.168.64.21
  → 失败 = 完全断网，进入等待恢复模式
  → 成功 = 物理网络正常，进入第2层

第2层: HTTPS 认证检测 (每30秒)
  → 探测 qq.com / baidu.com (HTTPS)
  → 被重定向 = 需要认证，自动登录
  → 200 OK = 已认证，进入第3层
  → 登录后60秒内跳过检测，防止重复登录

第3层: 心跳保活 (每3分钟)
  → GET /out.htm 维持会话
  → 失败 = 可能掉线，立即触发第2层检测
  → 成功 = 继续保持
```

### 断网场景处理

| 场景 | 检测时间 | 处理方式 |
|------|----------|----------|
| 20分钟突然断网 | ≤5秒 | Ping失败 → 等待恢复 → 自动重连 |
| 2小时超时注销 | ≤30秒 | HTTPS检测失败 → 自动重新登录 |
| 认证服务器重启 | ≤5秒 | Ping/HTTP失败 → 等待恢复 → 重连 |
| WiFi断开重连 | ≤5秒 | Ping恢复 → 立即认证 |

## 快速开始

### 1. 复制配置模板

```powershell
Copy-Item config.example.json config.json
```

### 2. 编辑 config.json

填入你的用户名和密码：

```json
{
  "portal_url": "http://192.168.64.21",
  "login_path": "/ac_portal/login.php",
  "heartbeat_path": "/out.htm",
  "username": "你的用户名",
  "password": "你的密码",
  "heartbeat_interval_sec": 180,
  "check_interval_sec": 30,
  "max_retries": 5,
  "log_file": "auth_log.txt"
}
```

### 3. 运行

```powershell
# 前台运行（可看日志，调试用）
.\auto_auth.ps1

# 只登录一次
.\auto_auth.ps1 -Once

# 后台静默运行
Start-Process powershell -ArgumentList "-WindowStyle Hidden -ExecutionPolicy Bypass -File .\auto_auth.ps1" -WindowStyle Hidden
```

### 4. 开机自启

**必须以管理员身份运行**（右键开始菜单 → 终端管理员 / PowerShell 管理员）：

```powershell
cd "D:\Code_workspace\network auth"
.\auto_auth.ps1 -Install      # 安装开机自启
.\auto_auth.ps1 -Uninstall    # 卸载开机自启
```

安装后，每次开机登录自动在后台运行，无需手动启动。

## 计划任务管理

```powershell
# 查看任务状态
Get-ScheduledTask -TaskName WuxuanNetworkAuth

# 停止后台任务
Stop-ScheduledTask -TaskName WuxuanNetworkAuth

# 启动后台任务
Start-ScheduledTask -TaskName WuxuanNetworkAuth

# 卸载（需管理员）
.\auto_auth.ps1 -Uninstall
```

## 查看日志

```powershell
# 实时查看最新日志
Get-Content auth_log.txt -Tail 20 -Wait

# 打开日志文件
notepad auth_log.txt
```

## 配置说明

| 字段 | 说明 | 默认值 |
|------|------|--------|
| `portal_url` | 认证服务器地址 | `http://192.168.64.21` |
| `login_path` | 登录接口路径 | `/ac_portal/login.php` |
| `heartbeat_path` | 心跳接口路径 | `/out.htm` |
| `username` | 用户名 | 必填 |
| `password` | 密码 | 必填 |
| `heartbeat_interval_sec` | 心跳间隔（秒） | `180` |
| `check_interval_sec` | HTTP检测间隔（秒） | `30` |
| `max_retries` | 最大重试次数 | `5` |
| `log_file` | 日志文件名 | `auth_log.txt` |

## 技术细节

- **认证协议**: 华为 AC Portal
- **登录接口**: `POST /ac_portal/login.php`，参数 `opr=pwdLogin&userName=xxx&pwd=xxx`
- **响应格式**: JSON `{success, msg, action, location, userName}`
- **心跳**: `GET /out.htm`，每 3 分钟一次
- **会话超时**: 2 小时无流量自动注销
- **测试地址**: `https://www.qq.com`、`https://www.baidu.com`（实测认证后可达）
- **测试地址说明**: `bing.com` 和 `sina.com` 在医院网络认证后仍被 portal 拦截，不可用

## 开源协议

MIT
