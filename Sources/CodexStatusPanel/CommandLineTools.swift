// 命令行诊断、预览渲染和轻量自测入口。
// 这些函数最终都会调用 exit，因此返回 Never，表示它们不会回到调用位置继续执行。

import AppKit
import CoreGraphics
import Darwin
import Dispatch
import Foundation

func printQuotaOnce() -> Never {
    // CLI 需要打印一次结果后退出；信号量把异步客户端桥接成有超时的同步等待。
    let semaphore = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 1
    CodexQuotaClient().fetch { result in
        switch result {
        case .success(let response):
            let snapshot = codexSnapshot(from: response)
            let remaining = snapshot.primary.map { max(0, 100 - $0.usedPercent) }
                ?? snapshot.individualLimit?.remainingPercent
                ?? 0
            print("codex: remaining=\(remaining)%")
            exitCode = 0
        case .failure(let error):
            fputs("\(error.localizedDescription)\n", stderr)
        }
        semaphore.signal()
    }
    if semaphore.wait(timeout: .now() + 20) == .timedOut {
        fputs("读取额度超时\n", stderr)
    }
    exit(exitCode)
}

func printMarketPriceOnce(symbol: String, label: String) -> Never {
    let semaphore = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 1
    MarketPriceClient(symbol: symbol).fetch { result in
        switch result {
        case .success(let price):
            print(String(format: "\(label): %.2f", price))
            exitCode = 0
        case .failure(let error):
            fputs("\(error.localizedDescription)\n", stderr)
        }
        semaphore.signal()
    }
    if semaphore.wait(timeout: .now() + 12) == .timedOut {
        fputs("读取 \(label) 价格超时\n", stderr)
    }
    exit(exitCode)
}

func printPanelConfiguration() -> Never {
    print(
        "panel-config: version=\(panelVersion) "
            + "bundle=\(panelBundleIdentifier) "
            + "theme=\(panelConfig.theme.id) "
            + "marketPricesEnabled=\(initialMarketPricesEnabled) "
            + "codexConnection=\(panelConfig.widgets.codexConnection) "
            + "followStatus=\(panelConfig.widgets.followStatus) "
            + "width=\(Int(expandedPanelSize.width)) "
            + "height=\(Int(expandedPanelSize.height)) "
            + "gap=\(String(format: "%.1f", panelPetGap))"
    )
    exit(0)
}

func printTaskProgressOnce() -> Never {
    let snapshot = CodexTaskProgressReader().read()
    let details = snapshot.items.enumerated().map { index, item in
        "\(index + 1):\(item.title)[\(item.kind.rawValue)]"
    }.joined(separator: " | ")
    print("task-progress: count=\(snapshot.items.count) \(details)")
    exit(0)
}

