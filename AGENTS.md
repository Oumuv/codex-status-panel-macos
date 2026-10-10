# Repository Guidelines

## 项目结构与模块组织

`Sources/CodexStatusPanel/` 存放 Swift/AppKit 产品代码：`main.swift` 负责 CLI 分发和应用启动，`AppDelegate.swift` 管理生命周期，视图、配置、服务客户端与任务状态分别放在同名职责文件中。`Resources/` 保存 `Info.plist`、默认 JSON 配置和图片资源；`scripts/` 提供构建、测试、发布及隐私审计脚本；`package/` 保存面向用户的安装、检查和卸载命令。`build/` 与 `dist/` 是生成目录，不应提交。

## 构建、测试与开发命令

项目要求 macOS 12.3+ 和 Xcode Command Line Tools。

```bash
./scripts/build.sh
./scripts/test-v1.2-menu-controls.sh
./scripts/test-task-animation-visual.sh
./build/Codex\ 状态面板.app/Contents/MacOS/CodexStatusPanel --self-test-placement
./scripts/privacy-audit.sh
```

`build.sh` 使用 Swift 5 分别编译 `arm64` 与 `x86_64`，生成通用 App。功能修改后运行集成测试；定位逻辑变更时补跑 placement 自测；发布前必须运行隐私审计。仅在准备发布包时执行 `./scripts/build-release.sh`。仅更新版本号时，Codex 不执行构建或回归测试，只做版本一致性和配置格式的静态检查；由用户重新安装后人工验证。

## 编码风格与命名约定

Swift 使用 4 空格缩进，类型采用 `UpperCamelCase`，函数、属性和局部变量采用 `lowerCamelCase`。优先保持每个文件职责单一；不参与继承的类声明为 `final`，实现细节使用 `private`。AppKit 回调中明确处理对象生命周期，异步闭包优先使用 `[weak self]`。错误信息应包含上下文并写入标准错误，不要静默忽略失败。Zsh 脚本保留 `set -euo pipefail`，常量和路径变量使用大写蛇形命名。

## 测试指南

仓库目前没有 XCTest 或覆盖率门槛，回归测试以内置 CLI 自测和 Zsh 集成脚本为主。新增可独立验证的逻辑时，在 `CommandLineTools.swift` 增加确定性自测，并在 `main.swift` 注册 `--self-test-<area>` 参数。测试脚本命名遵循 `scripts/test-v<版本>-<主题>.sh`。涉及界面时使用 `--render-preview <输出.png>` 生成预览并实际检查图片。

## UI 动效交付与视觉验收

动效实现前必须明确触发条件、循环方式、停止条件、减少动态效果行为，以及不同状态和同状态多任务的聚合规则。任务行消失、面板隐藏、窗口被遮挡或视图销毁时必须停止并移除对应动画。

素材视觉中心不得默认使用 `NSImageView` 或素材画布中心；应通过 Alpha 边界或可复现的主体分割得到视觉中心。光环、粒子和其他同源效果必须共享一个几何中心，禁止分别手调补偿值。

涉及光环或粒子位置时，最终验收必须基于 `--render-preview` 生成的 PNG，并运行 `./scripts/test-task-animation-visual.sh`。绿球与外环中心误差不得超过 `0.5pt`，外环横纵直径差不得超过 `0.5pt`，且不得接触预览边界。静态像素检查不能替代对动画节奏和生命周期的实际运行检查。

会重写 `build/` App 的构建和集成测试必须串行执行，不能与读取同一 App 的自测、签名检查或预览命令并发。安装验证需比较用户配置安装前后 SHA-256、安装二进制与 release 二进制 SHA-256，并使用已安装二进制重新生成关键预览。

用户明确要求重装或本机安装验证时，必须先备份当前安装并记录用户配置 SHA-256，再依次执行卸载脚本和 release 包中的安装脚本；禁止用直接覆盖 App 代替卸载重装。安装后必须确认用户配置未变化、安装二进制与 release 二进制一致，并使用已安装二进制生成关键预览。安装失败时应使用安装前备份恢复。

完整流程见 `.docs/superpowers/specs/2026-09-20-macos-panel-animation-delivery-workflow.md`；多任务动画目标规则见 `.docs/superpowers/specs/2026-09-20-task-animation-concurrency-design.md`。

## 提交与 Pull Request

现有历史使用 `类型:版本 简要说明`，例如 `feat:v1.2.1 main职责拆分`。提交应聚焦一个逻辑变更，避免混入生成物或个人配置。Pull Request 需说明动机、影响范围、验证命令与结果；关联相关 Issue。界面或素材变更须附前后截图，并说明 macOS 版本及显示器场景。

## 安全与配置

不要提交 API Key、个人绝对路径、日志、运行状态或用户的 `panel-config.json`。默认配置只在 `Resources/default-panel-config.json` 中维护，新增字段需提供安全默认值并验证旧配置兼容性。发布前检查压缩包不包含 `.env`、日志或健康状态文件。
