# Codex 状态面板

面向 macOS 的菜单栏浮动面板，用于集中查看 Codex 额度、Codex/Pi CLI 任务状态和可选行情。面板可以跟随 Codex 桌面端窗口；没有可跟随窗口时会独立显示，并允许拖动和记忆位置。

当前版本：`1.3.0`（build `9`）。支持 Apple Silicon 与 Intel Mac。

## 主要功能

### 额度

- 默认通过本机 `codex app-server --stdio` 读取 Codex 账户额度，不需要额外 API Key。
- 可选接入 Sub2API `/v1/usage`，支持钱包余额、订阅额度、日/周/月限额和多周期额度切换。
- 可以点击面板中的额度值循环切换额度周期，也可以从菜单栏的“额度”子菜单选择。
- 支持手动刷新；暂时刷新失败时会保留上一份可用展示结果。

### Codex 与 Pi 任务

- 同时展示本机 Codex 和 Pi CLI 会话，状态包括读取中、运行中、等待确认、已完成和执行失败。
- 支持 Codex CLI 的审批和用户输入等待状态。Codex 任务完成后保留 2 分钟，失败后保留 5 分钟，然后自动从面板消失，不改变会话的已读状态。
- Pi 任务以 `π` 前缀区分；Codex 与 Pi 同名任务不会互相覆盖。
- 最多同时展示 5 行任务，并为运行、等待、完成和失败提供独立图标、文字效果与动效。
- 遵循 macOS“减少动态效果”设置；面板隐藏、被遮挡或任务消失时会停止相关动画。
- 点击任务可打开 Codex App 线程，或聚焦承载 Codex/Pi CLI 的 Terminal、iTerm2、Ghostty 窗口。

### 面板与菜单栏

- 跟随当前 Codex/ChatGPT 桌面窗口中的 Codex 桌宠位置。
- 找不到桌面端或桌宠时，面板在屏幕上独立显示；此时可以拖动，位置会被记住。
- 支持折叠/展开、隐藏/显示、重置跟随位置和跨 Space 显示。
- 菜单栏可查看连接、跟随和 A 股市场状态，并可刷新额度、切换行情、打开或重新加载配置。
- 使用单实例锁和 LaunchAgent，避免重复面板并支持登录后自动启动。

### 可选行情

- BTC/ETH：使用 Binance 公共行情接口，默认关闭。
- A 股：使用东方财富公共行情接口，支持上证、深证、创业板、沪深 300 等自定义条目，默认关闭。
- A 股最多启用 5 项，区分交易中、未开盘、午间休市、已收盘、周末、缓存、过期和离线状态。
- A 股数据会写入本机缓存，网络异常或休市时可显示最近一次有效结果。

## 系统要求

| 项目 | 要求 |
| --- | --- |
| macOS | `12.3` 或更高版本 |
| 架构 | `arm64` 与 `x86_64` Universal App |
| Codex 额度 | 已安装并登录 Codex CLI，或配置 Sub2API |
| Codex 任务 | 本机 Codex CLI/App 产生的 session 日志 |
| Pi 任务 | Pi `>= 0.87.0`；当前使用 Pi `1.0.4` 验证 |
| 源码构建 | Xcode Command Line Tools |

Pi 是可选依赖。没有安装 Pi 时，Codex 额度、Codex 任务、面板和行情功能仍可正常使用。

## 安装与升级

从 release ZIP 安装时：

1. 解压整个 `Codex-Status-Panel-macOS-Universal-v<版本>.zip`，不要只取出 App。
2. 运行 `安装Codex状态面板.command`。
3. 安装完成后，可运行 `检查Codex状态面板.command` 做完整检查。

安装器会：

- 安装 App 到 `~/Applications/Codex 状态面板.app`；
- 注册当前用户的 LaunchAgent；
- 首次安装时创建默认配置；
- 安装 Pi 状态桥接扩展；
- 启动面板并等待健康状态通过。

直接运行新版安装器即可升级。已有 `panel-config.json` 会保留，不会被默认配置覆盖。

卸载时运行 `卸载Codex状态面板.command`。卸载器会删除 App、LaunchAgent、健康状态、Pi 桥接扩展和 Pi 运行状态，但保留用户配置，便于以后重装。

## 日常使用

点击菜单栏图标可以使用以下操作：

- **状态**：查看额度连接、面板跟随和 A 股市场状态。
- **面板**：隐藏/显示、折叠/展开、重置跟随位置。
- **额度**：立即刷新；存在多个额度周期时可直接选择。
- **显示内容**：开关 BTC/ETH 和 A 股行情。
- **配置**：打开配置文件并在修改后重新加载。

面板本身支持以下交互：

- 点击右下角控制区域折叠面板；点击折叠面板可展开。
- 点击可切换的额度值，循环切换额度周期。
- 点击任务行，打开对应 Codex 线程或终端窗口。
- 面板处于独立显示状态时，拖动面板可以保存新位置。

行情开关和独立面板位置保存在当前用户偏好中。菜单中保存过的行情开关优先于 JSON 中的初始默认值；“重置跟随位置”会清除已保存的独立位置。