func runMenuControlsSelfTest() -> Never {
    let visibleExpandedState = panelMenuControlState(
        isPanelVisible: true,
        isPanelHiddenByUser: false,
        isCollapsed: false,
        isRefreshing: false,
        showsMarketPrices: true
    )
    let hiddenState = panelMenuControlState(
        isPanelVisible: false,
        isPanelHiddenByUser: true,
        isCollapsed: false,
        isRefreshing: false,
        showsMarketPrices: false
    )
    let refreshingState = panelMenuControlState(
        isPanelVisible: true,
        isPanelHiddenByUser: false,
        isCollapsed: true,
        isRefreshing: true,
        showsMarketPrices: true
    )
    let checks = [
        statusBarSymbolName(for: menuBarDisplayState(
            isRefreshing: true,
            codexConnectionStatus: "connected",
            followHealthStatus: "following-pet"
        )) == "arrow.clockwise.circle",
        statusBarSymbolName(for: menuBarDisplayState(
            isRefreshing: false,
            codexConnectionStatus: "disconnected",
            followHealthStatus: "following-pet"
        )) == "bolt.slash.circle",
        statusBarSymbolName(for: menuBarDisplayState(
            isRefreshing: false,
            codexConnectionStatus: "connected",
            followHealthStatus: "screen-fallback"
        )) == "location.slash.circle",
        statusBarSymbolName(for: menuBarDisplayState(
            isRefreshing: false,
            codexConnectionStatus: "connected",
            followHealthStatus: "following-pet"
        )) == "bolt.circle",
        collapsedMenuItemTitle(isCollapsed: false) == "折叠面板",
        collapsedMenuItemTitle(isCollapsed: true) == "展开面板",
        visibleExpandedState == PanelMenuControlState(
            showPanelEnabled: false,
            hidePanelEnabled: true,
            collapseTitle: "折叠面板",
            refreshQuotaEnabled: true,
            marketPricesEnabled: true
        ),
        hiddenState == PanelMenuControlState(
            showPanelEnabled: true,
            hidePanelEnabled: false,
            collapseTitle: "折叠面板",
            refreshQuotaEnabled: true,
            marketPricesEnabled: false
        ),
        refreshingState == PanelMenuControlState(
            showPanelEnabled: false,
            hidePanelEnabled: true,
            collapseTitle: "展开面板",
            refreshQuotaEnabled: false,
            marketPricesEnabled: true
        ),
        resolvedMarketPricesEnabled(
            storedValue: nil,
            configuredDefault: false
        ) == false,
        resolvedMarketPricesEnabled(
            storedValue: true,
            configuredDefault: false
        ) == true,
        resolvedMarketPricesEnabled(
            storedValue: false,
            configuredDefault: true
        ) == false,
        panelConfigFileURL.path.hasSuffix("default-panel-config.json")
            || panelConfigFileURL.path.hasSuffix("/panel-config.json"),
        editablePanelConfigFileURL.path.hasSuffix("/panel-config.json"),
    ]

    guard checks.allSatisfy({ $0 }) else {
        fputs("menu-controls-self-test: failed\n", stderr)
        exit(1)
    }

    print("menu-controls-self-test: passed")
    exit(0)
}

func printPanelPlacementOnce(savedStateOnly: Bool = false) -> Never {
    let locator = PetWindowLocator()
    let result = savedStateOnly ? locator.locateSavedState() : locator.locate()
    guard let location = result else {
        fputs("没有找到已打开的 Codex 桌面窗口或已保存的位置\n", stderr)
        exit(1)
    }

    let placement = panelPlacement(
        petVisibleRect: location.visibleRect,
        panelSize: expandedPanelSize,
        screenVisibleFrame: location.screen.visibleFrame
    )
    print(
        "panel-location: source=\(location.source) "
            + "overlayX=\(Int(location.overlayRect.minX.rounded())) "
            + "overlayY=\(Int(location.overlayRect.minY.rounded())) "
            + "petCenterX=\(Int(location.visibleRect.midX.rounded())) "
            + "petTop=\(Int(location.visibleRect.maxY.rounded())) "
            + "panelX=\(Int(placement.origin.x)) "
            + "panelY=\(Int(placement.origin.y)) "
            + "gap=\(String(format: "%.1f", placement.actualGap)) "
            + "centerError=\(String(format: "%.1f", placement.centerError))"
    )
    exit(0)
}

