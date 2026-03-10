# OpenClaw Guardian 🛡️
> **为基于阿里百炼 (DASHSCOPE) 的 AI 智能体 [OpenClaw](https://github.com/vual/OpenClaw) 量身打造的极客级运维框架。**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Version: v2.0.0](https://img.shields.io/badge/Version-v2.0.0-blue.svg)](https://github.com/ecolid/OpenClaw-Guardian/releases)

---

### 🛡️ 为什么需要 Guardian？
当你将 OpenClaw 部署在 VPS 上作为 24/7 的在线伴侣时，你是否面临过这些困扰？
- **盲盒焦虑**：AI 回复慢了，是卡死了还是正在思考？
- **连接断点**：Telegram 被限流导致通知中断？
- **配置地狱**：改个 JSON 还要翻 SSH 目录，甚至因为超长文字发不出？
- **无损升级**：想更新 Guardian，又怕打断 AI 正在进行的精彩长谈？

**Guardian (守护者) 就是为了终结这些焦虑而生的。** 它将运维从“命令行地狱”提升到了“Telegram 全交互天堂”。

---

### 🚀 里程碑：Guardian 2.0 核心特性

#### 🤖 双机粘性路由 (Sticky Resilient Routing)
- **429 智能避让**: 毫秒级识别 Telegram 限流 (429)，自动无缝切换至备用 Bot 节点。
- **状态探测机**: 冷启动瞬间执行链路自检，确保发信权限 100% 可靠。
- **手动掌控**: 支持通过 `/switch` 指令随时审视并手动强制路由，实现通讯链路的绝对自主。

#### ⚙️ 配置全能管理 (Config Mastery & Delivery)
- **交互式漫游**: 通过 `/config` 指令直接在 Telegram 中以交互按钮形式浏览 `/root/.openclaw/` 目录。
- **原始文件秒发**: 彻底解决 HTML 预览的格式崩坏。点击文件名，系统直接发送无损的 **Document** 原始文件，支持手机端直接编辑。
- **极简 UX**: 文件发送后自动销毁功能菜单，保持会话界面如镜面般整洁。

#### 🦞 “活字段”实时回执 (Live Metrics 2.0)
- **动态工具追踪**: 实时回显 AI 正在运行的工具链（如 `🛠️ 阅卷:2 | 绘图:1`），没动用的工具自动隐藏。
- **异常内容穿透**: 底层错误（如 Context 溢出或 API 挂掉）直接显示在思考回执中，拒绝运维黑盒。
- **毫秒级监测**: `/status` 实时显示主机负载及 Bot 到 Telegram API 的往返时延 (RTT)。

#### 🚀 秒级无感热更新 (Instant Seamless OTA)
- **状态原子存档**: 点击更新瞬间，Guardian 将当前思考进度（计时、字数、工具状态）毫秒级固化到磁盘。
- **镜像接管技术**: 更新完成后秒速重启，新版直接加载存档，接管之前的思考任务继续执行。

---

### 🚀 极速部署 (一行指令)

Guardian 采用纯 **Python + Bash** 的轻量级架构，零 Docker 依赖，1 分钟即可完成武装：

```bash
curl -sL https://raw.githubusercontent.com/ecolid/OpenClaw-Guardian/main/deploy-guardian.sh | bash
```

> **提示**：更新时只需再次运行上方指令。它会自动识别并保留你已配置的 Token、ChatID 以及自定义的备份计划。

---

### 🛠️ 指令集速查

| 指令 | 2.0 极客运维实战机能 |
| :--- | :--- |
| `/status` | **综合看板**：查看 CPU/内存/磁盘压力、API 时延以及服务运行时间。 |
| `/stats` | **统计中心**：实时汇总今日/累计消耗字符、负载峰值与各技能调用频度。 |
| `/config` | **配置管理**：像网盘一样浏览目录并直接获取 JSON/YAML/LOG 原始文件。 |
| `/switch` | **路由切换**：可视化切换主/备 Bot 线路，告别限流封禁。 |
| `/backup` | **全能备份**：一键生成极致瘦身的异地快照，并自动同步云端索引。 |
| `/rollback`| **时光回滚**：点选历史快照，一键无损还原配置与记忆。 |
| `/grep [关键词]`| **案发现场**：定向抓取日志上下文字段，快速定位 400 指令或数据库故障。 |
| `/logs` | **日志中心**：快速查阅业务日志，支持自动分页与超长保护。 |
| `/restart` | **强制重启**：当发现 AI 响应逻辑异常时，一键重启 OpenClaw 后端。 |
| `/update` | **无感 OTA**：点击即更新，秒级热修复且不中断任何正在进行的思考任务。 |

---

### 💡 极客运维心智模型 (Mental Model)

- **分层观察**：实时回执是你的第一体感。看到 `🚨 异常` 提示时，立即配合 `/grep` 抓取具体堆栈。
- **无感进化**：不要等待！由于有了“原子存档”，你可以在 AI 思考的任何时刻执行 `/update`。
- **资源正义**：定期通过 `/status` 检查磁盘占用。Slim Backup 虽然省空间，定期清理旧快照依然是好习惯。

---

**开源地址**: [github.com/ecolid/OpenClaw-Guardian](https://github.com/ecolid/OpenClaw-Guardian)
*守护你的数字伴侣，让技术更有温度。* 🛡️