## 配置

用户配置位于：

```text
~/Library/Application Support/io.github.mayday-materials.codex-status-panel/panel-config.json
```

默认模板位于 [`Resources/default-panel-config.json`](Resources/default-panel-config.json)。安装器只在用户配置不存在时复制模板。

修改配置后，从菜单栏选择“配置 → 重新加载配置”。如果新配置无效，App 会显示错误并继续使用当前有效配置。

配置加载优先级为：

1. `CODEX_STATUS_PANEL_CONFIG` 指定的文件；
2. 兼容变量 `CODEX_PANEL_CONFIG` 指定的文件；
3. 用户 `panel-config.json`；
4. App 内置默认配置；
5. 代码内置安全默认值。

### 额度来源

默认模板中的 `baseUrl` 和 `apiKey` 都为空，此时使用本机 Codex：

```json
{
  "usageProvider": {
    "baseUrl": "",
    "apiKey": "",
    "modelProvider": "sub2api"
  }
}
```

使用 Sub2API 时填写服务地址和 API Key：

```json
{
  "usageProvider": {
    "baseUrl": "https://your-sub2api.example.com",
    "apiKey": "YOUR_API_KEY",
    "modelProvider": "sub2api"
  }
}
```

客户端会根据 `baseUrl` 构造 `/v1/usage` 地址，并通过 `Authorization: Bearer <API Key>` 请求。建议只使用可信 HTTPS 服务；不要把包含真实 API Key 的用户配置提交到仓库。

### A 股条目

`markets.stockQuotes` 中每项支持：

- `secid`：必填，格式为 `0|1.六位代码`；
- `name`：可选，最多 32 个字符；
- `badge`：可选，最多 2 个字符；
- `enabled`：是否展示，默认 `true`。

示例：

```json
{
  "markets": {
    "stockQuotes": [
      {"secid": "1.000001", "name": "上证指数", "badge": "沪", "enabled": true},
      {"secid": "0.399006", "name": "创业板指", "badge": "创", "enabled": true}
    ]
  }
}
```

同一 `secid` 不能重复，最多启用 5 项。

### 常用配置项

| 配置 | 默认值 | 说明 |
| --- | --- | --- |
| `theme.title` | `Codex` | 不显示额度组件时使用的标题 |
| `theme.backgroundImage` | `quota-panel-background.png` | App Resources 中的背景图片 |
| `widgets.codexQuota` | `true` | 是否显示额度组件 |
| `widgets.cryptoPrices` | `false` | 未被环境变量或菜单偏好覆盖时的 BTC/ETH 默认状态；release 安装后默认关闭 |
| `widgets.stockPrices` | `false` | 未被环境变量或菜单偏好覆盖时的 A 股默认状态；release 安装后默认关闭 |
| `tracking.gapPoints` | `14` | 面板和桌宠可见顶部之间的间距 |
| `tracking.mascotTopPaddingPoints` | `7` | 桌宠素材顶部透明区域补偿 |
| `refresh.quotaSeconds` | `300` | 额度刷新周期 |
| `refresh.cryptoSeconds` | `5` | BTC/ETH 刷新周期 |
| `refresh.stockSeconds` | `30` | A 股活跃时刷新周期 |
| `refresh.stockClosedSeconds` | `300` | A 股休市/离线时刷新周期 |
| `refresh.stockCacheWriteSeconds` | `300` | A 股缓存最短写入周期 |
| `refresh.followSeconds` | `0.05` | 面板跟随检查周期，实际最低为 0.05 秒 |

## Pi CLI 集成

为了准确识别 Pi 的运行、等待确认、完成和失败状态，Pi 需要加载一个用户级扩展。安装器会自动安装，不需要执行 `pi install`：

```text
~/.pi/agent/extensions/io.github.mayday-materials.codex-status-panel.ts
```

新启动的 Pi 会话会自动加载扩展。已经打开的 Pi 会话需要执行 `/reload`，或退出后重新启动。

使用自定义 Pi 目录时，应在运行安装、检查和卸载脚本时设置相同的环境变量：

```bash
PI_CODING_AGENT_DIR="$HOME/path/to/pi-agent" \
  ./安装Codex状态面板.command
```

以下情况不会上报 Pi 状态：

- 使用 `pi --no-extensions`；
- Pi 版本早于 `0.87.0`，缺少完整事件；
- Pi 在远端或隔离环境运行，无法写入本机状态目录；
- 当前会话在安装扩展后没有重新加载。

桥接扩展按 Pi 进程写入原子状态文件，并通过心跳处理异常退出。状态目录为：

```text
~/Library/Application Support/io.github.mayday-materials.codex-status-panel/pi-sessions/
```

扩展只保存会话 ID、PID、模式、工作目录、会话文件路径、状态和时间戳。任务标题最多 80 字符；未命名会话可能使用首条提示首行的前 80 字符。扩展不读取 Pi 认证文件，也不保存其余提示、回复或工具输出。

## 数据来源与隐私

项目没有自建数据收集服务器。运行时可能访问以下数据源：

