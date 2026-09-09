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

func printStockQuoteOnce(secid: String) -> Never {
    let semaphore = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 1
    EastMoneyMarketClient().fetch(secid: secid) { result in
        switch result {
        case .success(let quote):
            print(String(
                format: "%@(%@): %.2f %+.2f%%",
                quote.name,
                quote.code,
                quote.latest,
                quote.changePercent
            ))
            exitCode = 0
        case .failure(let error):
            fputs("\(error.localizedDescription)\n", stderr)
        }
        semaphore.signal()
    }
    if semaphore.wait(timeout: .now() + 12) == .timedOut {
        fputs("读取 \(secid) 行情超时\n", stderr)
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
            + "stockPricesEnabled=\(initialStockPricesEnabled) "
            + "cryptoSeconds=\(Int(cryptoRefreshInterval)) "
            + "stockSeconds=\(Int(stockRefreshInterval)) "
            + "stockClosedSeconds=\(Int(stockClosedRefreshInterval)) "
            + "stockCacheWriteSeconds=\(Int(stockCacheWriteInterval)) "
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
    let redrawView = QuotaPanelView(
        frame: NSRect(origin: .zero, size: expandedPanelSize)
    )
    var redrawRequestCount = 0
    let redrawObservation = redrawView.observe(\.needsDisplay) { _, _ in
        redrawRequestCount += 1
    }
    redrawView.followStatusText = "跟随中"
    let followStatusDoesNotInvalidatePanel = redrawRequestCount == 0
    let followStatusValueUpdated = redrawView.followStatusText == "跟随中"
    redrawView.statusText = "已更新"
    let renderedStatusInvalidatesPanel = redrawRequestCount > 0
    withExtendedLifetime(redrawObservation) {}

    let visibleExpandedState = panelMenuControlState(
        isPanelVisible: true,
        isPanelHiddenByUser: false,
        isCollapsed: false,
        isRefreshing: false,
        showsMarketPrices: true,
        showsStockPrices: true
    )
    let hiddenState = panelMenuControlState(
        isPanelVisible: false,
        isPanelHiddenByUser: true,
        isCollapsed: false,
        isRefreshing: false,
        showsMarketPrices: false,
        showsStockPrices: false
    )
    let refreshingState = panelMenuControlState(
        isPanelVisible: true,
        isPanelHiddenByUser: false,
        isCollapsed: true,
        isRefreshing: true,
        showsMarketPrices: true,
        showsStockPrices: false
    )
    let redrawChecks = [
        ("follow-status-invalidated-panel", followStatusDoesNotInvalidatePanel),
        ("follow-status-value-not-updated", followStatusValueUpdated),
        ("rendered-status-did-not-invalidate-panel", renderedStatusInvalidatesPanel),
    ]
    if let failedRedrawCheck = redrawChecks.first(where: { !$0.1 }) {
        fputs("menu-controls-self-test: failed (\(failedRedrawCheck.0))\n", stderr)
        exit(1)
    }

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
        panelVisibilityMenuItemTitle(showPanelEnabled: true) == "显示面板",
        panelVisibilityMenuItemTitle(showPanelEnabled: false) == "隐藏面板",
        visibleExpandedState == PanelMenuControlState(
            showPanelEnabled: false,
            hidePanelEnabled: true,
            collapseTitle: "折叠面板",
            refreshQuotaEnabled: true,
            marketPricesEnabled: true,
            stockPricesEnabled: true
        ),
        hiddenState == PanelMenuControlState(
            showPanelEnabled: true,
            hidePanelEnabled: false,
            collapseTitle: "折叠面板",
            refreshQuotaEnabled: true,
            marketPricesEnabled: false,
            stockPricesEnabled: false
        ),
        refreshingState == PanelMenuControlState(
            showPanelEnabled: false,
            hidePanelEnabled: true,
            collapseTitle: "展开面板",
            refreshQuotaEnabled: false,
            marketPricesEnabled: true,
            stockPricesEnabled: false
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

func runMarketDataSelfTest() -> Never {
    let fetchedAt = Date(timeIntervalSince1970: 1_774_201_200)
    let quoteData = Data(#"""
    {
      "rc": 0,
      "data": {
        "f43": 3560.25,
        "f47": "123456",
        "f48": "-",
        "f57": "000001",
        "f58": "上证指数",
        "f169": 23.83,
        "f170": 0.67
      }
    }
    """#.utf8)
    let quoteResult = EastMoneyMarketClient.decodeQuote(
        data: quoteData,
        secid: "1.000001",
        fetchedAt: fetchedAt
    )
    guard case .success(let quote) = quoteResult,
          quote.name == "上证指数",
          quote.latest == 3560.25,
          quote.volume == 123456,
          quote.amount == nil,
          quote.changePercent == 0.67,
          quote.fetchedAt == fetchedAt
    else {
        fputs("market-data-self-test: quote parsing failed\n", stderr)
        exit(1)
    }

    let nullData = Data(#"{"rc":0,"data":null}"#.utf8)
    let invalidQuote = Data(#"{"rc":0,"data":{"f43":"-","f47":"-","f48":"-","f57":"000001","f58":"上证指数","f169":"-","f170":"-"}}"#.utf8)
    let oversized = Data(
        repeating: 0,
        count: EastMoneyMarketClient.maximumResponseBytes + 1
    )
    guard case .failure = EastMoneyMarketClient.decodeQuote(
        data: nullData,
        secid: "1.000001"
    ), case .failure = EastMoneyMarketClient.decodeQuote(
        data: invalidQuote,
        secid: "1.000001"
    ), case .failure = EastMoneyMarketClient.decodeQuote(
        data: oversized,
        secid: "1.000001"
    ) else {
        fputs("market-data-self-test: invalid response handling failed\n", stderr)
        exit(1)
    }

    let loader = UsageProviderTestLoader(data: quoteData)
    var fetchedQuote: StockQuote?
    let fetchedTask = EastMoneyMarketClient(loader: loader).fetch(
        secid: "1.000001"
    ) {
        if case .success(let value) = $0 { fetchedQuote = value }
    }
    let requestURL = loader.capturedRequests.first?.url?.absoluteString ?? ""
    var redirectProposal = URLRequest(
        url: URL(string: "https://push2delay.eastmoney.com/api/qt/stock/get")!
    )
    redirectProposal.httpMethod = "GET"
    redirectProposal.setValue("secret", forHTTPHeaderField: "Authorization")
    redirectProposal.setValue("session=secret", forHTTPHeaderField: "Cookie")
    let permittedRedirect = permittedHTTPRedirectRequest(
        from: URL(string: "https://push2.eastmoney.com/api/qt/stock/get"),
        to: redirectProposal,
        allowedHosts: [
            "push2.eastmoney.com",
            "push2delay.eastmoney.com",
        ]
    )
    let blockedRedirect = permittedHTTPRedirectRequest(
        from: URL(string: "https://push2.eastmoney.com/api/qt/stock/get"),
        to: URLRequest(url: URL(string: "https://example.com/redirect")!),
        allowedHosts: [
            "push2.eastmoney.com",
            "push2delay.eastmoney.com",
        ]
    )
    let oversizedLoader = UsageProviderTestLoader(
        data: nil,
        error: HTTPDataLoaderError.responseTooLarge
    )
    var oversizedFetchError: Error?
    EastMoneyMarketClient(loader: oversizedLoader).fetch(secid: "1.000001") {
        if case .failure(let error) = $0 { oversizedFetchError = error }
    }
    guard fetchedQuote?.code == "000001",
          fetchedTask === loader.task,
          requestURL.contains("push2.eastmoney.com/api/qt/stock/get"),
          requestURL.contains("secid=1.000001"),
          requestURL.contains("f43"),
          permittedRedirect?.url?.host == "push2delay.eastmoney.com",
          permittedRedirect?.value(forHTTPHeaderField: "Authorization") == nil,
          permittedRedirect?.value(forHTTPHeaderField: "Cookie") == nil,
          blockedRedirect == nil,
          oversizedFetchError as? EastMoneyMarketClientError
            == .responseTooLarge("1.000001")
    else {
        fputs("market-data-self-test: request construction failed\n", stderr)
        exit(1)
    }

    let newConfigJSON = #"""
    {
      "version": 1,
      "theme": {"id":"market","displayName":"Market","title":"Codex","backgroundImage":"quota-panel-background.png"},
      "widgets": {"codexQuota":true,"codexConnection":true,"followStatus":true,"cryptoPrices":true,"stockPrices":true},
      "markets": {"stockQuotes":[{"secid":"1.000001","name":"上证指数","badge":"沪","enabled":true}]},
      "tracking": {"mode":"follow-current-codex-desktop","gapPoints":14,"mascotTopPaddingPoints":7,"fallback":"top-right"},
      "refresh": {"quotaSeconds":300,"cryptoSeconds":5,"stockSeconds":15,"stockClosedSeconds":60,"stockCacheWriteSeconds":60,"followSeconds":0.05}
    }
    """#
    let legacyConfigJSON = #"""
    {
      "version": 1,
      "theme": {"id":"market","displayName":"Market","title":"Codex","backgroundImage":"quota-panel-background.png"},
      "widgets": {"codexQuota":true,"codexConnection":true,"followStatus":true,"marketPrices":true},
      "tracking": {"mode":"follow-current-codex-desktop","gapPoints":14,"mascotTopPaddingPoints":7,"fallback":"top-right"},
      "refresh": {"quotaSeconds":300,"marketSeconds":7,"followSeconds":0.05}
    }
    """#
    let newConfig = try? decodePanelConfig(from: Data(newConfigJSON.utf8))
    let legacyConfig = try? decodePanelConfig(from: Data(legacyConfigJSON.utf8))
    guard newConfig?.widgets.cryptoPrices == true,
          newConfig?.widgets.stockPrices == true,
          newConfig?.refresh.stockSeconds == 15,
          legacyConfig?.widgets.cryptoPrices == true,
          legacyConfig?.widgets.stockPrices == false,
          legacyConfig?.refresh.cryptoSeconds == 7,
          legacyConfig?.refresh.stockSeconds == 30
    else {
        fputs("market-data-self-test: config compatibility failed\n", stderr)
        exit(1)
    }

    func refreshConfig(
        field: String,
        current: Int,
        replacement: String
    ) -> Result<PanelConfig, Error> {
        let json = newConfigJSON.replacingOccurrences(
            of: "\"\(field)\":\(current)",
            with: "\"\(field)\":\(replacement)"
        )
        do {
            return .success(try decodePanelConfig(from: Data(json.utf8)))
        } catch {
            return .failure(error)
        }
    }
    let refreshSpecs = [
        ("cryptoSeconds", 5, 5),
        ("stockSeconds", 15, 15),
        ("stockClosedSeconds", 60, 60),
        ("stockCacheWriteSeconds", 60, 60),
    ]
    for (field, current, minimum) in refreshSpecs {
        guard case .success = refreshConfig(
            field: field,
            current: current,
            replacement: "\(minimum)"
        ), case .success = refreshConfig(
            field: field,
            current: current,
            replacement: "86400"
        ), case .failure(let lowError) = refreshConfig(
            field: field,
            current: current,
            replacement: "\(minimum - 1)"
        ), case .failure(let highError) = refreshConfig(
            field: field,
            current: current,
            replacement: "86401"
        ), lowError.localizedDescription.contains("refresh.\(field)"),
        lowError.localizedDescription.contains("\(minimum)...86400"),
        highError.localizedDescription.contains("refresh.\(field)"),
        highError.localizedDescription.contains("\(minimum)...86400") else {
            fputs("market-data-self-test: \(field) bounds failed\n", stderr)
            exit(1)
        }
    }
    guard case .failure(let nonFiniteError) = refreshConfig(
        field: "cryptoSeconds",
        current: 5,
        replacement: "1e309"
    ), nonFiniteError.localizedDescription.contains("refresh.cryptoSeconds"),
    nonFiniteError.localizedDescription.contains("5...86400") else {
        fputs("market-data-self-test: non-finite interval failed\n", stderr)
        exit(1)
    }

    let duplicateMarkets = Data(#"{"stockQuotes":[{"secid":"1.000001","enabled":true},{"secid":"1.000001","enabled":true}]}"#.utf8)
    let tooManyMarkets = Data(#"{"stockQuotes":[{"secid":"1.000001"},{"secid":"0.399001"},{"secid":"0.399006"},{"secid":"1.000300"},{"secid":"1.000016"},{"secid":"1.000688"}]}"#.utf8)
    let nonASCIIStockCode = Data(#"{"stockQuotes":[{"secid":"1.０００００１"}]}"#.utf8)
    let orderedMarkets = try? JSONDecoder().decode(
        PanelMarkets.self,
        from: Data(#"{"stockQuotes":[{"secid":"0.399006"},{"secid":"1.000001"},{"secid":"0.399001"}]}"#.utf8)
    )
    guard (try? JSONDecoder().decode(
        PanelMarkets.self,
        from: duplicateMarkets
    )) == nil,
    (try? JSONDecoder().decode(
        PanelMarkets.self,
        from: tooManyMarkets
    )) == nil,
    (try? JSONDecoder().decode(
        PanelMarkets.self,
        from: nonASCIIStockCode
    )) == nil,
    orderedMarkets?.stockQuotes.map(\.secid)
        == ["0.399006", "1.000001", "0.399001"] else {
        fputs("market-data-self-test: stock config bounds failed\n", stderr)
        exit(1)
    }

    let iso = ISO8601DateFormatter()
    guard let preOpen = iso.date(from: "2026-07-27T01:29:00Z"),
          let morning = iso.date(from: "2026-07-27T01:30:00Z"),
          let lunch = iso.date(from: "2026-07-27T03:30:00Z"),
          let afternoon = iso.date(from: "2026-07-27T05:00:00Z"),
          let closed = iso.date(from: "2026-07-27T07:00:00Z"),
          let weekend = iso.date(from: "2026-07-25T02:00:00Z"),
          stockSessionPeriod(at: preOpen) == .preOpen,
          stockSessionPeriod(at: morning) == .morningTrading,
          stockSessionPeriod(at: lunch) == .lunchClosed,
          stockSessionPeriod(at: afternoon) == .afternoonTrading,
          stockSessionPeriod(at: closed) == .closed,
          stockSessionPeriod(at: weekend) == .weekend,
          nextStockSessionBoundary(after: preOpen) == morning
    else {
        fputs("market-data-self-test: session schedule failed\n", stderr)
        exit(1)
    }

    var activityTracker = StockActivityTracker()
    activityTracker.reset(signature: nil)
    let firstObservation = activityTracker.observe(
        signature: "stable",
        at: fetchedAt
    )
    let unchanged1 = activityTracker.observe(
        signature: "stable",
        at: fetchedAt.addingTimeInterval(30)
    )
    let unchanged2 = activityTracker.observe(
        signature: "stable",
        at: fetchedAt.addingTimeInterval(60)
    )
    let stale = activityTracker.observe(
        signature: "stable",
        at: fetchedAt.addingTimeInterval(120)
    )
    let recovered = activityTracker.observe(
        signature: "changed",
        at: fetchedAt.addingTimeInterval(150)
    )
    guard firstObservation == .verifying,
          unchanged1 == .verifying,
          unchanged2 == .verifying,
          stale == .stale,
          recovered == .trading,
          activityTracker.unchangedCount == 0,
          activityTracker.unchangedSince == nil else {
        fputs("market-data-self-test: activity tracking failed\n", stderr)
        exit(1)
    }

    let cacheDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "codex-status-panel-stock-cache-\(UUID().uuidString)",
            isDirectory: true
        )
    let cacheURL = cacheDirectory.appendingPathComponent("stock-quotes.json")
    let cache = StockQuoteCache(fileURL: cacheURL)
    var firstCacheSize = Int.max
    do {
        try cache.save(quotes: [quote], savedAt: fetchedAt)
        firstCacheSize = (try cacheURL.resourceValues(
            forKeys: [.fileSizeKey]
        )).fileSize ?? Int.max
        try cache.save(quotes: [quote], savedAt: fetchedAt.addingTimeInterval(1))
    } catch {
        fputs("market-data-self-test: cache write failed: \(error)\n", stderr)
        exit(1)
    }
    let cached = cache.load(allowedSecIDs: ["1.000001"])
    let cacheFiles = (try? FileManager.default.contentsOfDirectory(
        atPath: cacheDirectory.path
    )) ?? []
    let cacheSize = (try? cacheURL.resourceValues(forKeys: [.fileSizeKey]))?
        .fileSize ?? Int.max
    guard cached?.quotes == [quote],
          cacheFiles == ["stock-quotes.json"],
          cacheSize == firstCacheSize,
          cacheSize <= StockQuoteCache.maximumBytes
    else {
        fputs("market-data-self-test: bounded cache failed\n", stderr)
        exit(1)
    }
    let unknownQuote = StockQuote(
        secid: "0.399001",
        code: "399001",
        name: "深证成指",
        latest: 10_842.18,
        change: -34.5,
        changePercent: -0.32,
        volume: 654_321,
        amount: 98_765,
        fetchedAt: fetchedAt
    )
    do {
        try cache.save(
            quotes: [quote, unknownQuote],
            savedAt: fetchedAt.addingTimeInterval(2)
        )
    } catch {
        fputs("market-data-self-test: unknown cache setup failed: \(error)\n", stderr)
        exit(1)
    }
    guard cache.load(allowedSecIDs: ["1.000001"])?.quotes == [quote] else {
        fputs("market-data-self-test: unknown cache filtering failed\n", stderr)
        exit(1)
    }
    try? Data("{invalid".utf8).write(to: cacheURL, options: .atomic)
    guard cache.load(allowedSecIDs: ["1.000001"]) == nil else {
        fputs("market-data-self-test: damaged cache handling failed\n", stderr)
        exit(1)
    }
    try? Data(
        repeating: 0,
        count: StockQuoteCache.maximumBytes + 1
    ).write(to: cacheURL, options: .atomic)
    guard cache.load(allowedSecIDs: ["1.000001"]) == nil else {
        fputs("market-data-self-test: oversized cache handling failed\n", stderr)
        exit(1)
    }
    try? FileManager.default.removeItem(at: cacheDirectory)

    print("market-data-self-test: parser=pass; config=pass; schedule=pass; cache=pass; bounds=pass")
    exit(0)
}

func printPanelPlacementOnce(savedStateOnly: Bool = false) -> Never {
    // CLI 路径也可能需要读取 NSScreen；先显式完成 AppKit 应用初始化。
    _ = NSApplication.shared
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

func printPetWindowDiagnostics() -> Never {
    let diagnostics = PetWindowLocator().windowDiagnostics()
    if diagnostics.isEmpty {
        print("pet-window-diagnostics: 没有可见的 Codex/ChatGPT 窗口")
    } else {
        diagnostics.forEach { print($0) }
    }
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

    guard PetWindowLocator.stateCompatibilitySelfTest(),
          PetWindowLocator.candidateOwnershipSelfTest()
    else {
        fputs("pet-state-compatibility: state parsing or self-window rejection failed\n", stderr)
        exit(1)
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

    print("placement-self-test: 13/13 passed; legacy-state=pass; compact-state=pass; anchor-state=pass; self-window=pass; gap=14.0; centerError=0.0")
    exit(0)
}

private func taskProgressIncrementalFailures(now: Date) throws -> [String] {
    let fileManager = FileManager.default
    let fixtureDirectory = fileManager.temporaryDirectory.appendingPathComponent(
        "codex-status-panel-task-progress-\(UUID().uuidString)",
        isDirectory: true
    )
    try fileManager.createDirectory(
        at: fixtureDirectory,
        withIntermediateDirectories: true
    )
    defer { try? fileManager.removeItem(at: fixtureDirectory) }

    let sessionMetadata = #"{"type":"session_meta","payload":{"thread_source":"user"}}"#
    let userMessage = #"{"type":"event_msg","payload":{"type":"user_message","message":"阶段二增量任务"}}"#
    let started = #"{"type":"event_msg","payload":{"type":"task_started"}}"#
    let completed = #"{"type":"event_msg","payload":{"type":"task_complete"}}"#
    let taskFailed = #"{"type":"event_msg","payload":{"type":"task_failed"}}"#
    let aborted = #"{"type":"event_msg","payload":{"type":"turn_aborted"}}"#
    let request = #"{"type":"response_item","payload":{"type":"function_call","name":"request_user_input","call_id":"call-stage-2"}}"#
    let response = #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"call-stage-2"}}"#
    let noUnreadState = CodexTaskProgressReader.UnreadThreadState(
        ids: [],
        isAvailable: false
    )
    var clockOffset: TimeInterval = 0
    var failures: [String] = []

    func nextDate() -> Date {
        clockOffset += 1
        return now.addingTimeInterval(clockOffset)
    }

    @discardableResult
    func setModificationDate(for url: URL) throws -> Date {
        let date = nextDate()
        try fileManager.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: url.path
        )
        return date
    }

    @discardableResult
    func writeLines(_ lines: [String], to url: URL) throws -> Date {
        let text = lines.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: url, options: .atomic)
        return try setModificationDate(for: url)
    }

    @discardableResult
    func append(_ data: Data, to url: URL) throws -> Date {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        return try setModificationDate(for: url)
    }

    @discardableResult
    func overwriteInPlace(_ lines: [String], at url: URL) throws -> Date {
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: data)
        return try setModificationDate(for: url)
    }

    func makeReader(
        urls: @escaping () -> [URL]
    ) -> CodexTaskProgressReader {
        CodexTaskProgressReader(
            rolloutURLsProvider: urls,
            threadTitlesOverride: [:],
            unreadStateOverride: noUnreadState
        )
    }

    func record(_ name: String, _ condition: @autoclosure () -> Bool) {
        if !condition() { failures.append(name) }
    }

    let lifecycleURL = fixtureDirectory.appendingPathComponent("lifecycle.jsonl")
    try writeLines([sessionMetadata, userMessage, started], to: lifecycleURL)
    let lifecycleReader = makeReader { [lifecycleURL] }
    let initial = lifecycleReader.read(at: nextDate())
    record(
        "initial-rebuild",
        initial.kind == .running
            && initial.items.first?.title == "阶段二增量任务"
            && lifecycleReader.lastReadDiagnostics.fullRebuildCount == 1
            && lifecycleReader.lastReadDiagnostics.bytesRead > 0
    )

    let unchanged = lifecycleReader.read(at: nextDate())
    record(
        "unchanged-zero-read",
        unchanged == initial
            && lifecycleReader.lastReadDiagnostics.bytesRead == 0
            && lifecycleReader.lastReadDiagnostics.cacheHitCount == 1
    )

    let requestData = Data((request + "\n").utf8)
    try append(requestData, to: lifecycleURL)
    let waiting = lifecycleReader.read(at: nextDate())
    record(
        "append-waiting",
        waiting.kind == .waitingForInput
            && lifecycleReader.lastReadDiagnostics.bytesRead == requestData.count
            && lifecycleReader.lastReadDiagnostics.incrementalReadCount == 1
            && lifecycleReader.lastReadDiagnostics.fullRebuildCount == 0
    )

    let responseData = Data((response + "\n").utf8)
    try append(responseData, to: lifecycleURL)
    let resumed = lifecycleReader.read(at: nextDate())
    record(
        "append-resumed",
        resumed.kind == .running
            && lifecycleReader.lastReadDiagnostics.bytesRead == responseData.count
            && lifecycleReader.lastReadDiagnostics.incrementalReadCount == 1
    )

    let completedData = Data((completed + "\n").utf8)
    try append(completedData, to: lifecycleURL)
    let completedSnapshot = lifecycleReader.read(at: nextDate())
    record(
        "append-completed",
        completedSnapshot.kind == .completed
            && lifecycleReader.lastReadDiagnostics.bytesRead == completedData.count
            && lifecycleReader.lastReadDiagnostics.incrementalReadCount == 1
    )

    let partialURL = fixtureDirectory.appendingPathComponent("partial.jsonl")
    try writeLines([sessionMetadata, started], to: partialURL)
    let partialReader = makeReader { [partialURL] }
    _ = partialReader.read(at: nextDate())
    let requestBytes = Data(request.utf8)
    let splitIndex = requestBytes.count / 2
    let firstHalf = requestBytes.subdata(in: 0..<splitIndex)
    let secondHalf = requestBytes.subdata(in: splitIndex..<requestBytes.count)
        + Data("\n".utf8)
    try append(firstHalf, to: partialURL)
    let partialSnapshot = partialReader.read(at: nextDate())
    let firstHalfWasBuffered = partialSnapshot.kind == .running
        && partialReader.lastReadDiagnostics.completeLineCount == 0
    try append(secondHalf, to: partialURL)
    let completedPartialSnapshot = partialReader.read(at: nextDate())
    record(
        "partial-line-once",
        firstHalfWasBuffered
            && completedPartialSnapshot.kind == .waitingForInput
            && partialReader.lastReadDiagnostics.completeLineCount == 1
            && partialReader.lastReadDiagnostics.bytesRead == secondHalf.count
    )

    let truncatedURL = fixtureDirectory.appendingPathComponent("truncated.jsonl")
    try writeLines([sessionMetadata, userMessage, started], to: truncatedURL)
    let truncatedReader = makeReader { [truncatedURL] }
    _ = truncatedReader.read(at: nextDate())
    let truncatedTitle = #"{"type":"event_msg","payload":{"type":"user_message","message":"截断后任务"}}"#
    try overwriteInPlace(
        [sessionMetadata, truncatedTitle, started],
        at: truncatedURL
    )
    let truncatedSnapshot = truncatedReader.read(at: nextDate())
    record(
        "truncated-rebuild",
        truncatedSnapshot.items.first?.title == "截断后任务"
            && truncatedReader.lastReadDiagnostics.fullRebuildCount == 1
    )

    let replacedURL = fixtureDirectory.appendingPathComponent("replaced.jsonl")
    try writeLines([sessionMetadata, userMessage, started], to: replacedURL)
    let replacedReader = makeReader { [replacedURL] }
    _ = replacedReader.read(at: nextDate())
    try fileManager.removeItem(at: replacedURL)
    let replacementTitle = #"{"type":"event_msg","payload":{"type":"user_message","message":"替换后任务"}}"#
    try writeLines([sessionMetadata, replacementTitle, started], to: replacedURL)
    let replacedSnapshot = replacedReader.read(at: nextDate())
    record(
        "same-path-replacement",
        replacedSnapshot.items.first?.title == "替换后任务"
            && replacedReader.lastReadDiagnostics.fullRebuildCount == 1
    )

    let oversizedURL = fixtureDirectory.appendingPathComponent("oversized.jsonl")
    try writeLines([sessionMetadata, started], to: oversizedURL)
    let oversizedReader = makeReader { [oversizedURL] }
    _ = oversizedReader.read(at: nextDate())
    let oversizedRecord = "{\"type\":\"noop\",\"padding\":\""
        + String(repeating: "x", count: 1_048_576 + 1_024)
        + "\"}\n"
    try append(Data(oversizedRecord.utf8), to: oversizedURL)
    let oversizedSnapshot = oversizedReader.read(at: nextDate())
    record(
        "oversized-bounded-rebuild",
        oversizedSnapshot.kind == .running
            && oversizedReader.lastReadDiagnostics.fullRebuildCount == 1
            && oversizedReader.lastReadDiagnostics.incrementalReadCount == 0
            && oversizedReader.lastReadDiagnostics.bytesRead <= 1_048_576
    )

    let irrelevantURL = fixtureDirectory.appendingPathComponent("irrelevant.jsonl")
    try writeLines([sessionMetadata, started], to: irrelevantURL)
    let irrelevantReader = makeReader { [irrelevantURL] }
    _ = irrelevantReader.read(at: nextDate())
    let irrelevantRecord = "{\"type\":\"noop\",\"padding\":\""
        + String(repeating: "界", count: 170_000)
        + "\"}\n"
    let irrelevantData = Data(irrelevantRecord.utf8)
    try append(irrelevantData, to: irrelevantURL)
    let irrelevantSnapshot = irrelevantReader.read(at: nextDate())
    record(
        "irrelevant-byte-filter",
        irrelevantSnapshot.kind == .running
            && irrelevantReader.lastReadDiagnostics.bytesRead == irrelevantData.count
            && irrelevantReader.lastReadDiagnostics.incrementalReadCount == 1
            && irrelevantReader.lastReadDiagnostics.stringFilterLineCount == 0
            && irrelevantReader.lastReadDiagnostics.jsonDecodingAttemptCount == 0
    )

    let middleURL = fixtureDirectory.appendingPathComponent("middle.jsonl")
    let middleTitle = #"{"type":"event_msg","payload":{"type":"user_message","message":"中段读取任务"}}"#
    let middleData = Data(
        (String(repeating: "x", count: 1_048_576 + 4_096)
            + "\n\(middleTitle)\n\(started)\n").utf8
    )
    try middleData.write(to: middleURL, options: .atomic)
    try setModificationDate(for: middleURL)
    let middleReader = makeReader { [middleURL] }
    let middleSnapshot = middleReader.read(at: nextDate())
    record(
        "middle-first-line-discarded",
        middleSnapshot.items.first?.title == "中段读取任务"
            && middleReader.lastReadDiagnostics.bytesRead <= 1_048_576
    )

    let firstCacheURL = fixtureDirectory.appendingPathComponent("cache-1.jsonl")
    let secondCacheURL = fixtureDirectory.appendingPathComponent("cache-2.jsonl")
    let firstCacheTitle = #"{"type":"event_msg","payload":{"type":"user_message","message":"缓存一"}}"#
    let secondCacheTitle = #"{"type":"event_msg","payload":{"type":"user_message","message":"缓存二"}}"#
    try writeLines([sessionMetadata, firstCacheTitle, started], to: firstCacheURL)
    try writeLines([sessionMetadata, secondCacheTitle, started], to: secondCacheURL)
    var cachedURLs = [firstCacheURL]
    let evictionReader = makeReader { cachedURLs }
    _ = evictionReader.read(at: nextDate())
    cachedURLs = [secondCacheURL]
    let secondCacheSnapshot = evictionReader.read(at: nextDate())
    record(
        "cache-eviction",
        secondCacheSnapshot.items.first?.title == "缓存二"
            && evictionReader.lastReadDiagnostics.cacheEntryCount == 1
    )

    let spacedErrorURL = fixtureDirectory.appendingPathComponent("spaced-error.jsonl")
    let spacedError = #"{"type" : "event_msg", "payload" : {"type" : "error"}}"#
    try writeLines([sessionMetadata, spacedError], to: spacedErrorURL)
    let spacedErrorReader = makeReader { [spacedErrorURL] }
    record(
        "spaced-error-marker",
        spacedErrorReader.read(at: nextDate()).kind == .failed
    )

    let semanticURL = fixtureDirectory.appendingPathComponent("semantic.jsonl")
    let unicodeTitle = #"{"type" : "event_msg", "payload" : {"type" : "user_message", "message" : "蓝色小龙任务"}}"#
    let semanticLines = [unicodeTitle, started, request, response, completed]
    try writeLines([sessionMetadata] + semanticLines, to: semanticURL)
    let semanticReader = makeReader { [semanticURL] }
    let semanticSnapshot = semanticReader.read(at: nextDate())
    let referenceSnapshot = CodexTaskProgressReader.parse(
        lines: semanticLines,
        modificationDate: try semanticURL.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate ?? now,
        now: nextDate()
    )
    record("semantic-equivalence", semanticSnapshot == referenceSnapshot)

    let failedURL = fixtureDirectory.appendingPathComponent("task-failed.jsonl")
    try writeLines([sessionMetadata, started], to: failedURL)
    let failedReader = makeReader { [failedURL] }
    _ = failedReader.read(at: nextDate())
    let taskFailedData = Data((taskFailed + "\n").utf8)
    try append(taskFailedData, to: failedURL)
    let failedSnapshot = failedReader.read(at: nextDate())
    record(
        "append-task-failed",
        failedSnapshot.kind == .failed
            && failedReader.lastReadDiagnostics.bytesRead == taskFailedData.count
            && failedReader.lastReadDiagnostics.incrementalReadCount == 1
    )

    let abortedURL = fixtureDirectory.appendingPathComponent("turn-aborted.jsonl")
    try writeLines([sessionMetadata, started], to: abortedURL)
    let abortedReader = makeReader { [abortedURL] }
    _ = abortedReader.read(at: nextDate())
    let abortedData = Data((aborted + "\n").utf8)
    try append(abortedData, to: abortedURL)
    let abortedSnapshot = abortedReader.read(at: nextDate())
    record(
        "append-turn-aborted",
        abortedSnapshot.kind == .failed
            && abortedReader.lastReadDiagnostics.bytesRead == abortedData.count
            && abortedReader.lastReadDiagnostics.incrementalReadCount == 1
    )

    return failures
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
    var boundarySplitMetadata = Data((subagentMetadata + "\n").utf8)
    boundarySplitMetadata.append(Data(
        repeating: 0x78,
        count: 262_144 - boundarySplitMetadata.count - 1
    ))
    // 模拟 256 KiB 读取块在三字节 UTF-8 字符首字节后截断。
    boundarySplitMetadata.append(0xE7)
    guard CodexTaskProgressReader.isUserVisibleSessionMetadata(line: userMetadata),
          !CodexTaskProgressReader.isUserVisibleSessionMetadata(line: subagentMetadata),
          !CodexTaskProgressReader.isUserVisibleSessionMetadata(line: automationMetadata),
          !CodexTaskProgressReader.isUserVisibleSessionMetadata(
              data: boundarySplitMetadata
          )
    else {
        fputs("task non-user session filtering failed\n", stderr)
        exit(1)
    }

    let incrementalFailures: [String]
    do {
        incrementalFailures = try taskProgressIncrementalFailures(now: now)
    } catch {
        fputs(
            "task progress incremental fixture failed: \(error.localizedDescription)\n",
            stderr
        )
        exit(1)
    }
    guard incrementalFailures.isEmpty else {
        fputs(
            "task progress incremental checks failed: "
                + incrementalFailures.joined(separator: ", ")
                + "\n",
            stderr
        )
        exit(1)
    }

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

    print("task-progress-self-test: lifecycle=7/7; title=pass; visibility=pass; filtering=pass; incremental=16/16; animation=4/4; list=pass; layout=pass; icons=4/4")
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
    let switchableRateData = Data(#"{"mode":"quota_limited","isValid":true,"unit":"USD","quota":{"limit":100,"used":6,"remaining":94},"rate_limits":[{"window":"1d","limit":200,"used":19.5068814,"remaining":180.4931186,"reset_at":"2026-07-29T00:00:00+08:00"},{"window":"7d","limit":2000,"used":197.780476,"remaining":1802.219524,"reset_at":"2026-07-31T00:00:00+08:00"}],"usage":{"today":{"total_tokens":123456789}}}"#.utf8)
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
    let switchableRate = try? Sub2APIUsageMapper.presentation(
        from: switchableRateData,
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
    let weeklyRate: QuotaPresentation?
    if let switchableRate,
       let option = switchableRate.rateLimitOptions.first(where: {
           $0.displayName == "7 天"
       })
    {
        weeklyRate = switchableRate.selectingRateLimit(id: option.id)
    } else {
        weeklyRate = nil
    }
    let refreshedWeeklyRate: QuotaPresentation?
    if let switchableRate, let weeklyRate {
        refreshedWeeklyRate = quotaPresentationAfterRefresh(
            previous: weeklyRate,
            result: .success(switchableRate)
        )
    } else {
        refreshedWeeklyRate = nil
    }
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
            switchableRate?.valueText == "剩余 $180.49"
                && switchableRate?.progressPercent == 90
                && switchableRate?.detailText == "今日已用 $19.51"
                && switchableRate?.rateLimitOptions.map(\.displayName)
                    == ["1 天", "7 天"]
                && switchableRate?.selectedRateLimitOption?.displayName
                    == "1 天",
            weeklyRate?.valueText == "剩余 $1802.22"
                && weeklyRate?.progressPercent == 90
                && weeklyRate?.detailText == "今日已用 $19.51"
                && weeklyRate?.selectedRateLimitOption?.displayName
                    == "7 天",
            switchableRate?.cyclingRateLimit() == weeklyRate,
            weeklyRate?.cyclingRateLimit()
                .selectedRateLimitOption?.displayName == "1 天",
            refreshedWeeklyRate?.selectedRateLimitOption?.displayName
                == "7 天"
                && refreshedWeeklyRate?.valueText == "剩余 $1802.22",
            switchableRate?.selectingRateLimit(id: "missing")
                == switchableRate,
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
    case sub2apiRate1d = "sub2api-rate-1d"
    case sub2apiRate7d = "sub2api-rate-7d"
    case sub2apiWarning = "sub2api-warning"
    case sub2apiDanger = "sub2api-danger"
}

private func previewSub2APIRateLimitPresentation(
    selectedIndex: Int
) -> QuotaPresentation {
    let options = [
        QuotaRateLimitOption(
            id: "1d",
            displayName: "1 天",
            valueText: "剩余 $180.49",
            progressPercent: 90,
            isDepleted: false
        ),
        QuotaRateLimitOption(
            id: "7d",
            displayName: "7 天",
            valueText: "剩余 $1802.22",
            progressPercent: 90,
            isDepleted: false
        ),
    ]
    let first = options[0]
    let presentation = QuotaPresentation(
        sourceName: "Sub2API",
        valueText: first.valueText,
        progressPercent: first.progressPercent,
        detailText: "今日已用 $19.51",
        dailyTokenText: "今日Token 1.23亿",
        showsInlineUsageMetrics: true,
        rateLimitOptions: options,
        selectedRateLimitID: first.id,
        isDepleted: false
    )
    return presentation.selectingRateLimit(
        id: options[min(max(0, selectedIndex), options.count - 1)].id
    )
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
    case .sub2apiRate1d:
        return previewSub2APIRateLimitPresentation(selectedIndex: 0)
    case .sub2apiRate7d:
        return previewSub2APIRateLimitPresentation(selectedIndex: 1)
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
    let previewStockConfigurations = Array(
        PanelMarkets.defaults.stockQuotes.prefix(2)
    )
    let previewStockQuotes = [
        StockQuote(
            secid: "1.000001",
            code: "000001",
            name: "上证指数",
            latest: 3_560.25,
            change: 23.83,
            changePercent: 0.67,
            volume: 123_456,
            amount: 987_654_321,
            fetchedAt: Date()
        ),
        StockQuote(
            secid: "0.399001",
            code: "399001",
            name: "深证成指",
            latest: 10_842.18,
            change: -35.20,
            changePercent: -0.32,
            volume: 456_789,
            amount: 123_456_789,
            fetchedAt: Date()
        ),
    ]
    let previewSize = collapsed
        ? collapsedPanelSize
        : panelSizeForTaskRows(
            previewTaskProgress.rowCount,
            showsMarketPrices: true,
            showsStockPrices: true,
            stockRowCount: previewStockConfigurations.count
        )
    let view = QuotaPanelView(frame: NSRect(origin: .zero, size: previewSize))
    view.pointerSide = .bottom
    view.isCollapsed = collapsed
    view.showsMarketPrices = true
    view.showsStockPrices = true
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
    view.stockQuotePresentations = zip(
        previewStockConfigurations,
        previewStockQuotes
    ).map {
        StockQuotePresentation(
            configuration: $0.0,
            quote: $0.1,
            isCached: false,
            isOffline: false
        )
    }
    view.stockMarketState = .trading
    view.stockUpdatedText = "14:32"
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
