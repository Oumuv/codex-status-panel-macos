# Codex 状态面板

独立的 macOS 状态面板，用于显示本机 Codex 额度、Codex 连接状态和桌面跟随状态。默认不显示 BTC/ETH 行情。

## 功能

- 通过本机 `codex app-server --stdio` 读取 Codex 额度。
- 同时显示本机 Codex 与 Pi CLI 会话的执行、待确认、完成和失败状态。
- 点击 Codex/Pi CLI 任务可切换到其所在的 Terminal、iTerm2 或 Ghostty 窗口。
- 跟随当前 Codex 桌面窗口；找不到可跟随目标时按配置固定显示。
- 支持可编辑 JSON 配置，无需重新构建 App。
- 提供安装、检查、卸载脚本和 release ZIP 构建脚本。

## 构建

需要 macOS 12.3+ 与 Xcode Command Line Tools。

```bash
./scripts/build.sh
```

构建输出：

```text
build/Codex 状态面板.app
```

## 调试命令

```bash
./build/Codex\ 状态面板.app/Contents/MacOS/CodexStatusPanel --print-panel-config
./build/Codex\ 状态面板.app/Contents/MacOS/CodexStatusPanel --self-test-placement
./build/Codex\ 状态面板.app/Contents/MacOS/CodexStatusPanel --render-preview /tmp/codex-status-panel-preview.png
```

## 打包

```bash
./scripts/build-release.sh
```

输出：

```text
dist/Codex-Status-Panel-macOS-Universal-v1.1.0.zip
```

## 安装位置

- App：`~/Applications/Codex 状态面板.app`
- LaunchAgent：`~/Library/LaunchAgents/io.github.mayday-materials.codex-status-panel.plist`
- 配置：`~/Library/Application Support/io.github.mayday-materials.codex-status-panel/panel-config.json`
- 健康状态：`~/Library/Caches/io.github.mayday-materials.codex-status-panel/panel-health.json`
- Pi 状态桥接：`~/.pi/agent/extensions/io.github.mayday-materials.codex-status-panel.ts`
- Pi 运行状态：`~/Library/Application Support/io.github.mayday-materials.codex-status-panel/pi-sessions/`
- 日志：`~/Library/Logs/Codex 状态面板.log`

## 配置

默认配置模板位于 `Resources/default-panel-config.json`。安装器只在配置文件不存在时复制默认配置，重装会保留用户已有配置。

## Pi CLI 集成

安装器会把只负责状态上报的用户级扩展放入 Pi agent 目录。完整状态支持要求 Pi `>= 0.87.0`，当前按 Pi `1.0.4` 验证。新启动的 Pi 会话会自动加载；已经打开的 Pi 需要执行 `/reload` 或重新启动。使用自定义 `PI_CODING_AGENT_DIR` 时，应在同一环境下运行安装器。

扩展只写入会话 ID、PID、工作目录、状态和时间戳。任务标题最多 80 字符；未命名会话的标题可能取自首条提示首行的前 80 字符。扩展不读取认证文件，也不保存其余提示内容、回复或工具输出。使用 `pi --no-extensions`、远端 Pi 或未挂载状态目录的隔离环境时，面板会自动退化为仅显示 Codex 会话。

Codex 与 Pi 任务共用最多五行的任务区域。Pi 任务使用 `π` 前缀区分；Codex 额度显示不受影响。

## 隐私

额度数据只来自本机 Codex，不上传到本项目服务器。发布前建议运行：

```bash
./scripts/privacy-audit.sh
```

## 许可

原创代码和文档结构使用 MIT License。素材与商标说明见 [ASSET-NOTICE.md](ASSET-NOTICE.md)。
