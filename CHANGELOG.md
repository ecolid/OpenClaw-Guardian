# OpenClaw Guardian 更新日志

## [v1.1.0] - 2026-03-07
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
