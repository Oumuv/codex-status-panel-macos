# Codex 状态面板

独立的 macOS 状态面板，用于显示本机 Codex 额度、Codex 连接状态和桌面跟随状态。默认不显示 BTC/ETH 行情。

## 功能

- 通过本机 `codex app-server --stdio` 读取 Codex 额度。
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
- 日志：`~/Library/Logs/Codex 状态面板.log`

## 配置

默认配置模板位于 `Resources/default-panel-config.json`。安装器只在配置文件不存在时复制默认配置，重装会保留用户已有配置。

## 隐私

额度数据只来自本机 Codex，不上传到本项目服务器。发布前建议运行：

```bash
./scripts/privacy-audit.sh
```

## 许可

原创代码和文档结构使用 MIT License。素材与商标说明见 [ASSET-NOTICE.md](ASSET-NOTICE.md)。