func runPlacementSelfTest() -> Never {
    struct TestCase {
        let name: String
        let petRect: NSRect
        let panelSize: NSSize
        let screenRect: NSRect
    }

    let cases = [
        TestCase(
            name: "built-in-display",
            petRect: NSRect(x: 1_110, y: 318, width: 163, height: 170),
            panelSize: expandedPanelSize,
            screenRect: NSRect(x: 0, y: 0, width: 1_512, height: 982)
        ),
        TestCase(
            name: "external-negative-origin",
            petRect: NSRect(x: -554, y: 500, width: 163, height: 170),
            panelSize: expandedPanelSize,
            screenRect: NSRect(x: -1_920, y: -98, width: 1_920, height: 1_080)
        ),
        TestCase(
            name: "scaled-pet",
            petRect: NSRect(x: 420, y: 260, width: 204, height: 213),
            panelSize: expandedPanelSize,
            screenRect: NSRect(x: 0, y: 0, width: 1_920, height: 1_080)
        ),
        TestCase(
            name: "collapsed-panel",
            petRect: NSRect(x: 280, y: 210, width: 120, height: 125),
            panelSize: collapsedPanelSize,
            screenRect: NSRect(x: 0, y: 0, width: 1_280, height: 720)
        ),
        TestCase(
            name: "left-screen-edge",
            petRect: NSRect(x: 8, y: 180, width: 80, height: 100),
            panelSize: expandedPanelSize,
            screenRect: NSRect(x: 0, y: 0, width: 1_280, height: 720)
        ),
        TestCase(
            name: "right-screen-edge",
            petRect: NSRect(x: 1_192, y: 180, width: 80, height: 100),
            panelSize: expandedPanelSize,
            screenRect: NSRect(x: 0, y: 0, width: 1_280, height: 720)
        ),
    ]

    for test in cases {
        let placement = panelPlacement(
            petVisibleRect: test.petRect,
            panelSize: test.panelSize,
            screenVisibleFrame: test.screenRect
        )
        guard abs(placement.actualGap - panelPetGap) <= 0.01 else {
            fputs("\(test.name): gap=\(placement.actualGap), expected=\(panelPetGap)\n", stderr)
            exit(1)
        }
        guard abs(placement.centerError) <= 0.01 else {
            fputs("\(test.name): centerError=\(placement.centerError)\n", stderr)
            exit(1)
        }
    }

    let staleStateURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-panel-stale-display-state-\(UUID().uuidString).json")
    let staleState = #"{"electron-avatar-overlay-open":true,"electron-avatar-overlay-bounds":{"x":500,"y":300,"displayId":2,"placement":"top-end","byDisplayId":{"3":{"x":100,"y":300,"width":356,"height":320,"displayId":3,"placement":"top-end","mascot":{"left":221,"top":196,"width":107,"height":116}}}}}"#
    do {
        try Data(staleState.utf8).write(to: staleStateURL)
    } catch {
        fputs("cross-display-stale-anchor: cannot create state fixture: \(error)\n", stderr)
        exit(1)
    }
    defer { try? FileManager.default.removeItem(at: staleStateURL) }
    setenv("CODEX_STATUS_PANEL_STATE_FILE", staleStateURL.path, 1)
    setenv("CODEX_PANEL_STATE_FILE", staleStateURL.path, 1)

    if let staleLocation = PetWindowLocator().locateSavedState() {
        fputs(
            "cross-display-stale-anchor: expected no saved location, got \(staleLocation.source)\n",
            stderr
        )
        exit(1)
    }

    let currentOverlay = NSRect(x: 1_477, y: 50, width: 408, height: 400)
    guard let fallbackRect = geometricFallbackVisibleRect(in: currentOverlay) else {
        fputs("current-window-geometry: expected a fallback rectangle\n", stderr)
        exit(1)
    }
    guard abs(fallbackRect.midX - currentOverlay.midX) <= 0.01 else {
        fputs("current-window-geometry: center mismatch\n", stderr)
        exit(1)
    }
    let expectedTop = currentOverlay.maxY - 274
    guard abs(fallbackRect.maxY - expectedTop) <= 0.01 else {
        fputs("current-window-geometry: top mismatch\n", stderr)
        exit(1)
    }

    print("placement-self-test: 8/8 passed; gap=14.0; centerError=0.0")
    exit(0)
}

