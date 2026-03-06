# OpenClaw Guardian 是专为基于阿里百炼 (DASHSCOPE) 运作的中文原神 AI 智能体 [OpenClaw](https://github.com/vual/OpenClaw) 设计的一键化部署、状态监控与容灾守护框架。

**当前稳定版本**: `v1.4.5` (已通过高并发压测，修复了死锁与转义奔溃，推荐作为核心生产环境部署)。

全天候监控你的 OpenClaw 服务状态，修改配置实时防抖备份，并在发生崩溃时第一时间将系统状态推送到你的 Telegram。

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## ✨ 核心特性

- **双通道状态机监控**：独创 `journalctl` 实时流(秒级告警) + 60s `systemctl` 金标准轮询兜底，确保状态检测 100% 准确，防刷屏防卡死。
- **智能防抖备份**：监听配置和记忆（Agents）文件夹，改动后自动缓冲 5 分钟后静默合并备份，告别碎片化文件。
- **定时全量备份**：默认每 4 小时全自动热备份配置和对话历史，打包发送至个人 Telegram 单线联系存档。
- **一键回滚历史快照**：Telegram 内联按钮直接展示最近备份记录，点选即可实现脱机热更新与一键回滚，全过程无人值守。
- **交互式命令菜单**：支持 `/status` (查内存/状态)、`/restart` (强制重启)、`/logs` (看崩溃堆栈)。

## 🚀 一键安装

环境要求：基于 Systemd 部署的 Ubuntu/Debian 系统，且正在运行 OpenClaw。
无需安装 Node/Docker，纯底层轻量级 Python + Bash 实现。

```bash
curl -fsSL https://raw.githubusercontent.com/ecolid/openclaw-guardian/main/deploy-guardian.sh | sudo bash
```

安装过程中会提示你输入两个必填参数。

## ⚙️ 准备工作 (Bot 配置)

在你运行一键安装之前，你需要准备好：

1. **Telegram Bot Token**:
   - 在 Telegram 中搜索 `@BotFather`
   - 发送 `/newbot` 创建一个新机器人
   - 复制生成的 API Token (格式如 `123456789:AAEF...`)

2. **你的个人 Chat ID**:
   - 在 Telegram 中搜索 `@userinfobot` 或 `@getmyid_bot`
   - 获取你的纯数字 ID (例如 `5722324304`)

## 🛠️ Bot 指令说明

在与你的 Guardian Bot 私聊时，可以直接发送以下命令（菜单中已内置提示）：

| 命令 | 功能描述 |
|---|---|
| `/status` | 返回 OpenClaw 服务的存活状态、VPS CPU/内存和磁盘使用率 |
| `/backup` | 忽略定时和防抖倒计时，立即执行一次全量热备份 |
| `/rollback` | 调出内联按钮菜单，列出最近 10 次历史快照。点击后自动下载、解压、覆盖并重启服务 |
| `/restart` | 直接在 VPS 层面执行 `systemctl restart openclaw` |
| `/logs`    | 截取最近的 20 行 `journalctl` 崩溃核心日志发至聊天窗口 |

---

*OpenClaw Guardian 作为一个与主进程完全解耦的 Sidecar 守护程序运行。即便 OpenClaw 因配置错误陷入死循环崩溃，Guardian 依然独立存活并随时接受你的指令。*
