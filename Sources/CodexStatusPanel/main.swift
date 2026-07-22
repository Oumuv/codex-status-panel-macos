import AppKit
import CoreGraphics
import Foundation

private let panelVersion = "1.2.0"
private let defaultBundleIdentifier = "io.github.mayday-materials.codex-status-panel"
private let panelBundleIdentifier = Bundle.main.bundleIdentifier ?? defaultBundleIdentifier
private let panelClientName = "codex-status-panel"

private func isFalseEnvironmentValue(_ rawValue: String) -> Bool {
    ["0", "false", "no", "off"].contains(rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
}

private func defaultMarketPricesEnabledFromEnvironment() -> Bool {
    guard let rawValue = ProcessInfo.processInfo.environment["CODEX_STATUS_PANEL_SHOW_MARKET_PRICES"] else {
        return true
    }
    return !isFalseEnvironmentValue(rawValue)
}

private struct PanelConfig: Decodable {
    var version: Int
    var theme: PanelTheme
    var widgets: PanelWidgets
    var tracking: PanelTracking
    var refresh: PanelRefresh

    static let fallback = PanelConfig(
        version: 1,
        theme: PanelTheme(
            id: "codex-default",
            displayName: "Codex Default",
            title: "Codex",
            backgroundImage: "quota-panel-background.png"
        ),
        widgets: PanelWidgets(
            codexQuota: true,
            codexConnection: true,
            followStatus: true,
            marketPrices: defaultMarketPricesEnabledFromEnvironment()
        ),
        tracking: PanelTracking(
            mode: "follow-current-codex-desktop",
            gapPoints: 14,
            mascotTopPaddingPoints: 7,
            fallback: "top-right"
        ),
        refresh: PanelRefresh(
            quotaSeconds: 300,
            marketSeconds: 5,
            followSeconds: 0.03
        )
    )
}

private struct PanelTheme: Decodable {
    var id: String
    var displayName: String
    var title: String
    var backgroundImage: String
}

private struct PanelWidgets: Decodable {
    var codexQuota: Bool
    var codexConnection: Bool
    var followStatus: Bool
    var marketPrices: Bool
}

private struct PanelTracking: Decodable {
    var mode: String
    var gapPoints: CGFloat
    var mascotTopPaddingPoints: CGFloat
    var fallback: String
}

private struct PanelRefresh: Decodable {
    var quotaSeconds: TimeInterval
    var marketSeconds: TimeInterval
    var followSeconds: TimeInterval
}

private struct LoadedPanelConfig {
    let config: PanelConfig
    let warnings: [String]
    let sourceURL: URL?
    let sourceKind: PanelConfigSourceKind
}

private enum PanelConfigSourceKind {
    case environment
    case user
    case bundle
    case fallback
}

private func defaultUserPanelConfigURL() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/\(defaultBundleIdentifier)/panel-config.json")
}

private func bundledDefaultPanelConfigURL() -> URL? {
    Bundle.main.url(forResource: "default-panel-config", withExtension: "json")
}

private func ensureEditablePanelConfigFile() -> URL? {
    if FileManager.default.fileExists(atPath: editablePanelConfigFileURL.path) {
        return editablePanelConfigFileURL
    }

    guard let defaultConfigURL = bundledDefaultPanelConfigURL() else {
        return nil
    }

    do {
        try FileManager.default.createDirectory(
            at: editablePanelConfigFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: defaultConfigURL, to: editablePanelConfigFileURL)
        return editablePanelConfigFileURL
    } catch {
        fputs("panel-config: 无法创建可编辑配置文件：\(error.localizedDescription)\n", stderr)
        return nil
    }
}

private func loadPanelConfig() -> LoadedPanelConfig {
    let decoder = JSONDecoder()
    var warnings: [String] = []

    func decodeConfig(from url: URL, source: String) -> PanelConfig? {
        do {
            let data = try Data(contentsOf: url)
            return try decoder.decode(PanelConfig.self, from: data)
        } catch {
            warnings.append("panel-config: \(source) 无法加载，将继续尝试其他配置源：\(error.localizedDescription)")
            return nil
        }
    }

    if let override = ProcessInfo.processInfo.environment["CODEX_STATUS_PANEL_CONFIG"],
       !override.isEmpty,
       let config = decodeConfig(from: URL(fileURLWithPath: override), source: "CODEX_STATUS_PANEL_CONFIG")
    {
        return LoadedPanelConfig(
            config: config,
            warnings: warnings,
            sourceURL: URL(fileURLWithPath: override),
            sourceKind: .environment
        )
    }

    if let override = ProcessInfo.processInfo.environment["CODEX_PANEL_CONFIG"],
       !override.isEmpty,
       let config = decodeConfig(from: URL(fileURLWithPath: override), source: "CODEX_PANEL_CONFIG")
    {
        return LoadedPanelConfig(
            config: config,
            warnings: warnings,
            sourceURL: URL(fileURLWithPath: override),
            sourceKind: .environment
        )
    }

    let userConfigURL = defaultUserPanelConfigURL()
    if FileManager.default.fileExists(atPath: userConfigURL.path),
       let config = decodeConfig(from: userConfigURL, source: "user panel-config.json")
    {
        return LoadedPanelConfig(
            config: config,
            warnings: warnings,
            sourceURL: userConfigURL,
            sourceKind: .user
        )
    }

    if let resourceURL = bundledDefaultPanelConfigURL(),
       let config = decodeConfig(from: resourceURL, source: "bundle default-panel-config.json")
    {
        return LoadedPanelConfig(
            config: config,
            warnings: warnings,
            sourceURL: resourceURL,
            sourceKind: .bundle
        )
    }

    return LoadedPanelConfig(config: .fallback, warnings: warnings, sourceURL: nil, sourceKind: .fallback)
}

private let loadedPanelConfig = loadPanelConfig()
private let panelConfig = loadedPanelConfig.config
private let panelConfigWarnings = loadedPanelConfig.warnings
private let panelConfigFileURL = loadedPanelConfig.sourceURL ?? defaultUserPanelConfigURL()
private let editablePanelConfigFileURL: URL = {
    switch loadedPanelConfig.sourceKind {
    case .environment, .user:
        return panelConfigFileURL
    case .bundle, .fallback:
        return defaultUserPanelConfigURL()
    }
}()
private let refreshInterval: TimeInterval = max(1, panelConfig.refresh.quotaSeconds)
private let btcRefreshInterval: TimeInterval = max(1, panelConfig.refresh.marketSeconds)
private let marketPricesEnabled: Bool = {
    if let rawValue = ProcessInfo.processInfo.environment["CODEX_STATUS_PANEL_SHOW_MARKET_PRICES"],
       isFalseEnvironmentValue(rawValue)
    {
        return false
    }
    return panelConfig.widgets.marketPrices
}()
// Track fast enough that the panel preserves its visual gap while the pet
// window is moving between animation positions.
private let followInterval: TimeInterval = max(0.01, panelConfig.refresh.followSeconds)
private let expandedPanelSize = NSSize(width: 224, height: marketPricesEnabled ? 160 : 116)
private let collapsedPanelSize = NSSize(width: 64, height: 44)
private let panelPetGap: CGFloat = panelConfig.tracking.gapPoints
private let panelScreenMargin: CGFloat = 8
private let pointerTipBottomInset: CGFloat = 1
private let pointerHorizontalSafeInset: CGFloat = 18
// The v2 sprite has a small transparent top padding inside Codex's stored
// mascot anchor. Add it so the panel measures from Codex desktop visible top tuft.
private let petSpriteTopPaddingInsideAnchor: CGFloat = panelConfig.tracking.mascotTopPaddingPoints

private func reportPanelConfigWarnings() {
    for warning in panelConfigWarnings {
        fputs("\(warning)\n", stderr)
    }
}

private enum MenuBarDisplayState: Equatable {
    case normal
    case refreshing
    case disconnected
    case followAttention
}

private struct PanelMenuControlState: Equatable {
    let showPanelEnabled: Bool
    let hidePanelEnabled: Bool
    let collapseTitle: String
    let refreshQuotaEnabled: Bool
}

private func panelMenuControlState(
    isPanelVisible: Bool,
    isPanelHiddenByUser: Bool,
    isCollapsed: Bool,
    isRefreshing: Bool
) -> PanelMenuControlState {
    PanelMenuControlState(
        showPanelEnabled: isPanelHiddenByUser || !isPanelVisible,
        hidePanelEnabled: isPanelVisible && !isPanelHiddenByUser,
        collapseTitle: collapsedMenuItemTitle(isCollapsed: isCollapsed),
        refreshQuotaEnabled: !isRefreshing
    )
}

