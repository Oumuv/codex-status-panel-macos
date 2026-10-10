# Pi CLI 会话状态桥接实施计划

## 目标

在不改变现有 Codex 任务状态行为的前提下，让本机 Pi CLI 的交互会话与 Codex 会话同时显示在状态面板中，并复用现有运行、待确认、完成、失败动效和终端窗口定位能力。

本次开发分支：`codex/pi-cli-status-bridge`。

## 已确认约束

- 当前 Pi `1.0.4` 提供 `agent_start`、`agent_before_settle`、`agent_settled`、`ui_prompt_start`、`ui_prompt_end` 和 `session_shutdown` 扩展事件。
- Pi 持久化 JSONL 不包含全部瞬时生命周期，不能单独可靠判断等待输入、最终 settled 或进程崩溃，因此不作为主状态源。
- Pi 扩展在 TUI、RPC、JSON 和 print 模式均可加载；`--no-extensions` 是明确的降级场景。
- 面板任务刷新周期保持 2 秒；桥接采用本地文件，不增加监听端口或网络请求。
- 安装和卸载必须管理桥接扩展，且不得读取或修改 Pi 的认证文件。
- 用户要求最终重新安装 App 验证。安装前必须备份当前安装并记录用户配置 SHA-256，安装失败时恢复备份。

## 方案

### 1. 中立任务模型

- 为任务增加来源 `codex` / `pi` 和稳定任务 ID。
- 将导航目标从 Codex 专属结构扩展为 Codex App、Codex CLI 和 Pi CLI 三类。
- 展示去重使用稳定任务 ID；没有稳定 ID 时才回退到来源加规范化标题，防止 Codex 与 Pi 同名任务互相覆盖。
- 保持现有状态优先级、排序、终态可见时间和最多五行规则。

### 2. Pi 用户级扩展

新增一个无第三方依赖的 TypeScript 扩展，安装到 Pi agent 目录的 `extensions` 子目录。默认目录为 `~/.pi/agent`，安装脚本同时尊重 `PI_CODING_AGENT_DIR`。

扩展事件映射：

| Pi 事件 | 状态 |
| --- | --- |
| `before_agent_start` / `agent_start` | `running` |
| `ui_prompt_start` | `waitingForInput` |
| `ui_prompt_end` | 有活动 agent 时恢复 `running` |
| `turn_end` / `agent_before_settle` | 缓存 `completed` / `aborted` / `error` 结果 |
| `agent_settled` | `completed` 或 `failed` |
| `session_shutdown` | 停止心跳并写入关闭状态 |

- 每个 Pi 进程写一个 `<pid>.json`，多个终端并发时互不覆盖。
- 使用同目录临时文件加 rename 原子替换。
- 只保存最多 80 字符任务标题（未命名会话可能取首条提示首行片段）、会话 ID、会话文件、cwd、PID、模式和时间戳，不保存其余提示内容、回复、工具参数或凭据。
- 仅在运行和等待输入时刷新心跳；面板忽略心跳过期的活动状态，避免异常退出后长期显示运行中。
- UI 提示使用计数而不是布尔值，兼容并行或嵌套提示。

### 3. 面板读取与聚合

- 新增 `PiTaskProgressReader`，严格校验 schema、字段长度、时间戳、PID 和允许状态。
- 状态目录默认位于 `~/Library/Application Support/io.github.mayday-materials.codex-status-panel/pi-sessions`，支持测试环境变量覆盖。
- `running` / `waitingForInput` 仅在心跳新鲜时显示；`completed` / `failed` 保持现有两分钟可见时间。
- 新增聚合读取器，将 Codex 和 Pi 的 `allItems` 合并后统一排序、去重和截断。
- 任务标题增加紧凑来源前缀 `π`，Codex 文案保持不变。

### 4. 导航

- Pi 状态携带进程 PID。
- 点击 Pi 任务时从 PID 查找 TTY，再复用 Terminal、iTerm2 和 Ghostty 的现有聚焦逻辑。
- PID 已退出、无 TTY 或非 TUI 模式时不错误打开 Codex App，只记录有上下文的标准错误。

### 5. 安装、卸载和检查

- release 包携带桥接扩展。
- 安装器把扩展复制到 Pi 用户扩展目录，并创建状态目录；已有同名文件只由本项目覆盖。
- 卸载器删除项目管理的扩展和 Pi 状态目录，继续保留面板用户配置。
- 安装检查新增桥接扩展存在性检查；Pi 未安装不影响 App 主体运行。
- README 和隐私说明增加 Pi 集成、`/reload` / 重启要求、`--no-extensions` 降级和本地状态字段说明。

## 验证范围

### 核心确定性验证

- 扩展状态协议解析：合法运行、等待、完成、失败、过期心跳、过期终态、畸形数据。
- Codex 与 Pi 合并排序、稳定 ID 去重、同名跨来源保留和五行截断。
- Pi PID 导航目标不回退到 Codex deep link。
- 扩展源码静态检查和事件名称检查。

非核心安装文案和简单文件复制不新增细粒度单元测试，使用 release 重装和安装检查覆盖。

### 构建与回归

以下会读写同一个 App，必须串行执行：

```bash
./scripts/build.sh
./build/Codex\ 状态面板.app/Contents/MacOS/CodexStatusPanel --self-test-task-progress
./build/Codex\ 状态面板.app/Contents/MacOS/CodexStatusPanel --self-test-placement
zsh scripts/test-v1.2-menu-controls.sh
./scripts/test-task-animation-visual.sh
./scripts/privacy-audit.sh
```

### 本机重装验收

1. 备份当前已安装 App、LaunchAgent 和用户配置，记录配置 SHA-256。
2. 构建 release，验证签名、`arm64` / `x86_64` 和包内校验清单。
3. 依次运行 release 卸载器、安装器和检查脚本，禁止直接覆盖 App。
4. 比较安装前后配置 SHA-256，以及 release 与安装二进制 SHA-256。
5. 使用已安装二进制生成关键预览并运行视觉像素检查。
6. 启动真实 Pi 会话，验证 `running`、`waitingForInput`、`completed` 至少三个状态文件和面板读取结果。
7. 点击活动 Pi 任务，确认能聚焦对应终端；若自动化权限阻止聚焦，记录系统返回并验证 PID 到 TTY 的映射。

## 回退

- 代码回退到分支起点 `6d0b03d` 后重新构建 release，并按同一卸载、安装流程恢复。
- 安装失败时使用安装前备份恢复 App 和 LaunchAgent；用户配置始终从备份校验但不覆盖删除。
- 移除 Pi 桥接扩展后，面板自动退化为仅显示 Codex 会话。
