// 程序唯一入口：先分发一次性 CLI 命令；没有匹配参数时再启动菜单栏 App。
// 把入口保留在 main.swift，可让 Swift 编译器明确识别这里的顶层可执行代码。

import AppKit
import Darwin
import Foundation

let cliFlags: Set<String> = [
    "--print-quota",
    "--print-btc",
    "--print-eth",
    "--print-panel-location",
    "--print-saved-panel-location",
    "--self-test-placement",
    "--self-test-menu-controls",
    "--self-test-task-progress",
    "--self-test-authentication-fallback",
    "--self-test-usage-provider",
    "--print-panel-config",
    "--print-task-progress",
    "--render-preview",
]
if CommandLine.arguments.contains(where: { cliFlags.contains($0) }) {
    reportPanelConfigWarnings()
}

if CommandLine.arguments.contains("--print-quota") {
    printQuotaOnce()
}

if CommandLine.arguments.contains("--print-btc") {
    printMarketPriceOnce(symbol: "BTCUSDT", label: "BTC/USDT")
}

if CommandLine.arguments.contains("--print-eth") {
    printMarketPriceOnce(symbol: "ETHUSDT", label: "ETH/USDT")
}

if CommandLine.arguments.contains("--print-panel-location") {
    printPanelPlacementOnce()
}

if CommandLine.arguments.contains("--print-saved-panel-location") {
    printPanelPlacementOnce(savedStateOnly: true)
}

if CommandLine.arguments.contains("--self-test-placement") {
    runPlacementSelfTest()
}

if CommandLine.arguments.contains("--self-test-menu-controls") {
    runMenuControlsSelfTest()
}

if CommandLine.arguments.contains("--self-test-task-progress") {
    runTaskProgressSelfTest()
}

if CommandLine.arguments.contains("--self-test-authentication-fallback") {
    runAuthenticationFallbackSelfTest()
}

if CommandLine.arguments.contains("--self-test-usage-provider") {
    runUsageProviderSelfTest()
}

if CommandLine.arguments.contains("--print-panel-config") {
    printPanelConfiguration()
}

if CommandLine.arguments.contains("--print-task-progress") {
    printTaskProgressOnce()
}

if let previewFlag = CommandLine.arguments.firstIndex(of: "--render-preview") {
    guard CommandLine.arguments.indices.contains(previewFlag + 1) else {
        fputs("用法：CodexStatusPanel --render-preview <output.png> [--collapsed] [--preview-usage <mode>]\n", stderr)
        exit(1)
    }
    let usageMode: PreviewUsageMode
    if let modeFlag = CommandLine.arguments.firstIndex(
        of: "--preview-usage"
    ) {
        guard CommandLine.arguments.indices.contains(modeFlag + 1),
              let parsed = PreviewUsageMode(
                rawValue: CommandLine.arguments[modeFlag + 1]
              )
        else {
            fputs("用法：--preview-usage <codex|sub2api-wallet|sub2api-empty-wallet|sub2api-warning|sub2api-danger>\n", stderr)
            exit(1)
        }
        usageMode = parsed
    } else {
        usageMode = .codex
    }
    renderPreviewOnce(
        to: CommandLine.arguments[previewFlag + 1],
        collapsed: CommandLine.arguments.contains("--collapsed"),
        usageMode: usageMode
    )
}

private func runPanelApplication() {
    let singleInstanceLock: SingleInstanceLock
    do {
        singleInstanceLock = try SingleInstanceLock.acquire()
    } catch SingleInstanceLockError.alreadyRunning {
        fputs("已有 Codex 状态面板实例正在运行，本次启动退出。\n", stderr)
        exit(0)
    } catch {
        fputs("单实例锁初始化失败：\(error.localizedDescription)\n", stderr)
        exit(1)
    }

    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    // NSApplication 的 delegate 是弱引用；显式延长两个对象寿命，直到事件循环退出。
    withExtendedLifetime((singleInstanceLock, delegate)) {
        application.run()
    }
}

runPanelApplication()