private func menuBarDisplayState(
    isRefreshing: Bool,
    codexConnectionStatus: String,
    followHealthStatus: String
) -> MenuBarDisplayState {
    if isRefreshing { return .refreshing }
    if codexConnectionStatus != "connected" { return .disconnected }
    if followHealthStatus == "screen-fallback" || followHealthStatus == "waiting-for-pet" {
        return .followAttention
    }
    return .normal
}

private func statusBarSymbolName(for state: MenuBarDisplayState) -> String {
    switch state {
    case .normal:
        return "bolt.circle"
    case .refreshing:
        return "arrow.clockwise.circle"
    case .disconnected:
        return "bolt.slash.circle"
    case .followAttention:
        return "location.slash.circle"
    }
}

private func statusBarTooltip(for state: MenuBarDisplayState) -> String {
    switch state {
    case .normal:
        return "Codex 状态面板：正常"
    case .refreshing:
        return "Codex 状态面板：正在读取"
    case .disconnected:
        return "Codex 状态面板：Codex 未连接"
    case .followAttention:
        return "Codex 状态面板：跟随目标不可用"
    }
}

private func collapsedMenuItemTitle(isCollapsed: Bool) -> String {
    isCollapsed ? "展开面板" : "折叠面板"
}

private struct PanelPlacement {
    let origin: NSPoint
    let pointerCenterX: CGFloat
    let actualGap: CGFloat
    let centerError: CGFloat
}

/// Places the pointer tip on Codex desktop visible horizontal center and keeps its
/// tip exactly 14 logical points above the visible top tuft. All calculations
/// use AppKit points, so Retina and scaled displays preserve the same spacing.
private func panelPlacement(
    petVisibleRect: NSRect,
    panelSize: NSSize,
    screenVisibleFrame: NSRect
) -> PanelPlacement {
    let minX = screenVisibleFrame.minX + panelScreenMargin
    let maxX = max(minX, screenVisibleFrame.maxX - panelSize.width - panelScreenMargin)
    let desiredX = petVisibleRect.midX - panelSize.width / 2
    let x = min(max(desiredX, minX), maxX)

    let minY = screenVisibleFrame.minY + panelScreenMargin
    let maxY = max(minY, screenVisibleFrame.maxY - panelSize.height - panelScreenMargin)
    let desiredTipY = petVisibleRect.maxY + panelPetGap
    let desiredY = desiredTipY - pointerTipBottomInset
    let y = min(max(desiredY, minY), maxY)

    let originX = x
    let originY = y
    let rawPointerCenterX = petVisibleRect.midX - originX
    let safeMinX = min(pointerHorizontalSafeInset, panelSize.width / 2)
    let safeMaxX = max(safeMinX, panelSize.width - safeMinX)
    let pointerCenterX = min(max(rawPointerCenterX, safeMinX), safeMaxX)
    let actualPointerX = originX + pointerCenterX
    let actualPointerTipY = originY + pointerTipBottomInset

    return PanelPlacement(
        origin: NSPoint(x: originX, y: originY),
        pointerCenterX: pointerCenterX,
        actualGap: actualPointerTipY - petVisibleRect.maxY,
        centerError: actualPointerX - petVisibleRect.midX
    )
}

private func geometricFallbackVisibleRect(in overlayRect: NSRect) -> NSRect? {
    let aspectRatio = overlayRect.width / max(1, overlayRect.height)
    guard overlayRect.width >= 360,
          overlayRect.height >= 360,
          abs(aspectRatio - (408.0 / 400.0)) <= 0.12
    else { return nil }

    let estimatedWidth = overlayRect.width * (107.0 / 408.0)
    let estimatedHeight = max(1, estimatedWidth * (177.0 / 163.0) - petSpriteTopPaddingInsideAnchor)
    let visibleTop = overlayRect.maxY - overlayRect.height * (274.0 / 400.0)
    return NSRect(
        x: overlayRect.midX - estimatedWidth / 2,
        y: visibleTop - estimatedHeight,
        width: estimatedWidth,
        height: estimatedHeight
    )
}

private final class RuntimeHealthWriter {
    private let fileURL: URL = {
        if let override = ProcessInfo.processInfo.environment["CODEX_STATUS_PANEL_HEALTH_FILE"],
           !override.isEmpty
        {
            return URL(fileURLWithPath: override)
        }
        if let override = ProcessInfo.processInfo.environment["CODEX_PANEL_HEALTH_FILE"],
           !override.isEmpty
        {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/\(defaultBundleIdentifier)/panel-health.json")
    }()
    private var lastSignature = ""
    private var lastWriteAt: CFAbsoluteTime = 0

    func write(
        status: String,
        panelVisible: Bool,
        locationSource: String?,
        codexConnectionStatus: String,
        followStatus: String,
        gap: CGFloat? = nil,
        centerError: CGFloat? = nil,
        force: Bool = false
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        let signature = "\(status)|\(panelVisible)|\(locationSource ?? "none")|\(codexConnectionStatus)|\(followStatus)"
        guard force || signature != lastSignature || now - lastWriteAt >= 15 else { return }

        var payload: [String: Any] = [
            "codexConnectionStatus": codexConnectionStatus,
            "followStatus": followStatus,
            "locationSource": locationSource ?? NSNull(),
            "version": panelVersion,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "status": status,
            "panelVisible": panelVisible,
            "marketPricesEnabled": marketPricesEnabled,
            "panelHeightPoints": expandedPanelSize.height,
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        if let gap { payload["petGapPoints"] = gap }
        if let centerError { payload["pointerCenterErrorPoints"] = centerError }

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            try data.write(to: fileURL, options: .atomic)
            lastSignature = signature
            lastWriteAt = now
        } catch {
            // The panel must remain usable even if a managed Mac blocks cache writes.
        }
    }
}

private struct RateLimitWindow: Decodable {
    let usedPercent: Int
    let windowDurationMins: Int64?
    let resetsAt: Int64?
}

private struct SpendControlLimit: Decodable {
    let remainingPercent: Int
    let resetsAt: Int64
}

private struct RateLimitSnapshot: Decodable {
    let limitId: String?
    let limitName: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
    let individualLimit: SpendControlLimit?
}

private struct RateLimitsResult: Decodable {
    let rateLimits: RateLimitSnapshot
    let rateLimitsByLimitId: [String: RateLimitSnapshot]?
}

private struct RPCError: Decodable {
    let message: String
}

private struct RPCResponse: Decodable {
    let id: Int?
    let result: RateLimitsResult?
    let error: RPCError?
}

private struct QuotaRow {
    let name: String
    let remainingPercent: Int
    let resetsAt: Date?
}

private struct BinanceTickerResponse: Decodable {
    let symbol: String
    let price: String
}

private func codexSnapshot(from response: RateLimitsResult) -> RateLimitSnapshot {
    if let snapshots = response.rateLimitsByLimitId {
        if let exactMatch = snapshots["codex"] {
            return exactMatch
        }
        if let idMatch = snapshots.values.first(where: { $0.limitId == "codex" }) {
            return idMatch
        }
    }
    return response.rateLimits
}

private enum PointerSide: Equatable {
    case left
    case right
    case bottom
}

private enum QuotaClientError: LocalizedError {
    case codexNotFound
    case launchFailed(String)
    case noResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .codexNotFound:
            return "没有找到 Codex 本机服务"
        case .launchFailed(let detail):
            return "无法启动 Codex 本机服务：\(detail)"
        case .noResponse:
            return "Codex 暂未返回额度数据"
        case .server(let detail):
            return detail
        }
    }
}

private final class CodexQuotaClient {
    private let decoder = JSONDecoder()

    func fetch(completion: @escaping (Result<RateLimitsResult, Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            completion(self.fetchSynchronously())
        }
    }

    private func fetchSynchronously() -> Result<RateLimitsResult, Error> {
        guard let codexURL = locateCodex() else {
            return .failure(QuotaClientError.codexNotFound)
        }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.executableURL = codexURL
        process.arguments = ["app-server", "--stdio"]
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin

        do {
            try process.run()
        } catch {
            return .failure(QuotaClientError.launchFailed(error.localizedDescription))
        }

        func writeLines(_ lines: [String]) {
            let text = lines.joined(separator: "\n") + "\n"
            if let data = text.data(using: .utf8) {
                stdin.fileHandleForWriting.write(data)
            }
        }

        writeLines([
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"\(panelClientName)\",\"version\":\"\(panelVersion)\"},\"capabilities\":{\"experimentalApi\":true}}}",
        ])

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) {
            if process.isRunning {
                process.terminate()
            }
        }

