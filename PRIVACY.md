# 隐私说明

## 仓库与发布包不包含

- 作者或测试者的本机用户名、邮箱、主目录和绝对路径；
- GitHub Token、API Key、Cookie、密码或其他访问凭据；
- Codex 聊天内容、账号缓存、真实额度百分比或重置时间；
- 安装测试产生的日志、健康状态文件和诊断报告。

## 运行时数据

本项目没有自建数据收集服务器。运行时数据按用户启用的功能在本机处理，或发送到以下明确的数据源：

- 默认 Codex 额度由本机 `codex app-server` 提供，只用于面板显示。
- 配置 Sub2API 后，App 会向用户配置的服务地址请求 `/v1/usage`，并在 `Authorization` 请求头中携带配置的 Bearer API Key。API Key 保存在用户自己的 `panel-config.json` 中；建议仅使用可信 HTTPS 服务。
- BTC/ETH 行情默认关闭；启用后会请求 Binance 公共行情接口，不需要 API Key。
- A 股行情默认关闭；启用后会请求东方财富公共行情接口，并在本机缓存最近一次有效行情，不需要 API Key。
- Codex 任务状态来自本机 `CODEX_HOME`（默认 `~/.codex`）中的 session 和未读状态文件。
- macOS 日志位于当前用户的 `~/Library/Logs`。
- 健康状态文件记录面板版本、PID、运行和连接状态、跟随状态、面板可见性与高度、定位来源与误差、行情开关、A 股市场状态和更新时间；不记录真实额度值、token、API Key、邮箱或会话内容。
- Pi 状态桥接只在本机写入会话 ID、Pi 进程 PID、运行模式、工作目录、会话文件路径、状态和时间戳。任务标题最多 80 字符；未命名会话可能使用首条提示首行的前 80 字符。桥接不读取 Pi 认证文件，也不保存其余提示内容、回复、工具参数或工具输出。
- Pi 桥接状态位于当前用户的 `~/Library/Application Support/io.github.mayday-materials.codex-status-panel/pi-sessions`，卸载时删除。

## 发布前审计

维护者应运行：

```bash
./scripts/privacy-audit.sh
```

发布包还应在全新临时目录中解压并重新执行校验，避免把本机缓存、日志或绝对路径带入压缩包。
