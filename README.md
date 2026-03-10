# OpenClaw Guardian 🛡️
> **为基于阿里百炼 (DASHSCOPE) 的 AI 智能体 [OpenClaw](https://github.com/vual/OpenClaw) 量身打造的极客级运维框架。**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Version: v2.0.0](https://img.shields.io/badge/Version-v2.0.0-blue.svg)](https://github.com/ecolid/OpenClaw-Guardian/releases)

---

### 🛡️ 为什么需要 Guardian？
当你将 OpenClaw 部署在 VPS 上作为 24/7 的在线伴侣时，你是否面临过这些困扰？
- **盲盒焦虑**：AI 回复慢了，是卡死了还是正在思考？
- **配置黑洞**：一次手抖修改，导致长达数月的聊天记忆毁于一旦？
- **备份臃肿**：每次备份几个 GB，Telegram 上传慢如蜗牛？
- **无损升级**：想更新 Guardian，又怕打断 AI 正在进行的精彩长谈？

**Guardian (守护者) 就是为了终结这些焦虑而生的。** 它将运维从“命令行地狱”提升到了“Telegram 全交互天堂”。

---

### ✨ 核心进化 (v1.9.x 特性集)

#### 🦞 “活字段”实时回执 (Live Metrics & Tool Breakdown)
告别冰冷的计时器！Guardian 现在提供具有极高信息密度的**实时思考回执**：
- **动态工具发现**：实时显示 AI 正在动用的武库（如 `🛠️ 搜索:1 | 阅卷:2 | 绘图:1`），没用到的工具不占位。
- **流量优化可见**：实时累计图片/视频压缩节省的流量（如 `🖼️ 媒体节省: 2.3MB`）。
- **监控全扫描**：精准捕捉 `prompt/completion` 消耗及全对话规模。
- **异常实时回显**：工具调用失败（如 `DataInspectionFailed`）直接弹回原因。

#### 🤖 双机粘性路由 (Sticky Resilient Routing)
- **429 绕行**: 毫秒级识别 Telegram 限流，自动切换至备用 Bot 节点。
- **状态探测**: 冷启动瞬间自检链路，确保发信权限 100% 可用。
- **手动切流**: 支持通过 `/switch` 随时掌控当前活跃节点。

#### ⚙️ 配置全能管理 (Config Mastery & Delivery)
- **目录漫游**: 通过 `/config` 在 Telegram 中像操作网盘一样浏览 OpenClaw 目录。
- **原始文件分发**: 点击即发，以无损 Document 格式直接获取 JSON/YAML/LOG 原始文件。
- **消息销毁 UX**: 发送文件后自动清理菜单，保持频道绝对整洁。

#### 🚀 秒级无感热更新 (Instant Seamless OTA)
- **瞬时固化**: 点击更新，Guardian 在毫秒级内将当前思考进度锁定到磁盘。
- **镜像重启**: 更新完成后，新版自动加载存档接管进度，AI 思考过程无断点。

#### 📦 极致瘦身备份 (Slim Backup)
针对 VPS 存储与 Telegram 传输优化：
- **智能过滤**：自动剔除浏览器缓存、构建文件、Git 历史及大型 GIF。
- **体积骤降**：备份包体积通常减少 **80% 以上**，确保持续处于 Telegram 快速上传阈值内。

---

### 🚀 极速部署 (一行指令)

Guardian 采用纯 **Python + Bash** 的轻量级架构，零 Docker 依赖，1 分钟即可完成武装：

```bash
curl -sL https://raw.githubusercontent.com/ecolid/OpenClaw-Guardian/main/deploy-guardian.sh | bash
```

> **提示**：更新时只需再次运行上方指令。它会自动识别并保留你已配置的 Token、ChatID 以及自定义的备份计划。

---

### 🛠️ 指令集速查

| 指令 | 运维战术功能 |
| :--- | :--- |
| `/status` | **综合看板**：查看硬件压力、OpenClaw 状态及下次预定备份时间。 |
| `/stats` | **统计中心**：实时查看今日/累计消耗规模与压缩频率。 |
| `/schedule`| **计划调度**：呼出菜单，一键修改自动备份频率。 |
| `/backup` | **即时瘦身备份**：一键封存超轻量级快照并同步云端。 |
| `/rollback`| **时光回滚**：点选历史快照，一键无损还原配置与记忆。 |
| `/grep [关键词]`| **案发现场**：定向抓取底层日志关键上下文 (如 400, OOM)。 |
| `/config` | **配置管理**：交互式浏览 OpenClaw 目录并获取原始配置文件。 |
| `/logs` | **日志中心**：快速查阅业务日志，支持大文件预览保护。 |
| `/restart` | **强制重启**：当发现 AI 响应异常时，一键重启后端。 |
| `/update` | **无感 OTA**：无视运行状态，秒级完成热更新并保留所有进度。 |

---

### 💡 极客运维心智模型 (Mental Model)

- **分层观察**：实时回执是你的第一体感。如果 `exec` 工具频繁报错，说明底层权限或环境有问题。
- **无感进化**：养成看到 `/update` 提示就更新的习惯。由于有了“瞬时存档”，你无需等待对话结束。
- **空间正义**：定期通过 `/status` 检查磁盘。Slim Backup 虽然省空间，但定期的快照管理依然重要。

---

**开源地址**: [github.com/ecolid/OpenClaw-Guardian](https://github.com/ecolid/OpenClaw-Guardian)
*守护你的数字伴侣，让技术更有温度。* 🛡️