        var buffer = Data()
        var didSendReadRequest = false
        var finalResponse: RPCResponse?

        readLoop: while process.isRunning {
            let chunk = stdout.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)

            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard !line.isEmpty,
                      let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = object["id"] as? Int
                else { continue }

                if id == 1 && !didSendReadRequest {
                    didSendReadRequest = true
                    writeLines([
                        #"{"jsonrpc":"2.0","method":"initialized"}"#,
                        #"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":null}"#,
                    ])
                    continue
                }

                if id == 2 {
                    finalResponse = try? decoder.decode(RPCResponse.self, from: line)
                    break readLoop
                }
            }
        }

        try? stdin.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()

        if let result = finalResponse?.result {
            return .success(result)
        }
        if let error = finalResponse?.error {
            return .failure(QuotaClientError.server(error.message))
        }

        return .failure(QuotaClientError.noResponse)
    }

    private func locateCodex() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            ProcessInfo.processInfo.environment["CODEX_BIN"],
            home.appendingPathComponent(".local/bin/codex").path,
            home.appendingPathComponent(".codex/packages/standalone/current/bin/codex").path,
            home.appendingPathComponent("Applications/Codex.app/Contents/Resources/codex").path,
            home.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex").path,
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ].compactMap { $0 }

        return candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }).map(URL.init(fileURLWithPath:))
    }
}

private struct MarketPriceClientError: LocalizedError {
    enum Kind {
        case invalidResponse
        case server(Int)
        case invalidPrice
    }

    let symbol: String
    let kind: Kind

    var errorDescription: String? {
        switch kind {
        case .invalidResponse:
            return "\(symbol) 价格暂时无法读取"
        case .server(let statusCode):
            return "\(symbol) 接口返回 \(statusCode)"
        case .invalidPrice:
            return "\(symbol) 价格格式异常"
        }
    }
}

private final class MarketPriceClient {
    private let decoder = JSONDecoder()
    private let symbol: String
    private let endpoint: URL

    init(symbol: String) {
        self.symbol = symbol
        self.endpoint = URL(
            string: "https://data-api.binance.vision/api/v3/ticker/price?symbol=\(symbol)"
        )!
    }

    func fetch(completion: @escaping (Result<Double, Error>) -> Void) {
        var request = URLRequest(url: endpoint)
        let requestedSymbol = symbol
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { [decoder] data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(MarketPriceClientError(symbol: requestedSymbol, kind: .invalidResponse)))
                return
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                completion(.failure(MarketPriceClientError(symbol: requestedSymbol, kind: .server(httpResponse.statusCode))))
                return
            }
            guard let data,
                  let ticker = try? decoder.decode(BinanceTickerResponse.self, from: data),
                  ticker.symbol == requestedSymbol,
                  let price = Double(ticker.price),
                  price > 0
            else {
                completion(.failure(MarketPriceClientError(symbol: requestedSymbol, kind: .invalidPrice)))
                return
            }
            completion(.success(price))
        }.resume()
    }
}

private final class QuotaPanelView: NSView {
    var rows: [QuotaRow] = [] { didSet { needsDisplay = true } }
    var statusText = "正在读取额度…" { didSet { needsDisplay = true } }
    var codexConnectionText = "连接中" { didSet { needsDisplay = true } }
    var followStatusText = "定位中" { didSet { needsDisplay = true } }
    var errorText: String? { didSet { needsDisplay = true } }
    var btcPrice: Double? { didSet { needsDisplay = true } }
    var btcPriceDirection = 0 { didSet { needsDisplay = true } }
    var btcStatusText = "读取中…" { didSet { needsDisplay = true } }
    var ethPrice: Double? { didSet { needsDisplay = true } }
    var ethPriceDirection = 0 { didSet { needsDisplay = true } }
    var ethStatusText = "读取中…" { didSet { needsDisplay = true } }
    var pointerSide: PointerSide = .left {
        didSet {
            guard pointerSide != oldValue else { return }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    var pointerCenterX: CGFloat? {
        didSet {
            guard pointerCenterX != oldValue else { return }
            needsDisplay = true
        }
    }
    var isCollapsed = false {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    var onToggleCollapsed: (() -> Void)?
    private var hideButtonTrackingArea: NSTrackingArea?
    private var isHideButtonHovered = false

    private lazy var backgroundImage: NSImage? = {
        guard let resourceURL = Bundle.main.resourceURL?
            .appendingPathComponent(panelConfig.theme.backgroundImage)
        else { return nil }
        return NSImage(contentsOf: resourceURL)
    }()

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSGraphicsContext.current?.imageInterpolation = .high

        let bodyRect = panelBodyRect()

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.38)
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.set()

        let background = NSColor(calibratedRed: 0.035, green: 0.045, blue: 0.085, alpha: 0.97)
        let border = NSColor.white.withAlphaComponent(0.22)
        let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 17, yRadius: 17)
        background.setFill()
        bodyPath.fill()

        if !isCollapsed, let backgroundImage {
            NSGraphicsContext.saveGraphicsState()
            bodyPath.addClip()
            drawFiveBallBand(backgroundImage, in: bodyRect)
            NSColor.black.withAlphaComponent(0.08).setFill()
            bodyPath.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        border.setStroke()
        bodyPath.lineWidth = 1
        bodyPath.stroke()

        let arrow = NSBezierPath()
        switch pointerSide {
        case .left:
            let centerY = bodyRect.midY
            arrow.move(to: NSPoint(x: bodyRect.minX + 1, y: centerY - 8))
            arrow.line(to: NSPoint(x: 1, y: centerY))
            arrow.line(to: NSPoint(x: bodyRect.minX + 1, y: centerY + 8))
        case .right:
            let centerY = bodyRect.midY
            arrow.move(to: NSPoint(x: bodyRect.maxX - 1, y: centerY - 8))
            arrow.line(to: NSPoint(x: bounds.maxX - 1, y: centerY))
            arrow.line(to: NSPoint(x: bodyRect.maxX - 1, y: centerY + 8))
        case .bottom:
            let requestedCenterX = pointerCenterX ?? bodyRect.midX
            let centerX = min(
                max(requestedCenterX, bodyRect.minX + 12),
                bodyRect.maxX - 12
            )
            arrow.move(to: NSPoint(x: centerX - 8, y: bodyRect.maxY - 1))
            arrow.line(to: NSPoint(x: centerX, y: bounds.maxY - 1))
            arrow.line(to: NSPoint(x: centerX + 8, y: bodyRect.maxY - 1))
        }
        arrow.close()
        background.setFill()
        arrow.fill()
        border.setStroke()
        arrow.lineWidth = 1
        arrow.stroke()

        NSShadow().set()

        if isCollapsed {
            drawText(
                "展开",
                in: NSRect(x: bodyRect.minX, y: 8, width: bodyRect.width, height: 18),
                font: .systemFont(ofSize: 11, weight: .semibold),
                color: NSColor.white.withAlphaComponent(0.92),
                alignment: .center
            )
            return
        }

        let contentX = bodyRect.minX + 14
        let contentWidth = bodyRect.width - 28
        let hideButton = hideButtonRect(in: bodyRect)
        let hideButtonPath = NSBezierPath(roundedRect: hideButton, xRadius: 8, yRadius: 8)
        NSColor.white.withAlphaComponent(isHideButtonHovered ? 0.20 : 0.11).setFill()
        hideButtonPath.fill()
        NSColor.white.withAlphaComponent(isHideButtonHovered ? 0.38 : 0.20).setStroke()
        hideButtonPath.lineWidth = 0.75
        hideButtonPath.stroke()
        drawText(
            "折叠",
            in: NSRect(x: hideButton.minX, y: hideButton.minY + 2, width: hideButton.width, height: 15),
            font: .systemFont(ofSize: 9.5, weight: .medium),
            color: NSColor.white.withAlphaComponent(isHideButtonHovered ? 1.0 : 0.86),
            alignment: .center
        )

        if !panelConfig.widgets.codexQuota {
            drawText(
                panelConfig.theme.title,
                in: NSRect(x: contentX, y: 14, width: contentWidth - 48, height: 18),
                font: .systemFont(ofSize: 12.4, weight: .semibold),
                color: NSColor.white.withAlphaComponent(0.88)
            )
        } else if let errorText {
            drawText(
                errorText,
                in: NSRect(x: contentX, y: 14, width: contentWidth - 48, height: 38),
                font: .systemFont(ofSize: 12, weight: .medium),
                color: NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.38, alpha: 1)
            )
        } else if rows.isEmpty {
            drawText(
                "正在向 Codex 本机服务查询…",
                in: NSRect(x: contentX, y: 14, width: contentWidth - 48, height: 20),
                font: .systemFont(ofSize: 11.5, weight: .medium),
                color: NSColor.white.withAlphaComponent(0.68)
            )
        } else {
            for (index, row) in rows.prefix(1).enumerated() {
                draw(row: row, index: index, x: contentX, width: contentWidth)
            }
        }

        drawText(
            composedStatusText,
            in: NSRect(
                x: contentX,
                y: 77,
                width: contentWidth,
                height: 14
            ),
            font: .systemFont(ofSize: 9.2, weight: .regular),
            color: NSColor.white.withAlphaComponent(0.72),
            alignment: .right
        )

        if marketPricesEnabled {
            drawMarketPriceRow(
                symbol: "BTC/USDT",
                iconText: "₿",
                iconColor: NSColor(calibratedRed: 0.97, green: 0.58, blue: 0.11, alpha: 1),
                price: btcPrice,
                direction: btcPriceDirection,
                statusText: btcStatusText,
                y: 103,
                separatorY: 96,
                contentX: contentX,
                contentWidth: contentWidth
            )
            drawMarketPriceRow(
                symbol: "ETH/USDT",
                iconText: "Ξ",
                iconColor: NSColor(calibratedRed: 0.38, green: 0.45, blue: 0.95, alpha: 1),
                price: ethPrice,
                direction: ethPriceDirection,
                statusText: ethStatusText,
                y: 126,
                separatorY: 122,
                contentX: contentX,
                contentWidth: contentWidth
            )
        }
    }

