# OpenClaw Guardian 🛡️
> **为基于阿里百炼 (DASHSCOPE) 的 AI 智能体 [OpenClaw](https://github.com/vual/OpenClaw) 量身打造的极客级运维框架。**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Version: v1.7.2](https://img.shields.io/badge/Version-v1.7.2-blue.svg)](https://github.com/ecolid/OpenClaw-Guardian/releases)

---

### 🛡️ 为什么需要 Guardian？
当你将 OpenClaw 部署在 VPS 上作为 24/7 的在线伴侣时，你是否面临过这些困扰？
- **盲盒焦虑**：AI 回复慢了，是卡死了还是正在思考？
- **配置黑洞**：一次手抖修改，导致长达数月的聊天记忆毁于一旦？
- **字数迷雾**：这几天百炼到底扣了多少费？用了多少字符？
- **异地灾备**：VPS 炸了，我的 AI 还能在别的地方重生吗？

**Guardian (守护者) 就是为了终结这些焦虑而生的。** 它将运维从“命令行地狱”提升到了“Telegram 全交互天堂”。

---

### ✨ 核心进化 (v1.7.x 特性集)

#### 💃 灵魂舞者：思维状态追踪器 (Thinking Tracer)
告别猜测！当 AI 开始处理你的请求时，Telegram 会同步弹出一个动态计时器：
- **动态 Emoji 动画**：8 段循环律动图标 (🧠 💭 ⚡ ✨...)，提供即时的系统活跃感。
- **精准赶路计时**：采用 +Ns 动态增量算法，即使网络延迟波动，时间显示依然逻辑严密。
- **启动检测恢复**：即便 Guardian 意外重启，它也会自动回溯日志，瞬间找回正在进行的思考状态。

#### 🕹️ 智能管理中心：全交互式运维
- **指令菜单 2.0**：按 **监控/存储/维护** 分类的图标菜单，操作如丝般顺滑。
- **智能调度器 (/schedule)**：无需碰命令行。直接在手机上点击按钮，即可实时改写系统 Crontab 备份频率。
- **一键回滚 (/rollback)**：时光倒流之术。自动管理最近 10 次快照，自带“回滚前快照”双层保险。

#### 📊 数据监控与容灾
- **小龙虾看板 (/stats)**：实时字数统计、对话次数、Compaction 记录。
- **极客状态仪表盘 (/status)**：精美的硬件水位图表与 AI 运行环境全扫描。
- **私有云同步 (Cloud Sync)**：每次备份自动同步加密元数据索引至你的私有频道，确保数据异地重生。

---

### 🚀 极速部署 (一行指令)

Guardian 采用纯 **Python + Bash** 的轻量级架构，零 Docker 依赖，1 分钟即可完成武装：

```bash
curl -sL https://raw.githubusercontent.com/ecolid/OpenClaw-Guardian/main/deploy-guardian.sh | bash
```

> **提示**：更新时只需再次运行上方指令。它会自动识别并保留你已配置的 Token、ChatID 以及自定义的备份计划 (`schedule.json`)。

---

### 🛠️ 指令集速查

| 指令 | 运维战术功能 |
| :--- | :--- |
| `/status` | **综合看板**：查看硬件压力、OpenClaw 状态及下次预定备份时间。 |
| `/stats` | **统计中心**：实时查看今日/累计字数消耗与压缩频率。 |
| `/schedule`| **计划调度**：呼出菜单，一键修改自动备份频率（每4/6/12小时等）。 |
| `/backup` | **即时备份**：忽略计划，立即封存快照并同步云端。 |
| `/rollback`| **时光回滚**：点选历史快照，一键无损还原配置与记忆。 |
| `/grep [关键词]`| **案发现场**：定向抓取底层日志关键上下文 (如 400, OOM)。 |
| `/logs` | **日志中心**：快速查阅业务日志或 Cron 备份日志详情。 |
| `/restart` | **强制重启**：当发现 AI 响应异常时，一键重启后端。 |
| `/update` | **OTA 升级**：连线官方仓库，一键获取最新的 Guardian 特性。 |

---

### 💡 极客运维心智模型 (Mental Model)

- **分层观察**：先看 `/status`。如果网络通、Bot 在，说明底层还在。再看日志，精准打击。
- **日志为王**：拒绝主观猜测。利用 `/grep` 获取原始错误代码（如 `DataInspectionFailed`），这是与 AI 沟通解决问题的唯一桥梁。
- **资源敬畏**：监控 Swap 和负载热度。当硬件红灯亮起，那是系统在求救，请给它多一点处理时间，或者点击 `/restart` 清理内存。

---

**开源地址**: [github.com/ecolid/OpenClaw-Guardian](https://github.com/ecolid/OpenClaw-Guardian)
*守护你的数字伴侣，让技术更有温度。* 🛡️
