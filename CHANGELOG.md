# OpenClaw Guardian 更新日志

## [v1.3.0] - 2026-03-07
### 新增 (New)
- 改进 `/grep` 指令交互：单独发送 `/grep` 时，将呼出一个“快捷诊断面板”(Inline Keyboard)。内置了防打扰的一键回查按钮：
  - [🔴 百炼风控拦截 (DataInspectionFailed)]
  - [🟡 网络请求超时 (Timeout)]
  - [💥 内存耗尽被杀 (Out of memory)]
  - [🚨 严重运行异常 (Exception/Error)]
  - [🔵 系统启动记录 (Started)]
- 支持查询被风控拦截的关键词 (例如 `/grep 400`)，并将案发现场前后 5 行的 Payload 上下文推送到 Telegram，避免了原始 `/logs` 的刷屏与线索遗漏问题。

---## [v1.1.0] - 2026-03-07
### 新增 (New)
- 支持 OTA 热备份机制，通过 `/update` 命令无感平滑升级。
- 支持安全回滚机制，通过 `/update_rollback` 一键恢复上一版本。
- 新增版本控制与更新日志播报系统。

### 优化 (Enhancement)
- 分离私有配置到本地 `.env` 文件，不再硬编码敏感 Token。
- 增加防抖热备脚本拦截，避免在高速编辑文件时频繁触发全量备份。

### 修复 (Fix)
- 在执行备份打包 (tar) 时过滤 `.png`, `.jpg`, `.mp4` 等大体积的多媒体文件，防止磁盘 IO 和小龙虾 Playwright 缓存撑爆节点崩溃。

---

## [v1.0.0] - 2026-03-05
- 初版发布，具备 `/status`, `/backup`, `/rollback`, `/restart` 命令
- 整合 60s 定时状态机与 `journalctl` 高敏感流双活监听体系。