    private var composedStatusText: String {
        var parts = [statusText]
        if panelConfig.widgets.codexConnection {
            parts.append(codexConnectionText)
        }
        if panelConfig.widgets.followStatus {
            parts.append(followStatusText)
        }
        return parts.joined(separator: " · ")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hideButtonTrackingArea {
            removeTrackingArea(hideButtonTrackingArea)
        }
        guard !isCollapsed else {
            hideButtonTrackingArea = nil
            return
        }
        let trackingArea = NSTrackingArea(
            rect: hideButtonRect(in: panelBodyRect()),
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hideButtonTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHideButtonHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHideButtonHovered = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let bodyRect = panelBodyRect()
        if isCollapsed || hideButtonRect(in: bodyRect).contains(point) {
            onToggleCollapsed?()
            return
        }
        super.mouseDown(with: event)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let clickableRect = isCollapsed ? bounds : hideButtonRect(in: panelBodyRect())
        addCursorRect(clickableRect, cursor: .pointingHand)
    }

    private func panelBodyRect() -> NSRect {
        let arrowWidth: CGFloat = 10
        switch pointerSide {
        case .left:
            return NSRect(x: arrowWidth, y: 3, width: bounds.width - arrowWidth, height: bounds.height - 6)
        case .right:
            return NSRect(x: 0, y: 3, width: bounds.width - arrowWidth, height: bounds.height - 6)
        case .bottom:
            return NSRect(x: 3, y: 3, width: bounds.width - 6, height: bounds.height - arrowWidth - 3)
        }
    }

    private func hideButtonRect(in bodyRect: NSRect) -> NSRect {
        NSRect(x: bodyRect.maxX - 48, y: 10, width: 38, height: 18)
    }

    private func draw(row: QuotaRow, index: Int, x: CGFloat, width: CGFloat) {
        let top = CGFloat(13 + index * 43)
        let remaining = max(0, min(100, row.remainingPercent))
        let valueStart = x + 68
        let valueRight = x + width - 48

        drawText(
            row.name,
            in: NSRect(x: x, y: top, width: 64, height: 16),
            font: .systemFont(ofSize: 10.8, weight: .semibold),
            color: NSColor.white.withAlphaComponent(0.88)
        )
        drawText(
            "剩余 \(remaining)%",
            in: NSRect(x: valueStart, y: top, width: valueRight - valueStart, height: 16),
            font: .monospacedDigitSystemFont(ofSize: 10.8, weight: .semibold),
            color: progressColor(for: remaining),
            alignment: .right
        )

        let trackRect = NSRect(x: x, y: top + 55, width: width, height: 4)
        let track = NSBezierPath(roundedRect: trackRect, xRadius: 2, yRadius: 2)
        NSColor.black.withAlphaComponent(0.30).setFill()
        track.fill()

        let fillWidth = max(3, width * CGFloat(remaining) / 100)
        let fill = NSBezierPath(
            roundedRect: NSRect(x: x, y: top + 55, width: fillWidth, height: 4),
            xRadius: 2,
            yRadius: 2
        )
        progressColor(for: remaining).setFill()
        fill.fill()

        let resetText: String
        if let date = row.resetsAt {
            resetText = "\(Self.resetFormatter.string(from: date)) 重置"
        } else {
            resetText = "重置时间未知"
        }
        drawText(
            resetText,
            in: NSRect(x: x, y: top + 64, width: 94, height: 14),
            font: .systemFont(ofSize: 9.2, weight: .regular),
            color: NSColor.white.withAlphaComponent(0.72)
        )
    }

    private func drawFiveBallBand(_ image: NSImage, in destinationRect: NSRect) {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return }

        // The source is a portrait poster. Its central 32% contains only the
        // five character balls on black; the two MAYDAY text bands sit outside
        // this crop. The crop ratio closely matches the quota panel.
        let sourceRect = NSRect(
            x: 0,
            y: imageSize.height * 0.34,
            width: imageSize.width,
            height: imageSize.height * 0.32
        )

        let imageRect = NSRect(
            x: destinationRect.minX,
            y: destinationRect.minY,
            width: destinationRect.width,
            height: min(93, destinationRect.height)
        )

        image.draw(
            in: imageRect,
            from: sourceRect,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }

    private func drawMarketPriceRow(
        symbol: String,
        iconText: String,
        iconColor: NSColor,
        price: Double?,
        direction: Int,
        statusText: String,
        y: CGFloat,
        separatorY: CGFloat,
        contentX: CGFloat,
        contentWidth: CGFloat
    ) {
        let separator = NSBezierPath()
        separator.move(to: NSPoint(x: contentX, y: separatorY))
        separator.line(to: NSPoint(x: contentX + contentWidth, y: separatorY))
        NSColor.white.withAlphaComponent(0.13).setStroke()
        separator.lineWidth = 0.75
        separator.stroke()

        let iconRect = NSRect(x: contentX, y: y, width: 15, height: 15)
        let icon = NSBezierPath(ovalIn: iconRect)
        iconColor.setFill()
        icon.fill()
        drawText(
            iconText,
            in: NSRect(x: iconRect.minX, y: iconRect.minY + 0.5, width: iconRect.width, height: 14),
            font: .systemFont(ofSize: 10.2, weight: .bold),
            color: .white,
            alignment: .center
        )

        drawText(
            symbol,
            in: NSRect(x: contentX + 20, y: y, width: 62, height: 15),
            font: .systemFont(ofSize: 9.6, weight: .semibold),
            color: NSColor.white.withAlphaComponent(0.78)
        )

        if let price {
            let formattedPrice = Self.btcPriceFormatter.string(from: NSNumber(value: price)) ?? "--"
            drawText(
                formattedPrice,
                in: NSRect(x: contentX + 78, y: y - 1.5, width: 76, height: 17),
                font: .monospacedDigitSystemFont(ofSize: 11.4, weight: .bold),
                color: marketPriceColor(direction: direction),
                alignment: .right
            )
        } else {
            drawText(
                "--",
                in: NSRect(x: contentX + 78, y: y - 1.5, width: 76, height: 17),
                font: .monospacedDigitSystemFont(ofSize: 11.4, weight: .bold),
                color: NSColor.white.withAlphaComponent(0.70),
                alignment: .right
            )
        }

        drawText(
            statusText,
            in: NSRect(x: contentX + 158, y: y + 1, width: contentWidth - 158, height: 14),
            font: .systemFont(ofSize: 8.3, weight: .regular),
            color: NSColor.white.withAlphaComponent(0.54),
            alignment: .right
        )
    }

    private func marketPriceColor(direction: Int) -> NSColor {
        switch direction {
        case 1:
            return NSColor(calibratedRed: 0.24, green: 0.86, blue: 0.58, alpha: 1)
        case -1:
            return NSColor(calibratedRed: 1.0, green: 0.39, blue: 0.43, alpha: 1)
        default:
            return NSColor.white.withAlphaComponent(0.94)
        }
    }

    private func progressColor(for remaining: Int) -> NSColor {
        if remaining <= 20 {
            return NSColor(calibratedRed: 1.0, green: 0.34, blue: 0.39, alpha: 1)
        }
        if remaining <= 45 {
            return NSColor(calibratedRed: 1.0, green: 0.70, blue: 0.22, alpha: 1)
        }
        return NSColor(calibratedRed: 0.22, green: 0.60, blue: 1.0, alpha: 1)
    }

    private func drawText(
        _ text: String,
        in rect: NSRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment = .left
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(
            in: rect,
            withAttributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
                .shadow: Self.textShadow,
            ]
        )
    }