func runTaskProgressSelfTest() -> Never {
    let now = Date()
    let started = #"{"type":"event_msg","payload":{"type":"task_started"}}"#
    let completed = #"{"type":"event_msg","payload":{"type":"task_complete"}}"#
    let failed = #"{"type":"event_msg","payload":{"type":"turn_aborted","reason":"interrupted"}}"#
    let request = #"{"type":"response_item","payload":{"type":"function_call","name":"request_user_input","call_id":"call-1"}}"#
    let response = #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"call-1"}}"#
    let lifecycleCases: [(String, [String], Date, TaskProgressKind)] = [
        ("running", [started], now, .running),
        ("waiting", [started, request], now, .waitingForInput),
        ("resumed", [started, request, response], now, .running),
        ("completed", [started, completed], now, .completed),
        ("failed", [started, failed], now, .failed),
        ("fresh-tail-fallback", [], now, .running),
        ("idle", [], now.addingTimeInterval(-31 * 60), .idle),
    ]

    for test in lifecycleCases {
        let result = CodexTaskProgressReader.parse(
            lines: test.1,
            modificationDate: test.2,
            now: now
        )
        guard result.kind == test.3 else {
            fputs("task progress case \(test.0) failed: \(result.kind.rawValue)\n", stderr)
            exit(1)
        }
    }

    let titledUserMessage = ##"{"type":"event_msg","payload":{"type":"user_message","message":"# Files mentioned by the user:\n/a.png\n## My request for Codex:\n列出具体任务名称"}}"##
    let titled = CodexTaskProgressReader.parse(
        lines: [titledUserMessage, started],
        modificationDate: now,
        now: now
    )
    guard titled.items.first?.title == "列出具体任务名称" else {
        fputs("task title extraction failed\n", stderr)
        exit(1)
    }

    let threadID = "12345678-1234-4abc-8def-1234567890ab"
    let rolloutURL = URL(fileURLWithPath: "/tmp/rollout-2026-07-16T16-52-47-\(threadID).jsonl")
    guard CodexTaskProgressReader.resolvedTitle(
        for: rolloutURL,
        indexedTitles: [threadID: "正式任务名称"],
        fallback: "Codex 任务"
    ) == "正式任务名称"
    else {
        fputs("task index title mapping failed\n", stderr)
        exit(1)
    }

    let unreadState = CodexTaskProgressReader.UnreadThreadState(ids: [threadID], isAvailable: true)
    let readState = CodexTaskProgressReader.UnreadThreadState(ids: [], isAvailable: true)
    let unavailableState = CodexTaskProgressReader.UnreadThreadState(ids: [], isAvailable: false)
    let visibilityChecks = [
        CodexTaskProgressReader.shouldDisplay(
            kind: .completed,
            threadID: threadID,
            modificationDate: now.addingTimeInterval(-3600),
            now: now,
            unreadState: unreadState
        ),
        !CodexTaskProgressReader.shouldDisplay(
            kind: .completed,
            threadID: threadID,
            modificationDate: now,
            now: now,
            unreadState: readState
        ),
        CodexTaskProgressReader.shouldDisplay(
            kind: .failed,
            threadID: threadID,
            modificationDate: now,
            now: now,
            unreadState: unavailableState,
            fallbackVisibility: 120
        ),
    ]
    guard visibilityChecks.allSatisfy({ $0 }) else {
        fputs("completed task filtering failed\n", stderr)
        exit(1)
    }

    let userMetadata = #"{"type":"session_meta","payload":{"thread_source":"user","source":{"cli":{}}}}"#
    let subagentMetadata = #"{"type":"session_meta","payload":{"thread_source":"subagent","source":{"subagent":{"thread_spawn":{}}}}}"#
    let automationMetadata = #"{"type":"session_meta","payload":{"thread_source":"automation","source":"vscode"}}"#
    guard CodexTaskProgressReader.isUserVisibleSessionMetadata(line: userMetadata),
          !CodexTaskProgressReader.isUserVisibleSessionMetadata(line: subagentMetadata),
          !CodexTaskProgressReader.isUserVisibleSessionMetadata(line: automationMetadata)
    else {
        fputs("task non-user session filtering failed\n", stderr)
        exit(1)
    }

    let largeRolloutURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "rollout-2026-07-23T12-02-00-66666666-6666-4666-8666-666666666666.jsonl"
        )
    let largeMetadata = "{\"type\":\"session_meta\",\"payload\":{"
        + "\"thread_source\":\"user\",\"padding\":\""
        + String(repeating: "x", count: 40 * 1_024)
        + "\"}}"
    let largeTitle = #"{"type":"event_msg","payload":{"type":"user_message","message":"大文件运行任务"}}"#
    let largeNoopTail = String(
        repeating: #"{"type":"noop","payload":{}}"# + "\n",
        count: 12_000
    )
    let previousRolloutOverride = ProcessInfo.processInfo.environment[
        "CODEX_STATUS_PANEL_TASK_ROLLOUT_FILE"
    ]
    do {
        try Data(
            "\(largeMetadata)\n\(largeTitle)\n\(started)\n\(largeNoopTail)".utf8
        ).write(to: largeRolloutURL)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-31 * 60)],
            ofItemAtPath: largeRolloutURL.path
        )
        setenv(
            "CODEX_STATUS_PANEL_TASK_ROLLOUT_FILE",
            largeRolloutURL.path,
            1
        )
        let largeRolloutSnapshot = CodexTaskProgressReader().read()
        guard largeRolloutSnapshot.items.contains(where: {
            $0.title == "大文件运行任务" && $0.kind == .running
        }) else {
            fputs("large rollout task discovery failed\n", stderr)
            exit(1)
        }
    } catch {
        fputs("large rollout fixture failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
    if let previousRolloutOverride {
        setenv(
            "CODEX_STATUS_PANEL_TASK_ROLLOUT_FILE",
            previousRolloutOverride,
            1
        )
    } else {
        unsetenv("CODEX_STATUS_PANEL_TASK_ROLLOUT_FILE")
    }
    try? FileManager.default.removeItem(at: largeRolloutURL)

    let truncated = TaskProgressSnapshot.displaying((0..<7).map { index in
        TaskProgressItem(title: "任务 \(index + 1)", kind: .running, startedAt: now)
    })
    let sameTitleThreads = TaskProgressSnapshot.displaying([
        TaskProgressItem(title: "相同任务", kind: .running, startedAt: now),
        TaskProgressItem(title: "  相同任务  ", kind: .completed, startedAt: now),
    ])
    guard truncated.items.count == maximumVisibleTaskRows,
          truncated.items.last?.title == "任务 5",
          sameTitleThreads.items.count == 1,
          sameTitleThreads.items.first?.kind == .running
    else {
        fputs("task list truncation or deduplication failed\n", stderr)
        exit(1)
    }

    let oneTaskWithoutMarket = panelSizeForTaskRows(1, showsMarketPrices: false)
    let threeTasksWithMarket = panelSizeForTaskRows(3, showsMarketPrices: true)
    guard abs(
        threeTasksWithMarket.height - oneTaskWithoutMarket.height
            - taskProgressRowHeight * 2
            - marketPriceRowHeight * 2
    ) <= 0.01 else {
        fputs("dynamic panel height failed\n", stderr)
        exit(1)
    }

    let animationChecks = [
        shouldAnimateRunningArrow(
            isWindowVisible: true,
            isCollapsed: false,
            hasRunningTask: true
        ),
        !shouldAnimateRunningArrow(
            isWindowVisible: false,
            isCollapsed: false,
            hasRunningTask: true
        ),
        !shouldAnimateRunningArrow(
            isWindowVisible: true,
            isCollapsed: true,
            hasRunningTask: true
        ),
        !shouldAnimateRunningArrow(
            isWindowVisible: true,
            isCollapsed: false,
            hasRunningTask: false
        ),
    ]
    guard animationChecks.allSatisfy({ $0 }) else {
        fputs("running task animation lifecycle failed\n", stderr)
        exit(1)
    }

    let taskIconNames = [
        "task-running-icon.png",
        "task-waiting-icon.png",
        "task-completed-icon.png",
        "task-failed-icon.png",
    ]
    guard let resourceURL = Bundle.main.resourceURL,
          taskIconNames.allSatisfy({
              NSImage(contentsOf: resourceURL.appendingPathComponent($0)) != nil
          })
    else {
        fputs("task status icon assets failed\n", stderr)
        exit(1)
    }

    print("task-progress-self-test: lifecycle=7/7; title=pass; visibility=pass; filtering=pass; large-rollout=pass; animation=4/4; list=pass; layout=pass; icons=4/4")
    exit(0)
}

func runAuthenticationFallbackSelfTest() -> Never {
    let fixtureDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "codex-status-panel-auth-\(UUID().uuidString)",
            isDirectory: true
        )
    let fixtureURL = fixtureDirectory.appendingPathComponent("config.toml")

    let doubleQuoted = """
    model_provider = "sub2api"
    model = "gpt-5.4"
    [features]
    test = true
    """
    let singleQuoted = """
      model_provider='custom-provider' # active provider
    [model_providers.custom-provider]
    name = "Custom"
    """
    let nestedOnly = """
    [model_providers.custom-provider]
    model_provider = "nested-value"
    """
    let arrayBeforeProvider = """
    allowed_models = [
      "gpt-5.4",
    ]
    model_provider = "array-safe-provider"
    """

    do {
        try FileManager.default.createDirectory(
            at: fixtureDirectory,
            withIntermediateDirectories: true
        )
        try Data(doubleQuoted.utf8).write(to: fixtureURL, options: .atomic)
    } catch {
        try? FileManager.default.removeItem(at: fixtureDirectory)
        fputs("authentication fixture setup failed: \(error)\n", stderr)
        exit(1)
    }

    var unexpectedConfigurationReads = 0
    let nonAuthenticationText = quotaErrorDisplayText(
        QuotaClientError.noResponse
    ) {
        unexpectedConfigurationReads += 1
        return "must-not-be-read"
    }
    let authenticationText = quotaErrorDisplayText(
        QuotaClientError.authentication("chatgpt authentication required")
    ) {
        "sub2api"
    }
    let checks = [
        CodexConfigurationReader.modelProvider(from: doubleQuoted) == "sub2api",
        CodexConfigurationReader.modelProvider(from: singleQuoted)
            == "custom-provider",
        CodexConfigurationReader.modelProvider(from: nestedOnly) == nil,
        CodexConfigurationReader.modelProvider(from: arrayBeforeProvider)
            == "array-safe-provider",
        CodexConfigurationReader.modelProvider(at: fixtureURL) == "sub2api",
        authenticationText == "model_provider: sub2api",
        quotaErrorDisplayText(
            "ChatGPT Authentication token missing",
            modelProvider: nil
        ) == "Codex 未登录或认证已失效",
        nonAuthenticationText == "Codex 暂未返回额度数据",
        unexpectedConfigurationReads == 0,
    ]

    try? FileManager.default.removeItem(at: fixtureDirectory)
    guard checks.allSatisfy({ $0 }) else {
        fputs("authentication-fallback-self-test: failed\n", stderr)
        exit(1)
    }
    print("authentication-fallback-self-test: parser=5/5; presentation=3/3; minimal-read=pass")
    exit(0)
}