- **Codex 额度**：默认通过本机 `codex app-server` 获取。
- **Sub2API**：仅在配置后访问用户指定的 `/v1/usage`，并携带配置的 Bearer API Key。
- **BTC/ETH**：仅在启用后访问 Binance 公共行情接口。
- **A 股**：仅在启用后访问东方财富公共行情接口。
- **Codex 任务**：读取本机 `CODEX_HOME`（默认 `~/.codex`）下的 session 和未读状态文件。
- **Pi 任务**：读取上述本机桥接状态目录。

健康状态不保存真实额度、token 或邮箱。详细说明见 [`PRIVACY.md`](PRIVACY.md)。

## 安装位置

| 内容 | 路径 |
| --- | --- |
| App | `~/Applications/Codex 状态面板.app` |
| LaunchAgent | `~/Library/LaunchAgents/io.github.mayday-materials.codex-status-panel.plist` |
| 用户配置 | `~/Library/Application Support/io.github.mayday-materials.codex-status-panel/panel-config.json` |
| A 股缓存 | `~/Library/Caches/io.github.mayday-materials.codex-status-panel/stock-quotes.json` |
| 健康状态 | `~/Library/Caches/io.github.mayday-materials.codex-status-panel/panel-health.json` |
| Pi 扩展 | `~/.pi/agent/extensions/io.github.mayday-materials.codex-status-panel.ts` |
| Pi 状态 | `~/Library/Application Support/io.github.mayday-materials.codex-status-panel/pi-sessions/` |
| 日志 | `~/Library/Logs/Codex 状态面板.log` |

## 排查问题

### 面板没有额度

确认 Codex CLI 已安装并登录，然后执行：

```bash
"$HOME/Applications/Codex 状态面板.app/Contents/MacOS/CodexStatusPanel" --print-quota
```

如果使用 Sub2API，检查 `baseUrl`、API Key、HTTPS 连接和 `/v1/usage` 响应。

### Pi 任务没有出现

1. 确认扩展文件存在于 Pi agent 的 `extensions` 目录。
2. 在已有 Pi 会话执行 `/reload`，或重启 Pi。
3. 确认没有使用 `--no-extensions`。
4. 使用自定义 `PI_CODING_AGENT_DIR` 时，用相同环境运行安装脚本。

### 点击任务不能切换窗口

Codex App 任务通过 `codex://` 链接打开；CLI 任务需要进程仍在运行并拥有 TTY。首次控制 Terminal 或 iTerm2 时，macOS 可能要求授予 Automation 权限。非交互 print/RPC 进程没有可聚焦终端时，面板只记录诊断日志。

### 配置没有生效

从菜单栏执行“配置 → 重新加载配置”，然后查看：

```bash
"$HOME/Applications/Codex 状态面板.app/Contents/MacOS/CodexStatusPanel" --print-panel-config
tail -n 50 "$HOME/Library/Logs/Codex 状态面板.log"
```

### 检查安装

运行 release 包中的：

```text
检查Codex状态面板.command
```

它会检查 App、架构、签名、LaunchAgent、运行进程、健康状态、Pi 扩展和主要内置自测。

## 源码构建

```bash
./scripts/build.sh
```

输出：

```text
build/Codex 状态面板.app
```

启动本地构建：

```bash
open "build/Codex 状态面板.app"
```

## 调试与预览

```bash
BIN="./build/Codex 状态面板.app/Contents/MacOS/CodexStatusPanel"

"$BIN" --print-panel-config
"$BIN" --print-quota
"$BIN" --print-task-progress
"$BIN" --print-panel-location
"$BIN" --print-pet-window-diagnostics
"$BIN" --render-preview /tmp/codex-status-panel.png \
  --preview-usage sub2api-rate-7d \
  --preview-task showcase
```

可用额度预览模式：

```text
codex
unconfigured
sub2api-wallet
sub2api-empty-wallet
sub2api-rate-1d
sub2api-rate-7d
sub2api-warning
sub2api-danger
```

可用任务预览模式：

```text
showcase
reading
running
waiting
completed
failed
idle
```

追加 `--collapsed` 可以生成折叠态预览。

## 回归检查

会读写同一个构建 App 的命令应串行执行：

```bash
./scripts/build.sh
./build/Codex\ 状态面板.app/Contents/MacOS/CodexStatusPanel --self-test-task-progress
./build/Codex\ 状态面板.app/Contents/MacOS/CodexStatusPanel --self-test-placement
/bin/zsh scripts/test-v1.2-menu-controls.sh
./scripts/test-task-animation-visual.sh
./scripts/privacy-audit.sh
```

## 构建 release

```bash
./scripts/build-release.sh
```

输出：

```text
dist/Codex-Status-Panel-macOS-Universal-v<版本>.zip
```

release 包包含 Universal App、默认配置、Pi 桥接扩展、安装/检查/卸载脚本、文档和 SHA-256 校验清单。

## 许可

原创代码和文档结构使用 MIT License。素材与商标说明见 [`ASSET-NOTICE.md`](ASSET-NOTICE.md)。