    private static let textShadow: NSShadow = {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.72)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: 1)
        return shadow
    }()

    private static let resetFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "M/d HH:mm"
        return formatter
    }()

    private static let btcPriceFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.usesGroupingSeparator = true
        return formatter
    }()
}

private struct LocatedPet {
    let overlayRect: NSRect
    let visibleRect: NSRect
    let screen: NSScreen
    let source: String
}

private final class PetWindowLocator {
    private struct StoredMascotMetrics {
        let left: CGFloat
        let top: CGFloat
        let width: CGFloat
        let height: CGFloat
        let source: String
    }

    private struct StoredOverlayLocation {
        let rect: CGRect
        let mascot: StoredMascotMetrics?
        let isPrimary: Bool
    }

    private var cachedWindowID: CGWindowID?
    private var cachedMascotMetrics: StoredMascotMetrics?
    private var lastVisualProbeAt: CFAbsoluteTime = 0
    private var lastOverlayStateReadAt: CFAbsoluteTime = 0
    private var storedOverlayLocations: [StoredOverlayLocation] = []
    private var storedDisplayID: String?
    private(set) var overlayOpen: Bool?

    func locate() -> LocatedPet? {
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastOverlayStateReadAt >= 0.10 {
            lastOverlayStateReadAt = now
            refreshStoredOverlayState()
        }

        if let cachedWindowID,
           let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, cachedWindowID) as? [[String: Any]],
           let window = windows.first,
           let candidate = candidate(from: window),
           let location = makeLocation(from: candidate.rect, windowID: cachedWindowID)
        {
            return location
        }