func renderPreviewOnce(to outputPath: String, collapsed: Bool) -> Never {
    // 离屏创建 NSView 并缓存到位图，不需要真正显示窗口即可生成 UI 预览 PNG。
    let previewTaskProgress = TaskProgressSnapshot(items: [
        TaskProgressItem(
            title: "web3+ai科普视频",
            kind: .running,
            startedAt: Date()
        ),
        TaskProgressItem(
            title: "蓝色卜卜宠物",
            kind: .completed,
            startedAt: Date()
        ),
    ])
    let previewSize = collapsed
        ? collapsedPanelSize
        : panelSizeForTaskRows(
            previewTaskProgress.rowCount,
            showsMarketPrices: true
        )
    let view = QuotaPanelView(frame: NSRect(origin: .zero, size: previewSize))
    view.pointerSide = .bottom
    view.isCollapsed = collapsed
    view.showsMarketPrices = true
    view.taskProgress = previewTaskProgress
    view.rows = [QuotaRow(
        name: "Codex",
        remainingPercent: 94,
        resetsAt: Calendar.current.date(byAdding: .day, value: 7, to: Date())
    )]
    view.statusText = "12:43"
    view.codexConnectionText = "已连接"
    view.followStatusText = "跟随中"
    view.btcPrice = 64_169.97
    view.btcPriceDirection = 1
    view.btcStatusText = "5秒"
    view.ethPrice = 3_420.18
    view.ethPriceDirection = -1
    view.ethStatusText = "5秒"
    view.layoutSubtreeIfNeeded()

    let scale: CGFloat = 2
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(previewSize.width * scale),
        pixelsHigh: Int(previewSize.height * scale),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fputs("无法创建预览画布\n", stderr)
        exit(1)
    }
    bitmap.size = previewSize

    view.cacheDisplay(in: view.bounds, to: bitmap)

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fputs("无法编码预览图片\n", stderr)
        exit(1)
    }

    do {
        try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        print(outputPath)
        exit(0)
    } catch {
        fputs("写入预览失败：\(error.localizedDescription)\n", stderr)
        exit(1)
    }
}
