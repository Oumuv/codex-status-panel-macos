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
    let provider = makeQuotaUsageProvider(
        configuration: panelConfig.usageProvider
    )
    provider.fetch { result in
        switch result {
        case .success(let presentation):
            print("\(presentation.sourceName): \(presentation.valueText)")
            exitCode = 0
        case .failure(let error):
            let displayText = quotaErrorDisplayText(error) {
                CodexConfigurationReader.modelProvider(
                    at: codexConfigurationURL()
                )
            }
            fputs("\(displayText)\n", stderr)
        }
        semaphore.signal()
    }
    if semaphore.wait(timeout: .now() + 20) == .timedOut {
        fputs("读取用量超时\n", stderr)
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
    let usageSummary = usageProviderDiagnosticSummary(
        panelConfig.usageProvider
    )
    print(
        "panel-config: version=\(panelVersion) "
            + "bundle=\(panelBundleIdentifier) "
            + "theme=\(panelConfig.theme.id) "
            + "marketPricesEnabled=\(initialMarketPricesEnabled) "
            + "usageProvider=\(usageSummary.provider) "
            + "usageProviderConfigured=\(usageSummary.isConfigured) "
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
        statusBarTooltip(
            for: .disconnected,
            quotaSourceName: "Sub2API"
        ) == "Codex 状态面板：Sub2API 未连接",
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

private func usageProviderConfigurationChecks() -> [Bool] {
    let decoder = JSONDecoder()
    let legacyJSON = #"""
    {
      "version": 1,
      "theme": {"id":"legacy","displayName":"Legacy","title":"Codex","backgroundImage":"quota-panel-background.png"},
      "widgets": {"codexQuota":true,"codexConnection":true,"followStatus":true,"marketPrices":false},
      "tracking": {"mode":"follow-current-codex-desktop","gapPoints":14,"mascotTopPaddingPoints":7,"fallback":"top-right"},
      "refresh": {"quotaSeconds":300,"marketSeconds":5,"followSeconds":0.03}
    }
    """#
    let missingProviderJSON = #"{"baseUrl":"https://example.com","apiKey":"self-test-key"}"#
    let malformedProviderFieldJSON = #"""
    {
      "version": 1,
      "usageProvider": {"baseUrl":"https://example.com","apiKey":123,"modelProvider":"sub2api"},
      "theme": {"id":"invalid","displayName":"Invalid","title":"Codex","backgroundImage":"quota-panel-background.png"},
      "widgets": {"codexQuota":true,"codexConnection":true,"followStatus":true,"marketPrices":false},
      "tracking": {"mode":"follow-current-codex-desktop","gapPoints":14,"mascotTopPaddingPoints":7,"fallback":"top-right"},
      "refresh": {"quotaSeconds":300,"marketSeconds":5,"followSeconds":0.03}
    }
    """#
    let malformedProviderObjectJSON = malformedProviderFieldJSON
        .replacingOccurrences(
            of: #"{"baseUrl":"https://example.com","apiKey":123,"modelProvider":"sub2api"}"#,
            with: "123"
        )
    let legacyConfig = try? decodePanelConfig(from: Data(legacyJSON.utf8))
    let defaulted = try? decoder.decode(
        UsageProviderConfiguration.self,
        from: Data(missingProviderJSON.utf8)
    )
    let malformedFieldConfig = try? decodePanelConfig(
        from: Data(malformedProviderFieldJSON.utf8)
    )
    let malformedObjectConfig = try? decodePanelConfig(
        from: Data(malformedProviderObjectJSON.utf8)
    )
    let malformedPanelConfigRejected = (
        try? decodePanelConfig(from: Data("{".utf8))
    ) == nil

    let codexDisabled: Bool
    if case .success(.codex) = resolveUsageProviderConfiguration(nil) {
        codexDisabled = true
    } else {
        codexDisabled = false
    }

    let emptyDisabled: Bool
    if case .success(.codex) = resolveUsageProviderConfiguration(
        UsageProviderConfiguration(
            baseUrl: "",
            apiKey: "",
            modelProvider: "sub2api"
        )
    ) {
        emptyDisabled = true
    } else {
        emptyDisabled = false
    }

    let uppercaseAccepted: Bool
    if case let .success(.sub2api(baseURL, apiKey)) = resolveUsageProviderConfiguration(
        UsageProviderConfiguration(
            baseUrl: "https://example.com/proxy/",
            apiKey: " self-test-key ",
            modelProvider: " SUB2API "
        )
    ) {
        uppercaseAccepted = baseURL.absoluteString == "https://example.com/proxy/"
            && apiKey == "self-test-key"
    } else {
        uppercaseAccepted = false
    }

    let emptyProviderAccepted: Bool
    if case .success(.sub2api) = resolveUsageProviderConfiguration(
        UsageProviderConfiguration(
            baseUrl: "https://example.com",
            apiKey: "self-test-key",
            modelProvider: "  "
        )
    ) {
        emptyProviderAccepted = true
    } else {
        emptyProviderAccepted = false
    }

    let missingURLRejected = resolveUsageProviderConfiguration(
        UsageProviderConfiguration(
            baseUrl: "",
            apiKey: "self-test-key",
            modelProvider: "sub2api"
        )
    ) == .failure(.missingBaseURL)
    let missingKeyRejected = resolveUsageProviderConfiguration(
        UsageProviderConfiguration(
            baseUrl: "https://example.com",
            apiKey: "",
            modelProvider: "sub2api"
        )
    ) == .failure(.missingAPIKey)
    let invalidURLRejected = resolveUsageProviderConfiguration(
        UsageProviderConfiguration(
            baseUrl: "file:///tmp/usage",
            apiKey: "self-test-key",
            modelProvider: "sub2api"
        )
    ) == .failure(.invalidBaseURL)
    let queryRejected = resolveUsageProviderConfiguration(
        UsageProviderConfiguration(
            baseUrl: "https://example.com?token=value",
            apiKey: "self-test-key",
            modelProvider: "sub2api"
        )
    ) == .failure(.invalidBaseURL)
    let fragmentRejected = resolveUsageProviderConfiguration(
        UsageProviderConfiguration(
            baseUrl: "https://example.com#usage",
            apiKey: "self-test-key",
            modelProvider: "sub2api"
        )
    ) == .failure(.invalidBaseURL)
    let userInfoRejected = resolveUsageProviderConfiguration(
        UsageProviderConfiguration(
            baseUrl: "https://demo:secret@localhost",
            apiKey: "self-test-key",
            modelProvider: "sub2api"
        )
    ) == .failure(.invalidBaseURL)
    let unknownRejected = resolveUsageProviderConfiguration(
        UsageProviderConfiguration(
            baseUrl: "https://example.com",
            apiKey: "self-test-key",
            modelProvider: "other"
        )
    ) == .failure(.unsupportedModelProvider)
    let controlCharacterKeyRejected = resolveUsageProviderConfiguration(
        UsageProviderConfiguration(
            baseUrl: "https://example.com",
            apiKey: "self-test\r\nkey",
            modelProvider: "sub2api"
        )
    ) == .failure(.invalidAPIKey)
    let oversizedKeyRejected = resolveUsageProviderConfiguration(
        UsageProviderConfiguration(
            baseUrl: "https://example.com",
            apiKey: String(repeating: "k", count: 129),
            modelProvider: "sub2api"
        )
    ) == .failure(.invalidAPIKey)
    let summary = usageProviderDiagnosticSummary(
        UsageProviderConfiguration(
            baseUrl: "https://example.com",
            apiKey: "self-test-key",
            modelProvider: "sub2api"
        )
    )

    return [
        legacyConfig?.usageProvider == nil,
        defaulted?.modelProvider == "sub2api",
        codexDisabled,
        emptyDisabled,
        uppercaseAccepted,
        emptyProviderAccepted,
        missingURLRejected,
        missingKeyRejected,
        invalidURLRejected,
        queryRejected,
        fragmentRejected,
        userInfoRejected,
        unknownRejected,
        malformedFieldConfig.map {
            resolveUsageProviderConfiguration($0.usageProvider)
                == .failure(.invalidFormat)
        } == true,
        malformedObjectConfig.map {
            resolveUsageProviderConfiguration($0.usageProvider)
                == .failure(.invalidFormat)
        } == true,
        malformedPanelConfigRejected,
        controlCharacterKeyRejected,
        oversizedKeyRejected,
        summary == UsageProviderDiagnosticSummary(
            provider: "sub2api",
            isConfigured: true
        ),
        !String(describing: summary).contains("self-test-key"),
    ]
}

private func codexProviderChecks() -> [Bool] {
    let primary = RateLimitsResult(
        rateLimits: RateLimitSnapshot(
            limitId: "codex",
            limitName: "Codex",
            primary: RateLimitWindow(
                usedPercent: 6,
                windowDurationMins: 10_080,
                resetsAt: nil
            ),
            secondary: nil,
            individualLimit: nil
        ),
        rateLimitsByLimitId: nil
    )
    let individual = RateLimitsResult(
        rateLimits: RateLimitSnapshot(
            limitId: "codex",
            limitName: "Codex",
            primary: nil,
            secondary: nil,
            individualLimit: SpendControlLimit(
                remainingPercent: 20,
                resetsAt: 1_800_000_000
            )
        ),
        rateLimitsByLimitId: nil
    )
    let primaryPresentation = try? codexQuotaPresentation(from: primary)
    let individualPresentation = try? codexQuotaPresentation(from: individual)
    return [
        primaryPresentation == QuotaPresentation(
            sourceName: "Codex",
            valueText: "剩余 94%",
            progressPercent: 94,
            detailText: "已用 6%",
            isDepleted: false
        ),
        individualPresentation?.progressPercent == 20,
        individualPresentation?.valueText == "剩余 20%",
    ]
}

private func quotaUIContractChecks() -> [Bool] {
    let normal = QuotaPresentation(
        sourceName: "Sub2API",
        valueText: "剩余 46%",
        progressPercent: 46,
        detailText: "",
        isDepleted: false
    )
    let warning = QuotaPresentation(
        sourceName: "Sub2API",
        valueText: "剩余 45%",
        progressPercent: 45,
        detailText: "",
        isDepleted: false
    )
    let danger = QuotaPresentation(
        sourceName: "Sub2API",
        valueText: "剩余 20%",
        progressPercent: 20,
        detailText: "",
        isDepleted: false
    )
    let wallet = QuotaPresentation(
        sourceName: "Sub2API",
        valueText: "剩余 $12.34",
        progressPercent: nil,
        detailText: "",
        dailyTokenText: "今日Token 1.23亿",
        showsInlineUsageMetrics: true,
        isDepleted: false
    )
    let emptyWallet = QuotaPresentation(
        sourceName: "Sub2API",
        valueText: "剩余 $0.00",
        progressPercent: nil,
        detailText: "",
        dailyTokenText: "今日Token 0.00亿",
        showsInlineUsageMetrics: true,
        isDepleted: true
    )
    let failure: Result<QuotaPresentation, Error> = .failure(
        QuotaPresentationError.noDisplayableUsage
    )

    return [
        quotaDisplayTone(for: normal) == .normal,
        quotaDisplayTone(for: warning) == .warning,
        quotaDisplayTone(for: danger) == .danger,
        quotaDisplayTone(for: wallet) == .normal
            && wallet.progressPercent == nil,
        quotaDisplayTone(for: emptyWallet) == .danger
            && emptyWallet.progressPercent == nil,
        quotaPresentationAfterRefresh(
            previous: wallet,
            result: failure
        ) == wallet,
        quotaPresentationAfterRefresh(
            previous: nil,
            result: failure
        ) == nil,
        quotaPresentationAfterRefresh(
            previous: wallet,
            result: .success(normal)
        ) == normal,
    ]
}

private final class UsageProviderTestTask: HTTPDataTasking {
    private(set) var isCancelled = false

    func cancel() {
        isCancelled = true
    }
}

private final class UsageProviderTestLoader: HTTPDataLoading {
    var capturedRequests: [URLRequest] = []
    var data: Data?
    var statusCode: Int
    var error: Error?
    var completes = true
    let task = UsageProviderTestTask()

    init(data: Data?, statusCode: Int = 200, error: Error? = nil) {
        self.data = data
        self.statusCode = statusCode
        self.error = error
    }

    func loadData(
        with request: URLRequest,
        completion: @escaping (Data?, URLResponse?, Error?) -> Void
    ) -> HTTPDataTasking {
        capturedRequests.append(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )
        if completes {
            completion(data, response, error)
        }
        return task
    }
}

private func fetchedPresentation(
    provider: QuotaUsageFetching
) -> Result<QuotaPresentation, Error>? {
    let semaphore = DispatchSemaphore(value: 0)
    var captured: Result<QuotaPresentation, Error>?
    provider.fetch {
        captured = $0
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 1)
    return captured
}

private func sub2APIProviderChecks() -> (
    url: [Bool],
    request: [Bool],
    mapping: [Bool],
    errors: [Bool]
) {
    let root = URL(string: "https://example.com")!
    let prefixed = URL(string: "https://example.com/proxy/")!
    let walletData = Data(#"{"mode":"unrestricted","isValid":true,"planName":"钱包余额","unit":"USD","remaining":12.34,"balance":12.34,"usage":{"today":{"total_tokens":123456789}},"unknown":"ignored"}"#.utf8)
    let loader = UsageProviderTestLoader(data: walletData)
    let client = try! Sub2APIUsageClient(
        baseURL: root,
        apiKey: "self-test-key",
        loader: loader
    )
    let walletResult = fetchedPresentation(provider: client)
    let request = loader.capturedRequests.first

    let quotaData = Data(#"{"mode":"quota_limited","isValid":true,"quota":{"limit":100,"used":6,"remaining":94,"unit":"USD"},"usage":{"today":{"total_tokens":123456789}}}"#.utf8)
    let rateData = Data(#"{"mode":"quota_limited","isValid":true,"unit":"USD","rate_limits":[{"window":"5h","limit":20,"used":12,"remaining":8,"reset_at":"2026-07-25T00:00:00Z"},{"window":"1d","limit":100,"used":10,"remaining":90}],"usage":{"today":{"total_tokens":123456789}}}"#.utf8)
    let subscriptionData = Data(#"{"mode":"unrestricted","isValid":true,"planName":"Pro","unit":"USD","subscription":{"daily_usage_usd":2,"daily_limit_usd":10,"weekly_usage_usd":70,"weekly_limit_usd":100,"monthly_usage_usd":5,"monthly_limit_usd":100,"weekly_window_start":"2026-07-20T00:00:00Z"},"usage":{"today":{"total_tokens":123456789}}}"#.utf8)
    let zeroWalletData = Data(#"{"mode":"unrestricted","isValid":true,"unit":"USD","balance":0,"usage":{"today":{"total_tokens":0}}}"#.utf8)
    let walletWithoutUsageData = Data(#"{"mode":"unrestricted","isValid":true,"unit":"USD","balance":9.99}"#.utf8)
    let emptyData = Data(#"{"mode":"unrestricted","isValid":true}"#.utf8)
    let incompleteQuotaData = Data(#"{"mode":"quota_limited","isValid":true,"quota":{"limit":100,"unit":"USD"}}"#.utf8)
    let inactiveData = Data(#"{"mode":"unrestricted","isValid":false,"unit":"USD","balance":12.34}"#.utf8)
    let extremeQuotaData = Data(#"{"mode":"quota_limited","isValid":true,"quota":{"limit":1e-308,"remaining":1e308,"unit":"USD"}}"#.utf8)
    let fixedNow = Date(timeIntervalSince1970: 1_774_000_000)

    let quota = try? Sub2APIUsageMapper.presentation(
        from: quotaData,
        now: fixedNow
    )
    let rate = try? Sub2APIUsageMapper.presentation(
        from: rateData,
        now: fixedNow
    )
    let subscription = try? Sub2APIUsageMapper.presentation(
        from: subscriptionData,
        now: fixedNow
    )
    let zeroWallet = try? Sub2APIUsageMapper.presentation(
        from: zeroWalletData,
        now: fixedNow
    )
    let walletWithoutUsage = try? Sub2APIUsageMapper.presentation(
        from: walletWithoutUsageData,
        now: fixedNow
    )
    let extremeQuota = try? Sub2APIUsageMapper.presentation(
        from: extremeQuotaData,
        now: fixedNow
    )
    var boundedBuffer = BoundedHTTPResponseBuffer(maximumBytes: 4)
    let acceptedAtLimit = boundedBuffer.append(Data(repeating: 1, count: 4))
    let rejectedPastLimit = !boundedBuffer.append(Data([2]))

    let timeoutLoader = UsageProviderTestLoader(data: walletData)
    timeoutLoader.completes = false
    let timeoutClient = try! Sub2APIUsageClient(
        baseURL: root,
        apiKey: "self-test-key",
        loader: timeoutLoader,
        totalTimeout: 0.01
    )
    let absoluteTimeoutText: String?
    if case let .failure(error)? = fetchedPresentation(
        provider: timeoutClient
    ) {
        absoluteTimeoutText = error.localizedDescription
    } else {
        absoluteTimeoutText = nil
    }
    let wallet: QuotaPresentation?
    if case let .success(value)? = walletResult {
        wallet = value
    } else {
        wallet = nil
    }

    func normalizedURL(_ value: String) -> String? {
        guard let url = URL(string: value) else { return nil }
        return try? sub2APIUsageURL(from: url).absoluteString
    }

    func errorText(
        status: Int,
        data: Data? = walletData,
        error: Error? = nil
    ) -> String? {
        let stub = UsageProviderTestLoader(
            data: data,
            statusCode: status,
            error: error
        )
        let testClient = try! Sub2APIUsageClient(
            baseURL: root,
            apiKey: "self-test-key",
            loader: stub
        )
        if case let .failure(failure)? = fetchedPresentation(
            provider: testClient
        ) {
            return failure.localizedDescription
        }
        return nil
    }

    let invalidConfigurationProvider = makeQuotaUsageProvider(
        configuration: UsageProviderConfiguration(
            baseUrl: "https://example.com",
            apiKey: "",
            modelProvider: "sub2api"
        ),
        loader: loader
    )
    let invalidConfigurationText: String?
    if case let .failure(error)? = fetchedPresentation(
        provider: invalidConfigurationProvider
    ) {
        invalidConfigurationText = error.localizedDescription
    } else {
        invalidConfigurationText = nil
    }

    return (
        url: [
            normalizedURL("https://example.com")
                == "https://example.com/v1/usage",
            normalizedURL("https://example.com:18443")
                == "https://example.com:18443/v1/usage",
            normalizedURL("https://example.com/v1")
                == "https://example.com/v1/usage",
            normalizedURL("https://example.com/v1/usage/")
                == "https://example.com/v1/usage",
            try? sub2APIUsageURL(from: prefixed).absoluteString
                == "https://example.com/proxy/v1/usage",
        ].map { $0 == true },
        request: [
            request?.httpMethod == "GET",
            request?.value(forHTTPHeaderField: "Accept")
                == "application/json",
            request?.value(forHTTPHeaderField: "Authorization")
                == "Bearer self-test-key",
            request?.value(forHTTPHeaderField: "x-api-key") == nil,
            request?.url?.query == nil,
            request?.httpBody == nil,
            request?.timeoutInterval == 10,
            request?.cachePolicy == .reloadIgnoringLocalCacheData,
        ],
        mapping: [
            quota?.valueText == "剩余 $94.00"
                && quota?.progressPercent == 94,
            quota?.detailText == "今日已用 $6.00"
                && quota?.dailyTokenText == "今日Token 1.23亿"
                && quota?.showsInlineUsageMetrics == true,
            rate?.valueText == "剩余 $8.00"
                && rate?.detailText == "今日已用 $10.00"
                && rate?.dailyTokenText == "今日Token 1.23亿"
                && rate?.showsInlineUsageMetrics == true,
            subscription?.valueText == "剩余 $30.00"
                && subscription?.detailText == "今日已用 $2.00"
                && subscription?.dailyTokenText == "今日Token 1.23亿"
                && subscription?.showsInlineUsageMetrics == true,
            wallet?.valueText == "剩余 $12.34"
                && wallet?.progressPercent == nil,
            wallet?.detailText.isEmpty == true
                && wallet?.dailyTokenText == "今日Token 1.23亿"
                && wallet?.showsInlineUsageMetrics == true
                && wallet?.isDepleted == false,
            zeroWallet?.isDepleted == true
                && zeroWallet?.progressPercent == nil
                && zeroWallet?.detailText.isEmpty == true
                && zeroWallet?.dailyTokenText == "今日Token 0.00亿",
            walletWithoutUsage?.detailText.isEmpty == true
                && walletWithoutUsage?.dailyTokenText == nil
                && walletWithoutUsage?.valueText == "剩余 $9.99",
            (try? Sub2APIUsageMapper.presentation(
                from: emptyData,
                now: fixedNow
            )) == nil,
            (try? Sub2APIUsageMapper.presentation(
                from: incompleteQuotaData,
                now: fixedNow
            )) == nil,
        ],
        errors: [
            errorText(status: 401)
                == "Sub2API API Key 无效或无权限",
            errorText(
                status: 401,
                error: URLError(.networkConnectionLost)
            ) == "Sub2API API Key 无效或无权限",
            errorText(status: 403)
                == "Sub2API API Key 无效或无权限",
            errorText(status: 429)
                == "Sub2API 请求过于频繁",
            errorText(status: 500)
                == "Sub2API 接口返回 HTTP 500",
            errorText(status: 200, data: Data("not-json".utf8))
                == "Sub2API 响应格式异常",
            errorText(status: 200, data: Data())
                == "Sub2API 返回了空响应",
            errorText(
                status: 200,
                data: Data(repeating: 0, count: 1_048_577)
            ) == "Sub2API 响应过大",
            errorText(status: 200, data: inactiveData)
                == "Sub2API API Key 当前不可用",
            errorText(status: 200, error: URLError(.timedOut))
                == "Sub2API 请求超时",
            errorText(status: 200, error: URLError(.cannotFindHost))
                == "无法连接 Sub2API",
            errorText(
                status: 200,
                error: URLError(.serverCertificateUntrusted)
            ) == "Sub2API TLS 连接失败",
            makeQuotaUsageProvider(configuration: nil)
                is CodexQuotaUsageProvider,
            invalidConfigurationProvider.sourceDisplayName == "Sub2API"
                && invalidConfigurationText
                    == "第三方用量配置缺少 apiKey",
            extremeQuota?.progressPercent == 100,
            acceptedAtLimit && rejectedPastLimit
                && boundedBuffer.data.count == 4,
            absoluteTimeoutText == "Sub2API 请求超时"
                && timeoutLoader.task.isCancelled,
        ]
    )
}

func runUsageProviderSelfTest() -> Never {
    let configChecks = usageProviderConfigurationChecks()
    let codexChecks = codexProviderChecks()
    let uiChecks = quotaUIContractChecks()
    let sub2API = sub2APIProviderChecks()
    guard configChecks.allSatisfy({ $0 }) else {
        fputs("usage-provider-self-test: config failed\n", stderr)
        exit(1)
    }
    guard codexChecks.allSatisfy({ $0 }) else {
        fputs("usage-provider-self-test: codex failed\n", stderr)
        exit(1)
    }
    guard uiChecks.allSatisfy({ $0 }) else {
        fputs("usage-provider-self-test: ui failed\n", stderr)
        exit(1)
    }
    guard sub2API.url.allSatisfy({ $0 }) else {
        fputs("usage-provider-self-test: url failed\n", stderr)
        exit(1)
    }
    guard sub2API.request.allSatisfy({ $0 }) else {
        fputs("usage-provider-self-test: request failed\n", stderr)
        exit(1)
    }
    guard sub2API.mapping.allSatisfy({ $0 }) else {
        fputs("usage-provider-self-test: mapping failed\n", stderr)
        exit(1)
    }
    guard sub2API.errors.allSatisfy({ $0 }) else {
        fputs("usage-provider-self-test: errors failed\n", stderr)
        exit(1)
    }
    print(
        "usage-provider-self-test: "
            + "config=\(configChecks.count)/\(configChecks.count); "
            + "codex=\(codexChecks.count)/\(codexChecks.count); "
            + "ui=\(uiChecks.count)/\(uiChecks.count); "
            + "url=\(sub2API.url.count)/\(sub2API.url.count); "
            + "request=\(sub2API.request.count)/\(sub2API.request.count); "
            + "mapping=\(sub2API.mapping.count)/\(sub2API.mapping.count); "
            + "errors=\(sub2API.errors.count)/\(sub2API.errors.count)"
    )
    exit(0)
}

enum PreviewUsageMode: String {
    case codex
    case unconfigured
    case sub2apiWallet = "sub2api-wallet"
    case sub2apiEmptyWallet = "sub2api-empty-wallet"
    case sub2apiWarning = "sub2api-warning"
    case sub2apiDanger = "sub2api-danger"
}

private func previewQuotaPresentation(
    for mode: PreviewUsageMode
) -> QuotaPresentation? {
    switch mode {
    case .unconfigured:
        return nil
    case .codex:
        return QuotaPresentation(
            sourceName: "Codex",
            valueText: "剩余 94%",
            progressPercent: 94,
            detailText: "已用 6%",
            isDepleted: false
        )
    case .sub2apiWallet:
        return QuotaPresentation(
            sourceName: "Sub2API",
            valueText: "剩余 $12.34",
            progressPercent: nil,
            detailText: "",
            dailyTokenText: "今日Token 1.23亿",
            showsInlineUsageMetrics: true,
            isDepleted: false
        )
    case .sub2apiEmptyWallet:
        return QuotaPresentation(
            sourceName: "Sub2API",
            valueText: "剩余 $0.00",
            progressPercent: nil,
            detailText: "",
            dailyTokenText: "今日Token 0.00亿",
            showsInlineUsageMetrics: true,
            isDepleted: true
        )
    case .sub2apiWarning:
        return QuotaPresentation(
            sourceName: "Sub2API",
            valueText: "剩余 $45.00",
            progressPercent: 45,
            detailText: "今日已用 $55.00",
            dailyTokenText: "今日Token 1.23亿",
            showsInlineUsageMetrics: true,
            isDepleted: false
        )
    case .sub2apiDanger:
        return QuotaPresentation(
            sourceName: "Sub2API",
            valueText: "剩余 $20.00",
            progressPercent: 20,
            detailText: "今日已用 $80.00",
            dailyTokenText: "今日Token 3.45亿",
            showsInlineUsageMetrics: true,
            isDepleted: false
        )
    }
}

func renderPreviewOnce(
    to outputPath: String,
    collapsed: Bool,
    usageMode: PreviewUsageMode
) -> Never {
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
    let presentation = previewQuotaPresentation(for: usageMode)
    if let presentation {
        view.quotaSourceName = presentation.sourceName
        view.quotaPresentation = presentation
    } else {
        view.hasUsageProviderConfiguration = false
        view.errorText = "model_provider: sub2api"
    }
    view.statusText = "12:43"
    view.connectionText = "已连接"
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