        cachedWindowID = nil
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return storedOverlayLocation()
        }

        let candidates: [(id: CGWindowID, rect: CGRect, score: Double)] = windows.compactMap { window in
            guard let number = window[kCGWindowNumber as String] as? NSNumber,
                  let candidate = candidate(from: window)
            else { return nil }
            return (number.uint32Value, candidate.rect, candidate.score)
        }

        guard let best = candidates.min(by: { $0.score < $1.score }) else {
            return storedOverlayLocation()
        }
        cachedWindowID = best.id
        return makeLocation(from: best.rect, windowID: best.id) ?? storedOverlayLocation()
    }

    func locateSavedState() -> LocatedPet? {
        refreshStoredOverlayState()
        return storedOverlayLocation()
    }

    func reset() {
        cachedWindowID = nil
        cachedMascotMetrics = nil
        lastVisualProbeAt = 0
        lastOverlayStateReadAt = 0
        storedOverlayLocations = []
        storedDisplayID = nil
        overlayOpen = nil
    }

    private func makeLocation(from quartzRect: CGRect, windowID: CGWindowID) -> LocatedPet? {
        guard let converted = convertToAppKit(quartzRect) else { return nil }

        if let matched = bestStoredMetrics(matching: quartzRect) {
            cachedMascotMetrics = matched
            return LocatedPet(
                overlayRect: converted.0,
                visibleRect: visibleRect(in: converted.0, metrics: matched),
                screen: converted.1,
                source: "window-\(matched.source)"
            )
        }

        // Keep the last verified relative anchor during the few milliseconds
        // between the live window moving and Codex persisting its new bounds.
        if let cachedMascotMetrics,
           metricsAreValid(cachedMascotMetrics, for: quartzRect.size)
        {
            return LocatedPet(
                overlayRect: converted.0,
                visibleRect: visibleRect(in: converted.0, metrics: cachedMascotMetrics),
                screen: converted.1,
                source: "window-cached-anchor"
            )
        }

        // This is only a last resort for state files from unknown Codex builds.
        // Screen capture can be unavailable without Screen Recording permission,
        // so an unverified hard-coded transparent-window inset is never used.
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastVisualProbeAt >= 0.12 {
            lastVisualProbeAt = now
            if let probedInset = probeTopVisualInset(windowID: windowID) {
                let width = min(224, max(80, quartzRect.width * 163 / 356))
                let height = width * 177 / 163
                let metrics = StoredMascotMetrics(
                    left: max(0, (quartzRect.width - width) / 2),
                    top: max(0, probedInset - petSpriteTopPaddingInsideAnchor),
                    width: width,
                    height: height,
                    source: "image-probe"
                )
                cachedMascotMetrics = metrics
                return LocatedPet(
                    overlayRect: converted.0,
                    visibleRect: visibleRect(in: converted.0, metrics: metrics),
                    screen: converted.1,
                    source: "window-image-probe"
                )
            }
        }

        if let visibleRect = geometricFallbackVisibleRect(in: converted.0) {
            return LocatedPet(
                overlayRect: converted.0,
                visibleRect: visibleRect,
                screen: converted.1,
                source: "window-geometry-fallback"
            )
        }

        return nil
    }

    private func refreshStoredOverlayState() {
        let stateURL: URL
        if let override = ProcessInfo.processInfo.environment["CODEX_STATUS_PANEL_STATE_FILE"],
           !override.isEmpty
        {
            stateURL = URL(fileURLWithPath: override)
        } else if let override = ProcessInfo.processInfo.environment["CODEX_PANEL_STATE_FILE"],
           !override.isEmpty
        {
            stateURL = URL(fileURLWithPath: override)
        } else {
            stateURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/.codex-global-state.json")
        }
        guard let data = try? Data(contentsOf: stateURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        overlayOpen = root["electron-avatar-overlay-open"] as? Bool
        guard let overlay = root["electron-avatar-overlay-bounds"] as? [String: Any] else {
            storedOverlayLocations = []
            return
        }

        let activeDisplayID: String?
        if let number = overlay["displayId"] as? NSNumber {
            activeDisplayID = number.stringValue
        } else {
            activeDisplayID = overlay["displayId"] as? String
        }
        if activeDisplayID != storedDisplayID {
            storedDisplayID = activeDisplayID
            cachedWindowID = nil
            cachedMascotMetrics = nil
        }

        var locations: [StoredOverlayLocation] = []

        func addEntry(
            _ entry: [String: Any],
            displayID: String? = nil,
            isPrimary: Bool = false
        ) {
            if !isPrimary, let activeDisplayID, displayID != activeDisplayID {
                return
            }
            guard let x = entry["x"] as? NSNumber,
                  let y = entry["y"] as? NSNumber,
                  let width = entry["width"] as? NSNumber,
                  let height = entry["height"] as? NSNumber,
                  width.doubleValue > 0,
                  height.doubleValue > 0
            else { return }

            let rect = CGRect(
                x: x.doubleValue,
                y: y.doubleValue,
                width: width.doubleValue,
                height: height.doubleValue
            )
            let mascot = mascotMetrics(from: entry, overlayRect: rect)
            locations.append(StoredOverlayLocation(rect: rect, mascot: mascot, isPrimary: isPrimary))
        }

        // The root entry is the most recently active display and is the best fallback.
        addEntry(overlay, isPrimary: true)
        if let byDisplayID = overlay["byDisplayId"] as? [String: Any] {
            for (key, value) in byDisplayID {
                if let entry = value as? [String: Any] {
                    let entryDisplayID: String
                    if let number = entry["displayId"] as? NSNumber {
                        entryDisplayID = number.stringValue
                    } else {
                        entryDisplayID = entry["displayId"] as? String ?? key
                    }
                    addEntry(entry, displayID: entryDisplayID)
                }
            }
        }
        // Older Codex releases sometimes only retain a resolution-keyed copy.
        if let byResolution = overlay["byResolution"] as? [String: Any] {
            for value in byResolution.values {
                if let entry = value as? [String: Any] {
                    let entryDisplayID: String?
                    if let number = entry["displayId"] as? NSNumber {
                        entryDisplayID = number.stringValue
                    } else {
                        entryDisplayID = entry["displayId"] as? String
                    }
                    addEntry(entry, displayID: entryDisplayID)
                }
            }
        }

        storedOverlayLocations = locations
    }

    private func mascotMetrics(
        from entry: [String: Any],
        overlayRect: CGRect
    ) -> StoredMascotMetrics? {
        if let mascot = entry["mascot"] as? [String: Any],
           let left = mascot["left"] as? NSNumber,
           let top = mascot["top"] as? NSNumber,
           let width = mascot["width"] as? NSNumber
        {
            let derivedHeight = width.doubleValue * 177 / 163
            let height = (mascot["height"] as? NSNumber)?.doubleValue ?? derivedHeight
            let metrics = StoredMascotMetrics(
                left: CGFloat(left.doubleValue),
                top: CGFloat(top.doubleValue),
                width: CGFloat(width.doubleValue),
                height: CGFloat(height),
                source: "state-mascot"
            )
            if metricsAreValid(metrics, for: overlayRect.size) { return metrics }
        }

        // Compatibility with Codex builds that persisted only an absolute
        // anchor rectangle instead of relative `mascot` metrics.
        if let anchor = entry["anchor"] as? [String: Any],
           let x = anchor["x"] as? NSNumber,
           let y = anchor["y"] as? NSNumber,
           let width = anchor["width"] as? NSNumber,
           let height = anchor["height"] as? NSNumber
        {
            let metrics = StoredMascotMetrics(
                left: CGFloat(x.doubleValue - overlayRect.minX),
                top: CGFloat(y.doubleValue - overlayRect.minY),
                width: CGFloat(width.doubleValue),
                height: CGFloat(height.doubleValue),
                source: "state-anchor"
            )
            if metricsAreValid(metrics, for: overlayRect.size) { return metrics }
        }
        return nil
    }

    private func metricsAreValid(_ metrics: StoredMascotMetrics, for size: CGSize) -> Bool {
        metrics.width >= 40
            && metrics.height >= 40
            && metrics.left >= -2
            && metrics.top >= -2
            && metrics.left + metrics.width <= size.width + 2
            && metrics.top + metrics.height <= size.height + 2
    }

    private func bestStoredMetrics(matching liveRect: CGRect) -> StoredMascotMetrics? {
        let matches = storedOverlayLocations.compactMap { stored -> (StoredMascotMetrics, Double)? in
            guard let metrics = stored.mascot else { return nil }
            let widthDelta = abs(stored.rect.width - liveRect.width)
            let heightDelta = abs(stored.rect.height - liveRect.height)
            guard widthDelta <= max(24, liveRect.width * 0.15),
                  heightDelta <= max(24, liveRect.height * 0.15)
            else { return nil }

            // Electron display IDs are not guaranteed to equal CGDirectDisplayID.
            // Match the live Quartz rectangle to the nearest persisted rectangle
            // instead; this remains stable across Retina scale and monitor order.
            let centerDistance = hypot(stored.rect.midX - liveRect.midX, stored.rect.midY - liveRect.midY)
            let primaryBonus = stored.isPrimary ? -1.0 : 0.0
            let score = Double(widthDelta * 5 + heightDelta * 5 + centerDistance * 0.08) + primaryBonus
            return (metrics, score)
        }
        return matches.min(by: { $0.1 < $1.1 })?.0
    }

    private func visibleRect(in overlayRect: NSRect, metrics: StoredMascotMetrics) -> NSRect {
        let visibleHeight = max(1, metrics.height - petSpriteTopPaddingInsideAnchor)
        return NSRect(
            x: overlayRect.minX + metrics.left,
            y: overlayRect.maxY - metrics.top - metrics.height,
            width: metrics.width,
            height: visibleHeight
        )
    }

    private func storedOverlayLocation() -> LocatedPet? {
        guard overlayOpen != false else { return nil }

        for stored in storedOverlayLocations.sorted(by: { $0.isPrimary && !$1.isPrimary }) {
            guard let mascot = stored.mascot else { continue }
            guard let converted = convertToAppKit(stored.rect) else { continue }
            cachedMascotMetrics = mascot
            return LocatedPet(
                overlayRect: converted.0,
                visibleRect: visibleRect(in: converted.0, metrics: mascot),
                screen: converted.1,
                source: "saved-\(mascot.source)"
            )
        }
        return nil
    }

    private func probeTopVisualInset(windowID: CGWindowID) -> CGFloat? {
        guard let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming]
        ), image.width >= 250, image.height >= 170,
        let data = image.dataProvider?.data,
        let bytes = CFDataGetBytePtr(data)
        else { return nil }

        let bytesPerPixel = max(1, image.bitsPerPixel / 8)
        let bytesPerRow = image.bytesPerRow
        let minX = max(0, Int(Double(image.width) * 0.50))
        let maxX = min(image.width, Int(Double(image.width) * 0.85))
        let maxY = image.height
        let roiWidth = maxX - minX
        guard bytesPerPixel >= 4, roiWidth > 0 else { return nil }

        for y in 0..<maxY {
            var visiblePixels = 0
            for x in minX..<maxX {
                let offset = y * bytesPerRow + x * bytesPerPixel
                var isVisible = false
                for channel in 0..<min(bytesPerPixel, 4) where bytes[offset + channel] > 20 {
                    isVisible = true
                    break
                }
                if isVisible { visiblePixels += 1 }
            }

            // The pet's narrow top decoration begins with only a few pixels.
            // Reject nearly solid rows, which indicates a privacy-blocked image.
            if visiblePixels >= 4 && visiblePixels < Int(Double(roiWidth) * 0.80) {
                return CGFloat(y)
            }
        }
        return nil
    }

    private func candidate(from window: [String: Any]) -> (rect: CGRect, score: Double)? {
        guard let ownerName = window[kCGWindowOwnerName as String] as? String,
              let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue,
              layer >= 0,
              layer < 50,
              let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
              alpha > 0.05,
              let rawBounds = window[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: rawBounds),
              bounds.width >= 160,
              bounds.width <= 900,
              bounds.height >= 120,
              bounds.height <= 1_000
        else { return nil }

        let normalizedOwner = ownerName.lowercased()
        guard normalizedOwner.contains("codex") || normalizedOwner.contains("chatgpt") else {
            return nil
        }

        let name = window[kCGWindowName as String] as? String ?? ""
        var score = Double(abs(bounds.width - 356) + abs(bounds.height - 320) * 0.35)
        score += Double(abs(layer - 3) * 50)
        if name == "ChatGPT" || name == "Codex" { score -= 80 }

        if let distance = storedOverlayLocations.map({ stored in
            hypot(bounds.midX - stored.rect.midX, bounds.midY - stored.rect.midY)
        }).min() {
            score += Double(distance * 0.08)
        }
        return (bounds, score)
    }

    private func convertToAppKit(_ quartzRect: CGRect) -> (NSRect, NSScreen)? {
        let center = CGPoint(x: quartzRect.midX, y: quartzRect.midY)

        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            let displayBounds = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
            guard displayBounds.contains(center) || displayBounds.intersects(quartzRect) else {
                continue
            }

            let x = screen.frame.minX + (quartzRect.minX - displayBounds.minX)
            let y = screen.frame.maxY - (quartzRect.minY - displayBounds.minY) - quartzRect.height
            return (NSRect(x: x, y: y, width: quartzRect.width, height: quartzRect.height), screen)
        }
        return nil
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let quotaClient = CodexQuotaClient()
    private let btcPriceClient = MarketPriceClient(symbol: "BTCUSDT")
    private let ethPriceClient = MarketPriceClient(symbol: "ETHUSDT")
    private let locator = PetWindowLocator()
    private let healthWriter = RuntimeHealthWriter()
    private let quotaView = QuotaPanelView(frame: NSRect(origin: .zero, size: expandedPanelSize))
    private var panel: NSPanel!
    private var statusItem: NSStatusItem?
    private let statusMenu = NSMenu()
    private let codexStatusMenuItem = NSMenuItem()
    private let followStatusMenuItem = NSMenuItem()
    private let showPanelMenuItem = NSMenuItem(title: "显示面板", action: #selector(showPanelFromMenu(_:)), keyEquivalent: "")
    private let hidePanelMenuItem = NSMenuItem(title: "隐藏面板", action: #selector(hidePanelFromMenu(_:)), keyEquivalent: "")
    private let collapsePanelMenuItem = NSMenuItem(title: "折叠面板", action: #selector(toggleCollapsedFromMenu(_:)), keyEquivalent: "")
    private let refreshQuotaMenuItem = NSMenuItem(title: "立即刷新额度", action: #selector(refreshQuotaFromMenu(_:)), keyEquivalent: "r")
    private let resetFollowMenuItem = NSMenuItem(title: "重置跟随位置", action: #selector(resetFollowPositionFromMenu(_:)), keyEquivalent: "")
    private let openConfigMenuItem = NSMenuItem(title: "打开配置文件", action: #selector(openConfigFileFromMenu(_:)), keyEquivalent: ",")
    private var refreshTimer: Timer?
    private var btcRefreshTimer: Timer?
    private var followTimer: Timer?
    private var isRefreshing = false
    private var isRefreshingBTCPrice = false
    private var isRefreshingETHPrice = false
    private var lastBTCPrice: Double?
    private var lastETHPrice: Double?
    private var codexConnectionStatus = "disconnected"
    private var followHealthStatus = "waiting-for-pet"
    private var lastLocationSource: String?
    private var lastQuotaUpdatedAt: Date?
    private var isPanelHiddenByUser = false
    private var isManualStandaloneEnabled = false
    private var lastStatusMenuSignature = ""
    private var lastStatusBarDisplayState: MenuBarDisplayState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        reportPanelConfigWarnings()
        makeStatusItem()
        makePanel()
        writeHealth(status: "started", panelVisible: false, locationSource: nil, force: true)
        followPet()
        refreshQuota()
        if marketPricesEnabled {
            refreshBTCPrice()
            refreshETHPrice()
        }

        followTimer = Timer.scheduledTimer(withTimeInterval: followInterval, repeats: true) { [weak self] _ in
            self?.followPet()
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refreshQuota()
        }
        if marketPricesEnabled {
            btcRefreshTimer = Timer.scheduledTimer(withTimeInterval: btcRefreshInterval, repeats: true) { [weak self] _ in
                self?.refreshBTCPrice()
                self?.refreshETHPrice()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        btcRefreshTimer?.invalidate()
        followTimer?.invalidate()
        writeHealth(status: "terminated", panelVisible: false, locationSource: nil, force: true)
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateStatusMenu(force: true)
    }

    private func makeStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusMenu.delegate = self

        codexStatusMenuItem.isEnabled = false
        followStatusMenuItem.isEnabled = false
        statusMenu.addItem(codexStatusMenuItem)
        statusMenu.addItem(followStatusMenuItem)
        statusMenu.addItem(.separator())

        for item in [
            showPanelMenuItem,
            hidePanelMenuItem,
            collapsePanelMenuItem,
            refreshQuotaMenuItem,
            resetFollowMenuItem,
            openConfigMenuItem,
        ] {
            item.target = self
            statusMenu.addItem(item)
        }

        statusMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出", action: #selector(quitFromMenu(_:)), keyEquivalent: "q")
        quitItem.target = self
        statusMenu.addItem(quitItem)

        if let button = statusItem?.button {
            button.imagePosition = .imageOnly
        }
        statusItem?.menu = statusMenu
        updateStatusMenu(force: true)
    }

    private func updateStatusMenu(force: Bool = false) {
        let quotaUpdatedText: String
        if isRefreshing {
            quotaUpdatedText = "读取中"
        } else if let lastQuotaUpdatedAt {
            quotaUpdatedText = Self.timeFormatter.string(from: lastQuotaUpdatedAt)
        } else {
            quotaUpdatedText = quotaView.statusText
        }

        let codexTitle = "Codex：\(quotaView.codexConnectionText) · 额度：\(quotaUpdatedText)"
        let followTitle: String
        if isPanelHiddenByUser {
            followTitle = "面板：已隐藏"
        } else if let lastLocationSource {
            followTitle = "跟随：\(quotaView.followStatusText) · \(lastLocationSource)"
        } else {
            followTitle = "跟随：\(quotaView.followStatusText)"
        }
        let controlState = panelMenuControlState(
            isPanelVisible: panel?.isVisible ?? false,
            isPanelHiddenByUser: isPanelHiddenByUser,
            isCollapsed: quotaView.isCollapsed,
            isRefreshing: isRefreshing
        )
        let signature = [
            codexTitle,
            followTitle,
            String(controlState.showPanelEnabled),
            String(controlState.hidePanelEnabled),
            controlState.collapseTitle,
            String(controlState.refreshQuotaEnabled),
        ].joined(separator: "|")

        if force || signature != lastStatusMenuSignature {
            codexStatusMenuItem.title = codexTitle
            followStatusMenuItem.title = followTitle
            showPanelMenuItem.isEnabled = controlState.showPanelEnabled
            hidePanelMenuItem.isEnabled = controlState.hidePanelEnabled
            collapsePanelMenuItem.title = controlState.collapseTitle
            refreshQuotaMenuItem.isEnabled = controlState.refreshQuotaEnabled
            lastStatusMenuSignature = signature
        }
        updateStatusBarIcon()
    }

    private func updateStatusBarIcon() {
        guard let button = statusItem?.button else { return }
        let iconFollowStatus = isPanelHiddenByUser ? "following-pet" : followHealthStatus
        let state = menuBarDisplayState(
            isRefreshing: isRefreshing,
            codexConnectionStatus: codexConnectionStatus,
            followHealthStatus: iconFollowStatus
        )
        guard state != lastStatusBarDisplayState else { return }
        let tooltip = statusBarTooltip(for: state)

        if let image = NSImage(systemSymbolName: statusBarSymbolName(for: state), accessibilityDescription: tooltip) {
            image.isTemplate = true
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = "Codex"
        }
        button.toolTip = tooltip
        lastStatusBarDisplayState = state
    }

    private func makePanel() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: expandedPanelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = quotaView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        quotaView.onToggleCollapsed = { [weak self] in
            self?.toggleCollapsed()
        }
    }

    private func toggleCollapsed() {
        setCollapsed(!quotaView.isCollapsed)
    }

    private func setCollapsed(_ isCollapsed: Bool) {
        guard quotaView.isCollapsed != isCollapsed else {
            updateStatusMenu()
            return
        }
        quotaView.isCollapsed = isCollapsed
        panel.setContentSize(quotaView.isCollapsed ? collapsedPanelSize : expandedPanelSize)
        if !isPanelHiddenByUser {
            followPet(forceStandaloneFallback: isManualStandaloneEnabled)
        }
        updateStatusMenu()
    }

    @objc private func showPanelFromMenu(_ sender: Any?) {
        isPanelHiddenByUser = false
        isManualStandaloneEnabled = true
        followPet(forceStandaloneFallback: true)
        updateStatusMenu()
    }

    @objc private func hidePanelFromMenu(_ sender: Any?) {
        isManualStandaloneEnabled = false
        isPanelHiddenByUser = true
        if panel.isVisible {
            panel.orderOut(nil)
        }
        quotaView.followStatusText = "已隐藏"
        followHealthStatus = "hidden-by-user"
        lastLocationSource = nil
        writeHealth(status: "hidden-by-user", panelVisible: false, locationSource: nil, force: true)
        updateStatusMenu()
    }

    @objc private func toggleCollapsedFromMenu(_ sender: Any?) {
        setCollapsed(!quotaView.isCollapsed)
    }

    @objc private func refreshQuotaFromMenu(_ sender: Any?) {
        refreshQuota()
        updateStatusMenu()
    }

    @objc private func resetFollowPositionFromMenu(_ sender: Any?) {
        locator.reset()
        isPanelHiddenByUser = false
        isManualStandaloneEnabled = false
        followPet()
        updateStatusMenu()
    }

    @objc private func openConfigFileFromMenu(_ sender: Any?) {
        if let editableConfigURL = ensureEditablePanelConfigFile() {
            NSWorkspace.shared.open(editableConfigURL)
        } else {
            NSWorkspace.shared.open(editablePanelConfigFileURL.deletingLastPathComponent())
        }
    }

    @objc private func quitFromMenu(_ sender: Any?) {
        NSApp.terminate(sender)
    }

    private func followPet(forceStandaloneFallback: Bool = false) {
        guard !isPanelHiddenByUser else {
            if panel.isVisible {
                panel.orderOut(nil)
            }
            quotaView.followStatusText = "已隐藏"
            followHealthStatus = "hidden-by-user"
            lastLocationSource = nil
            writeHealth(status: "hidden-by-user", panelVisible: false, locationSource: nil)
            updateStatusMenu()
            return
        }

        guard let pet = locator.locate() else {
            lastLocationSource = nil
            if forceStandaloneFallback || isManualStandaloneEnabled || shouldShowStandalonePanel() {
                showStandalonePanel()
                quotaView.followStatusText = "固定显示"
                followHealthStatus = "screen-fallback"
                lastLocationSource = "screen-fallback"
                writeHealth(
                    status: "fallback-visible",
                    panelVisible: true,
                    locationSource: "screen-fallback"
                )
            } else {
                panel.orderOut(nil)
                quotaView.followStatusText = "等待桌宠"
                followHealthStatus = "waiting-for-pet"
                writeHealth(status: "waiting-for-codex", panelVisible: false, locationSource: nil)
            }
            updateStatusMenu()
            return
        }

        quotaView.followStatusText = "跟随中"
        followHealthStatus = "following-pet"
        lastLocationSource = pet.source
        let currentPanelSize = quotaView.isCollapsed ? collapsedPanelSize : expandedPanelSize
        let placement = panelPlacement(
            petVisibleRect: pet.visibleRect,
            panelSize: currentPanelSize,
            screenVisibleFrame: pet.screen.visibleFrame
        )

        quotaView.pointerSide = .bottom
        quotaView.pointerCenterX = placement.pointerCenterX
        let targetOrigin = placement.origin
        if panel.frame.origin != targetOrigin {
            panel.setFrameOrigin(targetOrigin)
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        writeHealth(
            status: "following-pet",
            panelVisible: true,
            locationSource: pet.source,
            gap: placement.actualGap,
            centerError: placement.centerError
        )
        updateStatusMenu()
    }

    private func shouldShowStandalonePanel() -> Bool {
        if let overlayOpen = locator.overlayOpen { return overlayOpen }

        return NSWorkspace.shared.runningApplications.contains { application in
            let name = application.localizedName?.lowercased() ?? ""
            let bundleID = application.bundleIdentifier?.lowercased() ?? ""
            return name == "codex"
                || name == "chatgpt"
                || bundleID.contains("openai.codex")
                || bundleID.contains("openai.chat")
        }
    }

    private func showStandalonePanel() {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }

        let visible = screen.visibleFrame
        let currentPanelSize = quotaView.isCollapsed ? collapsedPanelSize : expandedPanelSize
        let origin = NSPoint(
            x: (visible.maxX - currentPanelSize.width - 24).rounded(),
            y: (visible.maxY - currentPanelSize.height - 24).rounded()
        )
        quotaView.pointerSide = .bottom
        quotaView.pointerCenterX = currentPanelSize.width / 2
        if panel.frame.origin != origin {
            panel.setFrameOrigin(origin)
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func refreshQuota() {
        guard !isRefreshing else { return }
        isRefreshing = true
        if quotaView.rows.isEmpty {
            quotaView.errorText = nil
            quotaView.statusText = "正在读取额度…"
        } else {
            quotaView.statusText = "正在更新…"
        }
        updateStatusMenu()

        quotaClient.fetch { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRefreshing = false
                switch result {
                case .success(let response):
                    self.quotaView.rows = Self.makeRows(from: response)
                    self.quotaView.errorText = nil
                    self.codexConnectionStatus = "connected"
                    self.quotaView.codexConnectionText = "已连接"
                    let now = Date()
                    self.lastQuotaUpdatedAt = now
                    self.quotaView.statusText = Self.timeFormatter.string(from: now)
                case .failure(let error):
                    self.codexConnectionStatus = "disconnected"
                    self.quotaView.codexConnectionText = "未连接"
                    self.quotaView.errorText = error.localizedDescription
                    self.quotaView.statusText = "重试中"
                }
                self.updateStatusMenu()
            }
        }
    }

    private func writeHealth(
        status: String,
        panelVisible: Bool,
        locationSource: String?,
        gap: CGFloat? = nil,
        centerError: CGFloat? = nil,
        force: Bool = false
    ) {
        healthWriter.write(
            status: status,
            panelVisible: panelVisible,
            locationSource: locationSource,
            codexConnectionStatus: codexConnectionStatus,
            followStatus: followHealthStatus,
            gap: gap,
            centerError: centerError,
            force: force
        )
    }

    private func refreshBTCPrice() {
        guard !isRefreshingBTCPrice else { return }
        isRefreshingBTCPrice = true

        btcPriceClient.fetch { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRefreshingBTCPrice = false
                switch result {
                case .success(let price):
                    if let previousPrice = self.lastBTCPrice {
                        self.quotaView.btcPriceDirection = price > previousPrice ? 1 : (price < previousPrice ? -1 : 0)
                    } else {
                        self.quotaView.btcPriceDirection = 0
                    }
                    self.lastBTCPrice = price
                    self.quotaView.btcPrice = price
                    self.quotaView.btcStatusText = "5秒"
                case .failure:
                    self.quotaView.btcStatusText = self.quotaView.btcPrice == nil ? "重试中" : "暂离线"
                }
            }
        }
    }

    private func refreshETHPrice() {
        guard !isRefreshingETHPrice else { return }
        isRefreshingETHPrice = true

        ethPriceClient.fetch { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRefreshingETHPrice = false
                switch result {
                case .success(let price):
                    if let previousPrice = self.lastETHPrice {
                        self.quotaView.ethPriceDirection = price > previousPrice ? 1 : (price < previousPrice ? -1 : 0)
                    } else {
                        self.quotaView.ethPriceDirection = 0
                    }
                    self.lastETHPrice = price
                    self.quotaView.ethPrice = price
                    self.quotaView.ethStatusText = "5秒"
                case .failure:
                    self.quotaView.ethStatusText = self.quotaView.ethPrice == nil ? "重试中" : "暂离线"
                }
            }
        }
    }

    private static func makeRows(from response: RateLimitsResult) -> [QuotaRow] {
        let snapshot = codexSnapshot(from: response)

        if let window = snapshot.primary {
            return [QuotaRow(
                name: "Codex",
                remainingPercent: max(0, 100 - window.usedPercent),
                resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            )]
        }

        if let individual = snapshot.individualLimit {
            return [QuotaRow(
                name: "Codex",
                remainingPercent: individual.remainingPercent,
                resetsAt: Date(timeIntervalSince1970: TimeInterval(individual.resetsAt))
            )]
        }

        return [QuotaRow(name: "Codex", remainingPercent: 0, resetsAt: nil)]
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

}

private func printQuotaOnce() -> Never {
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

private func printMarketPriceOnce(symbol: String, label: String) -> Never {
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

private func printPanelConfiguration() -> Never {
    print(
        "panel-config: version=\(panelVersion) "
            + "bundle=\(panelBundleIdentifier) "
            + "theme=\(panelConfig.theme.id) "
            + "marketPricesEnabled=\(marketPricesEnabled) "
            + "codexConnection=\(panelConfig.widgets.codexConnection) "
            + "followStatus=\(panelConfig.widgets.followStatus) "
            + "width=\(Int(expandedPanelSize.width)) "
            + "height=\(Int(expandedPanelSize.height)) "
            + "gap=\(String(format: "%.1f", panelPetGap))"
    )
    exit(0)
}

private func runMenuControlsSelfTest() -> Never {
    let visibleExpandedState = panelMenuControlState(
        isPanelVisible: true,
        isPanelHiddenByUser: false,
        isCollapsed: false,
        isRefreshing: false
    )
    let hiddenState = panelMenuControlState(
        isPanelVisible: false,
        isPanelHiddenByUser: true,
        isCollapsed: false,
        isRefreshing: false
    )
    let refreshingState = panelMenuControlState(
        isPanelVisible: true,
        isPanelHiddenByUser: false,
        isCollapsed: true,
        isRefreshing: true
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
            refreshQuotaEnabled: true
        ),
        hiddenState == PanelMenuControlState(
            showPanelEnabled: true,
            hidePanelEnabled: false,
            collapseTitle: "折叠面板",
            refreshQuotaEnabled: true
        ),
        refreshingState == PanelMenuControlState(
            showPanelEnabled: false,
            hidePanelEnabled: true,
            collapseTitle: "展开面板",
            refreshQuotaEnabled: false
        ),
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

private func printPanelPlacementOnce(savedStateOnly: Bool = false) -> Never {
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

private func runPlacementSelfTest() -> Never {
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

private func renderPreviewOnce(to outputPath: String) -> Never {
    let view = QuotaPanelView(frame: NSRect(origin: .zero, size: expandedPanelSize))
    view.pointerSide = .bottom
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
        pixelsWide: Int(expandedPanelSize.width * scale),
        pixelsHigh: Int(expandedPanelSize.height * scale),
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
    bitmap.size = expandedPanelSize

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

let cliFlags: Set<String> = [
    "--print-quota",
    "--print-btc",
    "--print-eth",
    "--print-panel-location",
    "--print-saved-panel-location",
    "--self-test-placement",
    "--self-test-menu-controls",
    "--print-panel-config",
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

if CommandLine.arguments.contains("--print-panel-config") {
    printPanelConfiguration()
}

if let previewFlag = CommandLine.arguments.firstIndex(of: "--render-preview") {
    guard CommandLine.arguments.indices.contains(previewFlag + 1) else {
        fputs("用法：CodexStatusPanel --render-preview <output.png>\n", stderr)
        exit(1)
    }
    renderPreviewOnce(to: CommandLine.arguments[previewFlag + 1])
}

let application = NSApplication.shared
private let delegate = AppDelegate()
application.delegate = delegate
application.run()
