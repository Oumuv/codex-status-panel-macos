import AppKit
import CoreGraphics
import Darwin
import Foundation

private let panelVersion = "1.2.1"
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
private let taskProgressRefreshInterval: TimeInterval = 2
private let configuredMarketPricesEnabled: Bool = {
    if let rawValue = ProcessInfo.processInfo.environment[
        "CODEX_STATUS_PANEL_SHOW_MARKET_PRICES"
    ] {
        return !isFalseEnvironmentValue(rawValue)
    }
    return panelConfig.widgets.marketPrices
}()
private let marketPricesPreferenceKey = "showsMarketPrices"
private func resolvedMarketPricesEnabled(
    storedValue: Bool?,
    configuredDefault: Bool
) -> Bool {
    storedValue ?? configuredDefault
}
private let initialMarketPricesEnabled = resolvedMarketPricesEnabled(
    storedValue: UserDefaults.standard.object(
        forKey: marketPricesPreferenceKey
    ) as? Bool,
    configuredDefault: configuredMarketPricesEnabled
)
// Track fast enough that the panel preserves its visual gap while the pet
// window is moving between animation positions.
private let followInterval: TimeInterval = max(0.01, panelConfig.refresh.followSeconds)
private let panelHorizontalCanvasInset: CGFloat = 7
private let panelVerticalCanvasInset: CGFloat = 4
private let panelPointerLength: CGFloat = 10
private let taskProgressRowHeight: CGFloat = 23
private let marketPriceRowHeight: CGFloat = 23
private let maximumVisibleTaskRows = 5
private let baseExpandedPanelHeight: CGFloat = 120
private func panelSizeForTaskRows(
    _ count: Int,
    showsMarketPrices: Bool
) -> NSSize {
    let safeCount = max(1, min(maximumVisibleTaskRows, count))
    let marketHeight = showsMarketPrices ? marketPriceRowHeight * 2 : 0
    return NSSize(
        width: 232,
        height: baseExpandedPanelHeight
            + taskProgressRowHeight * CGFloat(safeCount)
            + marketHeight
    )
}
private let expandedPanelSize = panelSizeForTaskRows(
    1,
    showsMarketPrices: initialMarketPricesEnabled
)
private let collapsedPanelSize = NSSize(width: 72, height: 48)
private let panelPetGap: CGFloat = panelConfig.tracking.gapPoints
private let panelScreenMargin: CGFloat = 8
private let pointerTipBottomInset = panelVerticalCanvasInset
private let pointerHorizontalSafeInset = panelHorizontalCanvasInset + 12
// The v2 sprite has a small transparent top padding inside Codex's stored
// mascot anchor. Add it so the panel measures from Codex desktop visible top tuft.
private let petSpriteTopPaddingInsideAnchor: CGFloat = panelConfig.tracking.mascotTopPaddingPoints

private func reportPanelConfigWarnings() {
    for warning in panelConfigWarnings {
        fputs("\(warning)\n", stderr)
    }
}

private enum SingleInstanceLockError: LocalizedError {
    case alreadyRunning
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "已有 Codex 状态面板实例正在运行"
        case .unavailable(let detail):
            return "无法创建单实例锁：\(detail)"
        }
    }
}

private final class SingleInstanceLock {
    private let fileDescriptor: Int32

    private init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    static func acquire() throws -> SingleInstanceLock {
        let lockDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/\(defaultBundleIdentifier)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
        } catch {
            throw SingleInstanceLockError.unavailable(error.localizedDescription)
        }

        let lockURL = lockDirectory.appendingPathComponent("instance.lock")
        let fileDescriptor = lockURL.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard fileDescriptor >= 0 else {
            throw SingleInstanceLockError.unavailable(String(cString: strerror(errno)))
        }

        guard flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            _ = Darwin.close(fileDescriptor)
            if lockError == EWOULDBLOCK {
                throw SingleInstanceLockError.alreadyRunning
            }
            throw SingleInstanceLockError.unavailable(String(cString: strerror(lockError)))
        }

        return SingleInstanceLock(fileDescriptor: fileDescriptor)
    }

    deinit {
        _ = flock(fileDescriptor, LOCK_UN)
        _ = Darwin.close(fileDescriptor)
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
    let marketPricesEnabled: Bool
}

private func panelMenuControlState(
    isPanelVisible: Bool,
    isPanelHiddenByUser: Bool,
    isCollapsed: Bool,
    isRefreshing: Bool,
    showsMarketPrices: Bool
) -> PanelMenuControlState {
    PanelMenuControlState(
        showPanelEnabled: isPanelHiddenByUser || !isPanelVisible,
        hidePanelEnabled: isPanelVisible && !isPanelHiddenByUser,
        collapseTitle: collapsedMenuItemTitle(isCollapsed: isCollapsed),
        refreshQuotaEnabled: !isRefreshing,
        marketPricesEnabled: showsMarketPrices
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
        marketPricesEnabled: Bool,
        panelHeight: CGFloat,
        gap: CGFloat? = nil,
        centerError: CGFloat? = nil,
        force: Bool = false
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        let signature = [
            status,
            String(panelVisible),
            locationSource ?? "none",
            codexConnectionStatus,
            followStatus,
            String(marketPricesEnabled),
            String(format: "%.1f", panelHeight),
        ].joined(separator: "|")
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
            "panelHeightPoints": panelHeight,
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

private enum TaskProgressKind: String, Equatable {
    case reading
    case running
    case waitingForInput
    case completed
    case failed
    case idle
}

private struct TaskProgressItem: Equatable {
    let title: String
    let kind: TaskProgressKind
    let startedAt: Date
    let statusOverride: String?

    init(
        title: String,
        kind: TaskProgressKind,
        startedAt: Date = .distantPast,
        statusOverride: String? = nil
    ) {
        self.title = title
        self.kind = kind
        self.startedAt = startedAt
        self.statusOverride = statusOverride
    }

    var statusText: String {
        if let statusOverride { return statusOverride }
        switch kind {
        case .reading:
            return "读取中"
        case .running:
            return "正在执行"
        case .waitingForInput:
            return "等你确认"
        case .completed:
            return "已完成"
        case .failed:
            return "执行失败"
        case .idle:
            return "等待"
        }
    }
}

private struct TaskProgressSnapshot: Equatable {
    let items: [TaskProgressItem]

    var kind: TaskProgressKind { items.first?.kind ?? .idle }
    var rowCount: Int { max(1, items.count) }

    static let reading = TaskProgressSnapshot(items: [TaskProgressItem(
        title: "正在读取任务",
        kind: .reading
    )])

    static let idle = TaskProgressSnapshot(items: [TaskProgressItem(
        title: "暂无进行中的任务",
        kind: .idle
    )])

    static func displaying(_ sourceItems: [TaskProgressItem]) -> TaskProgressSnapshot {
        guard !sourceItems.isEmpty else { return .idle }
        return TaskProgressSnapshot(items: Array(
            sourceItems.prefix(maximumVisibleTaskRows)
        ))
    }
}

private func shouldAnimateRunningArrow(
    isWindowVisible: Bool,
    isCollapsed: Bool,
    hasRunningTask: Bool
) -> Bool {
    isWindowVisible && !isCollapsed && hasRunningTask
}

private final class CodexTaskProgressReader {
    struct UnreadThreadState {
        let ids: Set<String>
        let isAvailable: Bool
    }

    private struct RolloutCandidate {
        let url: URL
        let modificationDate: Date
    }

    private struct ParsedCacheEntry {
        let modificationDate: Date
        let snapshot: TaskProgressSnapshot
    }

    private let fileManager = FileManager.default
    private let maximumTailBytes: UInt64 = 128 * 1_024
    private let maximumMetadataBytes = 16 * 1_024
    private let maximumMetadataCandidates = 128
    private let maximumRolloutCandidates = 64
    private let discoveryDayCount = 3
    private let initialActiveDiscoveryWindow: TimeInterval = 6 * 60 * 60
    private let rolloutRescanInterval = taskProgressRefreshInterval
    private let completedTaskVisibility: TimeInterval = 2 * 60
    private var cachedRollouts: [RolloutCandidate] = []
    private var cachedRolloutVisibility: [String: Bool] = [:]
    private var parsedCache: [String: ParsedCacheEntry] = [:]
    private var cachedThreadTitles: [String: String] = [:]
    private var cachedThreadIndexModificationDate: Date?
    private var cachedUnreadThreadIDs = Set<String>()
    private var cachedUnreadStateModificationDate: Date?
    private var hasCachedUnreadState = false
    private var trackedActiveRolloutPaths = Set<String>()
    private var nextRolloutScanAt = Date.distantPast

    func read(at now: Date = Date()) -> TaskProgressSnapshot {
        let threadTitles = readThreadTitleIndex()
        let unreadState = readUnreadThreadState()
        var items: [TaskProgressItem] = []

        for candidate in recentRollouts(at: now, unreadThreadIDs: unreadState.ids) {
            let cacheKey = candidate.url.path
            let snapshot: TaskProgressSnapshot
            if let cached = parsedCache[cacheKey],
               cached.modificationDate == candidate.modificationDate
            {
                snapshot = cached.snapshot
            } else {
                guard let lines = readTailLines(from: candidate.url) else { continue }
                snapshot = Self.parse(
                    lines: lines,
                    modificationDate: candidate.modificationDate,
                    now: now
                )
                parsedCache[cacheKey] = ParsedCacheEntry(
                    modificationDate: candidate.modificationDate,
                    snapshot: snapshot
                )
            }

            switch snapshot.kind {
            case .running, .waitingForInput:
                trackedActiveRolloutPaths.insert(cacheKey)
            case .completed, .failed, .idle:
                trackedActiveRolloutPaths.remove(cacheKey)
            case .reading:
                break
            }

            guard var item = snapshot.items.first, item.kind != .idle else { continue }
            let resolvedTitle = Self.resolvedTitle(
                for: candidate.url,
                indexedTitles: threadTitles,
                fallback: item.title
            )
            if resolvedTitle != item.title {
                item = TaskProgressItem(
                    title: resolvedTitle,
                    kind: item.kind,
                    startedAt: item.startedAt,
                    statusOverride: item.statusOverride
                )
            }

            let threadID = Self.threadID(from: candidate.url)
            guard Self.shouldDisplay(
                kind: item.kind,
                threadID: threadID,
                modificationDate: candidate.modificationDate,
                now: now,
                unreadState: unreadState,
                fallbackVisibility: completedTaskVisibility
            ) else { continue }
            items.append(item)
        }

        items.sort {
            let leftTerminal = $0.kind == .completed || $0.kind == .failed
            let rightTerminal = $1.kind == .completed || $1.kind == .failed
            if leftTerminal != rightTerminal { return !leftTerminal }
            if $0.startedAt == $1.startedAt { return $0.title < $1.title }
            if leftTerminal { return $0.startedAt > $1.startedAt }
            return $0.startedAt < $1.startedAt
        }
        return .displaying(items)
    }

    static func parse(
        lines: [String],
        modificationDate: Date,
        now: Date
    ) -> TaskProgressSnapshot {
        var lifecycle: TaskProgressKind?
        var pendingUserInputCalls = Set<String>()
        var latestUserTitle: String?
        var activeTaskTitle: String?
        var taskStartedAt = modificationDate

        for line in lines {
            guard line.contains("task_started")
                || line.contains("task_complete")
                || line.contains("task_failed")
                || line.contains("turn_aborted")
                || line.contains(#""type":"error""#)
                || line.contains("user_message")
                || line.contains("request_user_input")
                || line.contains("function_call_output")
                || line.contains("custom_tool_call_output")
            else { continue }

            guard let data = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = record["payload"] as? [String: Any],
                  let payloadType = payload["type"] as? String
            else { continue }

            if record["type"] as? String == "event_msg" {
                if payloadType == "user_message",
                   let message = payload["message"] as? String,
                   let title = taskTitle(from: message)
                {
                    latestUserTitle = title
                } else if payloadType == "task_started" {
                    lifecycle = .running
                    pendingUserInputCalls.removeAll()
                    activeTaskTitle = latestUserTitle ?? activeTaskTitle
                    taskStartedAt = timestamp(from: record) ?? modificationDate
                } else if payloadType == "task_complete" {
                    lifecycle = .completed
                    pendingUserInputCalls.removeAll()
                } else if ["task_failed", "turn_aborted", "error"].contains(payloadType) {
                    lifecycle = .failed
                    pendingUserInputCalls.removeAll()
                }
                continue
            }

            if ["function_call", "custom_tool_call"].contains(payloadType),
               payload["name"] as? String == "request_user_input",
               let callID = payload["call_id"] as? String
            {
                pendingUserInputCalls.insert(callID)
                continue
            }

            if ["function_call_output", "custom_tool_call_output"].contains(payloadType),
               let callID = payload["call_id"] as? String
            {
                pendingUserInputCalls.remove(callID)
            }
        }

        let title = activeTaskTitle ?? latestUserTitle ?? "Codex 任务"
        if lifecycle == .running, !pendingUserInputCalls.isEmpty {
            return TaskProgressSnapshot(items: [TaskProgressItem(
                title: title,
                kind: .waitingForInput,
                startedAt: taskStartedAt
            )])
        }
        if let lifecycle {
            return TaskProgressSnapshot(items: [TaskProgressItem(
                title: title,
                kind: lifecycle,
                startedAt: taskStartedAt
            )])
        }
        if !pendingUserInputCalls.isEmpty {
            return TaskProgressSnapshot(items: [TaskProgressItem(
                title: title,
                kind: .waitingForInput,
                startedAt: taskStartedAt
            )])
        }
        if now.timeIntervalSince(modificationDate) <= 30 * 60 {
            return TaskProgressSnapshot(items: [TaskProgressItem(
                title: title,
                kind: .running,
                startedAt: taskStartedAt
            )])
        }
        return .idle
    }

    private static func taskTitle(from rawMessage: String) -> String? {
        var value = rawMessage
        if let marker = value.range(
            of: "## My request for Codex:",
            options: [.caseInsensitive]
        ) {
            value = String(value[marker.upperBound...])
        }
        if let imageTag = value.range(of: "<image", options: [.caseInsensitive]) {
            value = String(value[..<imageTag.lowerBound])
        }

        let lines = value.components(separatedBy: .newlines).compactMap {
            line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("# Files mentioned"),
                  !trimmed.hasPrefix("## My request"),
                  !trimmed.hasPrefix("/")
            else { return nil }
            return trimmed.trimmingCharacters(
                in: CharacterSet(charactersIn: "#*- ")
            )
        }
        let title = lines.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return String(title.prefix(80))
    }

    private static func timestamp(from record: [String: Any]) -> Date? {
        guard let raw = record["timestamp"] as? String else { return nil }
        return iso8601WithFractional.date(from: raw) ?? iso8601.date(from: raw)
    }

    static func threadID(from rolloutURL: URL) -> String? {
        let filename = rolloutURL.deletingPathExtension().lastPathComponent
        let pattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
        guard let range = filename.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        return String(filename[range]).lowercased()
    }

    static func resolvedTitle(
        for rolloutURL: URL,
        indexedTitles: [String: String],
        fallback: String
    ) -> String {
        guard let threadID = threadID(from: rolloutURL),
              let indexedTitle = indexedTitles[threadID],
              !indexedTitle.isEmpty
        else { return fallback }
        return indexedTitle
    }

    private static func userVisibilityFromSessionMetadata(
        line: String
    ) -> Bool? {
        guard let data = line.data(using: .utf8),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              record["type"] as? String == "session_meta",
              let payload = record["payload"] as? [String: Any]
        else {
            return nil
        }

        let threadSource = (payload["thread_source"] as? String)?.lowercased()
        if threadSource == "subagent" || threadSource == "automation" {
            return false
        }
        if let source = payload["source"] as? [String: Any], source["subagent"] != nil {
            return false
        }
        return true
    }

    static func isUserVisibleSessionMetadata(line: String) -> Bool {
        userVisibilityFromSessionMetadata(line: line) == true
    }

    static func shouldDisplay(
        kind: TaskProgressKind,
        threadID: String?,
        modificationDate: Date,
        now: Date,
        unreadState: UnreadThreadState,
        fallbackVisibility: TimeInterval = 2 * 60
    ) -> Bool {
        guard kind == .completed || kind == .failed else { return true }
        if unreadState.isAvailable, let threadID {
            return unreadState.ids.contains(threadID)
        }
        return now.timeIntervalSince(modificationDate) <= fallbackVisibility
    }

    private func codexHomeURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["CODEX_HOME"],
           !override.isEmpty
        {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }

    private func readThreadTitleIndex() -> [String: String] {
        let indexURL = codexHomeURL().appendingPathComponent("session_index.jsonl")
        guard let values = try? indexURL.resourceValues(
            forKeys: [.contentModificationDateKey, .isRegularFileKey]
        ),
        values.isRegularFile == true,
        let modificationDate = values.contentModificationDate
        else {
            return cachedThreadTitles
        }

        if cachedThreadIndexModificationDate == modificationDate {
            return cachedThreadTitles
        }
        guard let data = try? Data(contentsOf: indexURL),
              let text = String(data: data, encoding: .utf8)
        else {
            return cachedThreadTitles
        }

        var titles: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let lineData = String(line).data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(
                      with: lineData
                  ) as? [String: Any],
                  let rawID = record["id"] as? String,
                  let rawTitle = record["thread_name"] as? String
            else { continue }
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            titles[rawID.lowercased()] = String(title.prefix(80))
        }

        cachedThreadTitles = titles
        cachedThreadIndexModificationDate = modificationDate
        return titles
    }

    private func readUnreadThreadState() -> UnreadThreadState {
        let stateURL: URL
        if let override = ProcessInfo.processInfo.environment[
            "CODEX_STATUS_PANEL_STATE_FILE"
        ],
        !override.isEmpty
        {
            stateURL = URL(fileURLWithPath: override)
        } else if let override = ProcessInfo.processInfo.environment[
            "CODEX_PANEL_STATE_FILE"
        ],
        !override.isEmpty
        {
            stateURL = URL(fileURLWithPath: override)
        } else {
            stateURL = codexHomeURL().appendingPathComponent(
                ".codex-global-state.json"
            )
        }

        guard let values = try? stateURL.resourceValues(
            forKeys: [.contentModificationDateKey, .isRegularFileKey]
        ),
        values.isRegularFile == true,
        let modificationDate = values.contentModificationDate
        else {
            return UnreadThreadState(
                ids: cachedUnreadThreadIDs,
                isAvailable: hasCachedUnreadState
            )
        }
        if cachedUnreadStateModificationDate == modificationDate {
            return UnreadThreadState(
                ids: cachedUnreadThreadIDs,
                isAvailable: hasCachedUnreadState
            )
        }

        guard let data = try? Data(contentsOf: stateURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let atomState = root["electron-persisted-atom-state"] as? [String: Any],
              let unreadByHost = atomState[
                  "unread-thread-ids-by-host-v1"
              ] as? [String: Any]
        else {
            return UnreadThreadState(
                ids: cachedUnreadThreadIDs,
                isAvailable: hasCachedUnreadState
            )
        }

        var ids = Set<String>()
        for value in unreadByHost.values {
            guard let hostIDs = value as? [String] else { continue }
            ids.formUnion(hostIDs.map { $0.lowercased() })
        }
        cachedUnreadThreadIDs = ids
        cachedUnreadStateModificationDate = modificationDate
        hasCachedUnreadState = true
        return UnreadThreadState(ids: ids, isAvailable: true)
    }

    private func recentRollouts(
        at now: Date,
        unreadThreadIDs: Set<String>
    ) -> [RolloutCandidate] {
        if let override = ProcessInfo.processInfo.environment[
            "CODEX_STATUS_PANEL_TASK_ROLLOUT_FILE"
        ],
        !override.isEmpty
        {
            let url = URL(fileURLWithPath: override)
            guard isUserVisibleRollout(url) else { return [] }
            let modified = (try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? now
            return [RolloutCandidate(url: url, modificationDate: modified)]
        }

        if now < nextRolloutScanAt, !cachedRollouts.isEmpty {
            cachedRollouts = cachedRollouts.compactMap { candidate in
                guard let values = try? candidate.url.resourceValues(
                    forKeys: [
                        .contentModificationDateKey,
                        .isRegularFileKey,
                    ]
                ),
                values.isRegularFile == true,
                let modificationDate = values.contentModificationDate
                else { return nil }
                return RolloutCandidate(
                    url: candidate.url,
                    modificationDate: modificationDate
                )
            }
            trackedActiveRolloutPaths.formIntersection(
                cachedRollouts.map { $0.url.path }
            )
            return cachedRollouts
        }

        nextRolloutScanAt = now.addingTimeInterval(rolloutRescanInterval)
        let sessionsURL = codexHomeURL().appendingPathComponent(
            "sessions",
            isDirectory: true
        )
        let resourceKeys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .isRegularFileKey,
        ]
        var discoveredByPath: [String: RolloutCandidate] = [:]
        for directory in discoverySessionDirectories(
            sessionsURL: sessionsURL,
            at: now
        ) {
            guard let urls = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in urls {
                guard let candidate = rolloutCandidate(
                    at: url,
                    resourceKeys: resourceKeys
                ) else { continue }
                discoveredByPath[url.path] = candidate
            }
        }

        var existingTrackedPaths = Set<String>()
        for path in trackedActiveRolloutPaths {
            let url = URL(fileURLWithPath: path)
            guard let candidate = rolloutCandidate(
                at: url,
                resourceKeys: resourceKeys
            ) else { continue }
            existingTrackedPaths.insert(path)
            discoveredByPath[path] = candidate
        }
        trackedActiveRolloutPaths.formIntersection(existingTrackedPaths)

        let discovered = discoveredByPath.values.filter { candidate in
            let path = candidate.url.path
            if trackedActiveRolloutPaths.contains(path) { return true }
            let isUnread = Self.threadID(from: candidate.url).map {
                unreadThreadIDs.contains($0)
            } ?? false
            if isUnread { return true }
            return now.timeIntervalSince(candidate.modificationDate)
                <= initialActiveDiscoveryWindow
        }
        let sorted = discovered.sorted { left, right in
            let leftTracked = trackedActiveRolloutPaths.contains(left.url.path)
            let rightTracked = trackedActiveRolloutPaths.contains(right.url.path)
            if leftTracked != rightTracked { return leftTracked }
            let leftUnread = Self.threadID(from: left.url).map {
                unreadThreadIDs.contains($0)
            } ?? false
            let rightUnread = Self.threadID(from: right.url).map {
                unreadThreadIDs.contains($0)
            } ?? false
            if leftUnread != rightUnread { return leftUnread }
            return left.modificationDate > right.modificationDate
        }
        var candidates: [RolloutCandidate] = []
        for candidate in sorted.prefix(maximumMetadataCandidates)
            where isUserVisibleRollout(candidate.url)
        {
            candidates.append(candidate)
            if candidates.count == maximumRolloutCandidates { break }
        }

        cachedRollouts = candidates
        let activePaths = Set(cachedRollouts.map { $0.url.path })
        parsedCache = parsedCache.filter { activePaths.contains($0.key) }
        return cachedRollouts
    }

    private func discoverySessionDirectories(
        sessionsURL: URL,
        at now: Date
    ) -> [URL] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return (0..<discoveryDayCount).compactMap { dayOffset in
            guard let date = calendar.date(
                byAdding: .day,
                value: -dayOffset,
                to: now
            ) else { return nil }
            let components = calendar.dateComponents(
                [.year, .month, .day],
                from: date
            )
            guard let year = components.year,
                  let month = components.month,
                  let day = components.day
            else { return nil }
            return sessionsURL.appendingPathComponent(
                String(format: "%04d/%02d/%02d", year, month, day),
                isDirectory: true
            )
        }
    }

    private func rolloutCandidate(
        at url: URL,
        resourceKeys: Set<URLResourceKey>
    ) -> RolloutCandidate? {
        guard url.pathExtension == "jsonl",
              url.lastPathComponent.hasPrefix("rollout-"),
              let values = try? url.resourceValues(forKeys: resourceKeys),
              values.isRegularFile == true,
              let modificationDate = values.contentModificationDate
        else { return nil }
        return RolloutCandidate(
            url: url,
            modificationDate: modificationDate
        )
    }

    private func isUserVisibleRollout(_ url: URL) -> Bool {
        if let cached = cachedRolloutVisibility[url.path] { return cached }

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumMetadataBytes),
              let text = String(data: data, encoding: .utf8),
              let firstLine = text.split(
                  separator: "\n",
                  maxSplits: 1
              ).first,
              let isVisible = Self.userVisibilityFromSessionMetadata(
                  line: String(firstLine)
              )
        else { return false }

        cachedRolloutVisibility[url.path] = isVisible
        return isVisible
    }

    private func readTailLines(from url: URL) -> [String]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        let startOffset = fileSize > maximumTailBytes
            ? fileSize - maximumTailBytes
            : 0
        do {
            try handle.seek(toOffset: startOffset)
            guard var data = try handle.readToEnd(), !data.isEmpty else {
                return []
            }
            if startOffset > 0,
               let firstNewline = data.firstIndex(of: 0x0A)
            {
                data.removeSubrange(...firstNewline)
            }
            guard let text = String(data: data, encoding: .utf8) else {
                return nil
            }
            return text.split(whereSeparator: \.isNewline).map(String.init)
        } catch {
            return nil
        }
    }

    private static let iso8601WithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        return formatter
    }()

    private static let iso8601 = ISO8601DateFormatter()
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
    case authentication(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .codexNotFound:
            return "没有找到 Codex 本机服务"
        case .launchFailed(let detail):
            return "无法启动 Codex 本机服务：\(detail)"
        case .noResponse:
            return "Codex 暂未返回额度数据"
        case .authentication(let detail):
            return detail
        case .server(let detail):
            return detail
        }
    }
}

private struct CodexConfigurationReader {
    private enum TopLevelLineResult {
        case skip
        case stop
        case provider(String)
    }

    private static let maximumConfigBytes = 64 * 1_024
    private static let configReadChunkBytes = 4 * 1_024

    static func modelProvider(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var buffer = Data()
        var bytesRead = 0
        while bytesRead < maximumConfigBytes {
            let requestedBytes = min(
                configReadChunkBytes,
                maximumConfigBytes - bytesRead
            )
            guard let chunk = try? handle.read(upToCount: requestedBytes),
                  !chunk.isEmpty
            else { break }
            bytesRead += chunk.count
            buffer.append(chunk)

            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[..<newline]
                buffer.removeSubrange(...newline)
                switch topLevelLineResult(
                    String(decoding: lineData, as: UTF8.self)
                ) {
                case .provider(let provider):
                    return provider
                case .stop:
                    return nil
                case .skip:
                    continue
                }
            }
        }

        guard !buffer.isEmpty else { return nil }
        if case .provider(let provider) = topLevelLineResult(
            String(decoding: buffer, as: UTF8.self)
        ) {
            return provider
        }
        return nil
    }

    static func modelProvider(from source: String) -> String? {
        for rawLine in source.components(separatedBy: .newlines) {
            switch topLevelLineResult(rawLine) {
            case .provider(let provider):
                return provider
            case .stop:
                return nil
            case .skip:
                continue
            }
        }
        return nil
    }

    private static func topLevelLineResult(
        _ rawLine: String
    ) -> TopLevelLineResult {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if isTOMLTableHeader(line) { return .stop }
        guard !line.isEmpty,
              !line.hasPrefix("#"),
              let equals = line.firstIndex(of: "=")
        else { return .skip }

        let key = line[..<equals].trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard key == "model_provider" else { return .skip }

        var value = line[line.index(after: equals)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return .stop }

        if let quote = value.first, quote == "\"" || quote == "'" {
            value.removeFirst()
            guard let closingQuote = value.firstIndex(of: quote) else {
                return .stop
            }
            value = String(value[..<closingQuote])
        } else {
            value = String(value.prefix {
                !$0.isWhitespace && $0 != "#"
            })
        }

        let provider = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !provider.isEmpty else { return .stop }
        return .provider(String(provider.prefix(80)))
    }

    private static func isTOMLTableHeader(_ line: String) -> Bool {
        let key = #"(?:[A-Za-z0-9_-]+|\"(?:\\.|[^\"])*\"|'[^']*')"#
        let keyPath = key + #"(?:\s*\.\s*"# + key + #")*"#
        let suffix = #"\s*(?:#.*)?$"#
        let singleTable = #"^\[\s*"# + keyPath + #"\s*\]"# + suffix
        let arrayTable = #"^\[\[\s*"# + keyPath + #"\s*\]\]"# + suffix
        return line.range(of: singleTable, options: .regularExpression) != nil
            || line.range(of: arrayTable, options: .regularExpression) != nil
    }
}

private func codexConfigurationURL() -> URL {
    if let override = ProcessInfo.processInfo.environment["CODEX_HOME"],
       !override.isEmpty
    {
        return URL(fileURLWithPath: override, isDirectory: true)
            .appendingPathComponent("config.toml")
    }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex", isDirectory: true)
        .appendingPathComponent("config.toml")
}

private func quotaErrorDisplayText(
    _ error: Error,
    modelProviderLoader: () -> String?
) -> String {
    guard let quotaError = error as? QuotaClientError else {
        return error.localizedDescription
    }
    switch quotaError {
    case .authentication(let message):
        return quotaErrorDisplayText(
            message,
            modelProvider: modelProviderLoader()
        )
    default:
        return error.localizedDescription
    }
}

private func quotaErrorDisplayText(
    _ message: String,
    modelProvider: String?
) -> String {
    guard message.range(
        of: "authentication",
        options: [.caseInsensitive]
    ) != nil else {
        return message
    }

    if let modelProvider, !modelProvider.isEmpty {
        return "model_provider: \(modelProvider)"
    }
    return "Codex 未登录或认证已失效"
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
            if error.message.range(
                of: "authentication",
                options: [.caseInsensitive]
            ) != nil {
                return .failure(QuotaClientError.authentication(error.message))
            }
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
    var taskProgress = TaskProgressSnapshot.reading {
        didSet {
            if taskProgress != oldValue {
                needsDisplay = true
                updateRunningArrowTimer()
            }
        }
    }
    var showsMarketPrices = initialMarketPricesEnabled {
        didSet { needsDisplay = true }
    }
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
            window?.invalidateShadow()
        }
    }
    var pointerCenterX: CGFloat? {
        didSet {
            guard pointerCenterX != oldValue else { return }
            needsDisplay = true
            window?.invalidateShadow()
        }
    }
    var isCollapsed = false {
        didSet {
            needsDisplay = true
            updateRunningArrowTimer()
            window?.invalidateCursorRects(for: self)
            window?.invalidateShadow()
        }
    }
    var onToggleCollapsed: (() -> Void)?
    private var hideButtonTrackingArea: NSTrackingArea?
    private var isHideButtonHovered = false
    private var runningArrowTimer: Timer?
    private var windowVisibilityObservers: [NSObjectProtocol] = []

    private lazy var backgroundImage: NSImage? = {
        guard let resourceURL = Bundle.main.resourceURL?
            .appendingPathComponent(panelConfig.theme.backgroundImage)
        else { return nil }
        return NSImage(contentsOf: resourceURL)
    }()

    private lazy var completedTaskIcon: NSImage? = taskIcon(
        named: "task-completed-icon.png"
    )
    private lazy var runningTaskIcon: NSImage? = taskIcon(
        named: "task-running-icon.png"
    )
    private lazy var waitingTaskIcon: NSImage? = taskIcon(
        named: "task-waiting-icon.png"
    )
    private lazy var failedTaskIcon: NSImage? = taskIcon(
        named: "task-failed-icon.png"
    )

    private func taskIcon(named name: String) -> NSImage? {
        guard let resourceURL = Bundle.main.resourceURL?
            .appendingPathComponent(name)
        else { return nil }
        return NSImage(contentsOf: resourceURL)
    }

    override var isFlipped: Bool { true }

    deinit {
        runningArrowTimer?.invalidate()
        windowVisibilityObservers.forEach {
            NotificationCenter.default.removeObserver($0)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowVisibilityObservers.forEach {
            NotificationCenter.default.removeObserver($0)
        }
        windowVisibilityObservers.removeAll()
        if let window {
            let center = NotificationCenter.default
            windowVisibilityObservers.append(center.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.updateRunningArrowTimer()
            })
        }
        updateRunningArrowTimer()
    }

    private func updateRunningArrowTimer() {
        let hasRunningTask = taskProgress.items.contains {
            $0.kind == .running
        }
        let shouldAnimate = shouldAnimateRunningArrow(
            isWindowVisible: window?.isVisible == true,
            isCollapsed: isCollapsed,
            hasRunningTask: hasRunningTask
        )
        if shouldAnimate, runningArrowTimer == nil {
            let timer = Timer(
                timeInterval: 1.0 / 30.0,
                repeats: true
            ) { [weak self] timer in
                guard let self else {
                    timer.invalidate()
                    return
                }
                let remainsVisible = shouldAnimateRunningArrow(
                    isWindowVisible: self.window?.isVisible == true,
                    isCollapsed: self.isCollapsed,
                    hasRunningTask: self.taskProgress.items.contains {
                        $0.kind == .running
                    }
                )
                guard remainsVisible else {
                    timer.invalidate()
                    self.runningArrowTimer = nil
                    return
                }
                self.needsDisplay = true
            }
            RunLoop.main.add(timer, forMode: .common)
            runningArrowTimer = timer
        } else if !shouldAnimate {
            runningArrowTimer?.invalidate()
            runningArrowTimer = nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSGraphicsContext.current?.imageInterpolation = .high

        let bodyRect = panelBodyRect()

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
            arrow.line(to: NSPoint(x: panelVerticalCanvasInset, y: centerY))
            arrow.line(to: NSPoint(x: bodyRect.minX + 1, y: centerY + 8))
        case .right:
            let centerY = bodyRect.midY
            arrow.move(to: NSPoint(x: bodyRect.maxX - 1, y: centerY - 8))
            arrow.line(to: NSPoint(x: bounds.maxX - panelVerticalCanvasInset, y: centerY))
            arrow.line(to: NSPoint(x: bodyRect.maxX - 1, y: centerY + 8))
        case .bottom:
            let requestedCenterX = pointerCenterX ?? bodyRect.midX
            let centerX = min(
                max(requestedCenterX, bodyRect.minX + 12),
                bodyRect.maxX - 12
            )
            arrow.move(to: NSPoint(x: centerX - 8, y: bodyRect.maxY - 1))
            arrow.line(to: NSPoint(x: centerX, y: bounds.maxY - panelVerticalCanvasInset))
            arrow.line(to: NSPoint(x: centerX + 8, y: bodyRect.maxY - 1))
        }
        arrow.close()
        background.setFill()
        arrow.fill()
        border.setStroke()
        arrow.lineWidth = 1
        arrow.stroke()

        if isCollapsed {
            let label = "展开"
            let labelFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
            let labelHeight = (label as NSString).size(withAttributes: [.font: labelFont]).height
            drawText(
                label,
                in: NSRect(
                    x: bodyRect.minX,
                    y: bodyRect.midY - labelHeight / 2,
                    width: bodyRect.width,
                    height: labelHeight
                ),
                font: labelFont,
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
                in: NSRect(x: contentX, y: bodyRect.minY + 11, width: contentWidth - 48, height: 18),
                font: .systemFont(ofSize: 12.4, weight: .semibold),
                color: NSColor.white.withAlphaComponent(0.88)
            )
        } else if let errorText {
            drawText(
                errorText,
                in: NSRect(x: contentX, y: bodyRect.minY + 11, width: contentWidth - 48, height: 38),
                font: .systemFont(ofSize: 12, weight: .medium),
                color: NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.38, alpha: 1)
            )
        } else if rows.isEmpty {
            drawText(
                "正在向 Codex 本机服务查询…",
                in: NSRect(x: contentX, y: bodyRect.minY + 11, width: contentWidth - 48, height: 20),
                font: .systemFont(ofSize: 11.5, weight: .medium),
                color: NSColor.white.withAlphaComponent(0.68)
            )
        } else {
            for (index, row) in rows.prefix(1).enumerated() {
                draw(row: row, index: index, bodyMinY: bodyRect.minY, x: contentX, width: contentWidth)
            }
        }

        drawText(
            composedStatusText,
            in: NSRect(
                x: contentX,
                y: bodyRect.minY + 74,
                width: contentWidth,
                height: 14
            ),
            font: .systemFont(ofSize: 9.2, weight: .regular),
            color: NSColor.white.withAlphaComponent(0.72),
            alignment: .right
        )

        let taskItems = taskProgress.items.isEmpty
            ? TaskProgressSnapshot.idle.items
            : taskProgress.items
        for (index, item) in taskItems.enumerated() {
            drawTaskProgressItem(
                item,
                index: index,
                y: bodyRect.minY + 100
                    + CGFloat(index) * taskProgressRowHeight,
                separatorY: bodyRect.minY + 93
                    + CGFloat(index) * taskProgressRowHeight,
                contentX: contentX,
                contentWidth: contentWidth
            )
        }
        let taskSectionHeight = taskProgressRowHeight
            * CGFloat(max(1, taskItems.count))

        if showsMarketPrices {
            drawMarketPriceRow(
                symbol: "BTC/USDT",
                iconText: "₿",
                iconColor: NSColor(calibratedRed: 0.97, green: 0.58, blue: 0.11, alpha: 1),
                price: btcPrice,
                direction: btcPriceDirection,
                statusText: btcStatusText,
                y: bodyRect.minY + 100 + taskSectionHeight,
                separatorY: bodyRect.minY + 93 + taskSectionHeight,
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
                y: bodyRect.minY + 100
                    + taskSectionHeight
                    + marketPriceRowHeight,
                separatorY: bodyRect.minY + 93
                    + taskSectionHeight
                    + marketPriceRowHeight,
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
        switch pointerSide {
        case .left:
            let x = panelVerticalCanvasInset + panelPointerLength - 1
            return NSRect(
                x: x,
                y: panelVerticalCanvasInset,
                width: bounds.width - x - panelHorizontalCanvasInset,
                height: bounds.height - panelVerticalCanvasInset * 2
            )
        case .right:
            return NSRect(
                x: panelHorizontalCanvasInset,
                y: panelVerticalCanvasInset,
                width: bounds.width - panelHorizontalCanvasInset - panelVerticalCanvasInset - panelPointerLength + 1,
                height: bounds.height - panelVerticalCanvasInset * 2
            )
        case .bottom:
            return NSRect(
                x: panelHorizontalCanvasInset,
                y: panelVerticalCanvasInset,
                width: bounds.width - panelHorizontalCanvasInset * 2,
                height: bounds.height - panelVerticalCanvasInset * 2 - panelPointerLength + 1
            )
        }
    }

    private func hideButtonRect(in bodyRect: NSRect) -> NSRect {
        NSRect(x: bodyRect.maxX - 48, y: bodyRect.minY + 7, width: 38, height: 18)
    }

    private func draw(row: QuotaRow, index: Int, bodyMinY: CGFloat, x: CGFloat, width: CGFloat) {
        let top = bodyMinY + CGFloat(10 + index * 43)
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

    private func drawTaskProgressItem(
        _ item: TaskProgressItem,
        index: Int,
        y: CGFloat,
        separatorY: CGFloat,
        contentX: CGFloat,
        contentWidth: CGFloat
    ) {
        let separator = NSBezierPath()
        separator.move(to: NSPoint(x: contentX, y: separatorY))
        separator.line(to: NSPoint(
            x: contentX + contentWidth,
            y: separatorY
        ))
        NSColor.white.withAlphaComponent(0.13).setStroke()
        separator.lineWidth = 0.75
        separator.stroke()

        let color = taskProgressColor(for: item.kind)
        let taskIcon: NSImage?
        switch item.kind {
        case .running:
            taskIcon = runningTaskIcon
        case .waitingForInput:
            taskIcon = waitingTaskIcon
        case .completed:
            taskIcon = completedTaskIcon
        case .failed:
            taskIcon = failedTaskIcon
        case .reading, .idle:
            taskIcon = nil
        }

        let usesStatusIcon = taskIcon != nil
        if let taskIcon {
            let iconRect = NSRect(
                x: contentX - 2,
                y: y,
                width: 20,
                height: 15
            )
            taskIcon.draw(
                in: iconRect,
                from: NSRect(origin: .zero, size: taskIcon.size),
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
            drawTaskStatusBadge(for: item.kind, iconRect: iconRect)
        } else {
            let dot = NSBezierPath(ovalIn: NSRect(
                x: contentX,
                y: y + 4,
                width: 7,
                height: 7
            ))
            color.setFill()
            dot.fill()
        }

        let titleOffset: CGFloat = usesStatusIcon ? 22 : 13
        let titleReservedWidth: CGFloat = usesStatusIcon ? 89 : 80
        drawText(
            item.title,
            in: NSRect(
                x: contentX + titleOffset,
                y: y,
                width: contentWidth - titleReservedWidth,
                height: 15
            ),
            font: .systemFont(
                ofSize: 9.4,
                weight: index == 0 ? .semibold : .medium
            ),
            color: NSColor.white.withAlphaComponent(0.84)
        )
        drawText(
            item.statusText,
            in: NSRect(
                x: contentX + contentWidth - 66,
                y: y,
                width: 66,
                height: 15
            ),
            font: .systemFont(ofSize: 9.2, weight: .semibold),
            color: color,
            alignment: .right
        )
    }

    private func drawTaskStatusBadge(
        for kind: TaskProgressKind,
        iconRect: NSRect
    ) {
        guard kind != .completed && kind != .failed else { return }

        let badgeRect = NSRect(
            x: iconRect.minX + 10.6,
            y: iconRect.minY + 0.4,
            width: 8.4,
            height: 8.4
        )
        let badge = NSBezierPath(ovalIn: badgeRect)
        switch kind {
        case .running:
            NSColor(
                calibratedRed: 0.12,
                green: 0.46,
                blue: 0.96,
                alpha: 1
            ).setFill()
            badge.fill()
            drawRunningArrow(in: badgeRect)
        case .waitingForInput:
            NSColor(
                calibratedRed: 1.0,
                green: 0.76,
                blue: 0.10,
                alpha: 1
            ).setFill()
            badge.fill()
            drawText(
                "?",
                in: badgeRect.offsetBy(dx: 0, dy: -0.4),
                font: .systemFont(ofSize: 7.2, weight: .heavy),
                color: .white,
                alignment: .center
            )
        case .reading, .completed, .failed, .idle:
            break
        }
    }

    private func drawRunningArrow(in badgeRect: NSRect) {
        let center = NSPoint(x: badgeRect.midX, y: badgeRect.midY)
        let radius = badgeRect.width * 0.31
        let progress = Date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: 1.2) / 1.2
        let rotation = CGFloat(progress) * 2 * .pi
        let start: CGFloat = rotation - .pi * 0.40
        let sweep: CGFloat = .pi * 1.56
        let segments = 18
        let arc = NSBezierPath()
        for index in 0...segments {
            let angle = start + sweep * CGFloat(index) / CGFloat(segments)
            let point = NSPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )
            if index == 0 {
                arc.move(to: point)
            } else {
                arc.line(to: point)
            }
        }
        NSColor.white.setStroke()
        arc.lineWidth = 1.05
        arc.lineCapStyle = .round
        arc.stroke()

        let end = start + sweep
        let tip = NSPoint(
            x: center.x + cos(end) * radius,
            y: center.y + sin(end) * radius
        )
        let tangent = NSPoint(x: -sin(end), y: cos(end))
        let normal = NSPoint(x: -tangent.y, y: tangent.x)
        let base = NSPoint(
            x: tip.x - tangent.x * 1.6,
            y: tip.y - tangent.y * 1.6
        )
        let head = NSBezierPath()
        head.move(to: tip)
        head.line(to: NSPoint(
            x: base.x + normal.x * 0.72,
            y: base.y + normal.y * 0.72
        ))
        head.line(to: NSPoint(
            x: base.x - normal.x * 0.72,
            y: base.y - normal.y * 0.72
        ))
        head.close()
        NSColor.white.setFill()
        head.fill()
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

    private func taskProgressColor(for kind: TaskProgressKind) -> NSColor {
        switch kind {
        case .reading, .running:
            return NSColor(
                calibratedRed: 0.10,
                green: 0.78,
                blue: 1.0,
                alpha: 1
            )
        case .waitingForInput:
            return NSColor(
                calibratedRed: 1.0,
                green: 0.79,
                blue: 0.18,
                alpha: 1
            )
        case .completed:
            return NSColor(
                calibratedRed: 0.24,
                green: 0.86,
                blue: 0.58,
                alpha: 1
            )
        case .failed:
            return NSColor(
                calibratedRed: 1.0,
                green: 0.39,
                blue: 0.43,
                alpha: 1
            )
        case .idle:
            return NSColor.white.withAlphaComponent(0.54)
        }
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
    private let taskProgressReader = CodexTaskProgressReader()
    private let btcPriceClient = MarketPriceClient(symbol: "BTCUSDT")
    private let ethPriceClient = MarketPriceClient(symbol: "ETHUSDT")
    private let locator = PetWindowLocator()
    private let healthWriter = RuntimeHealthWriter()
    private let quotaView = QuotaPanelView(frame: NSRect(origin: .zero, size: expandedPanelSize))
    private var currentExpandedPanelSize = expandedPanelSize
    private var panel: NSPanel!
    private var statusItem: NSStatusItem?
    private let statusMenu = NSMenu()
    private let codexStatusMenuItem = NSMenuItem()
    private let followStatusMenuItem = NSMenuItem()
    private let showPanelMenuItem = NSMenuItem(title: "显示面板", action: #selector(showPanelFromMenu(_:)), keyEquivalent: "")
    private let hidePanelMenuItem = NSMenuItem(title: "隐藏面板", action: #selector(hidePanelFromMenu(_:)), keyEquivalent: "")
    private let collapsePanelMenuItem = NSMenuItem(title: "折叠面板", action: #selector(toggleCollapsedFromMenu(_:)), keyEquivalent: "")
    private let refreshQuotaMenuItem = NSMenuItem(title: "立即刷新额度", action: #selector(refreshQuotaFromMenu(_:)), keyEquivalent: "r")
    private let toggleMarketPricesMenuItem = NSMenuItem(
        title: "显示行情列表",
        action: #selector(toggleMarketPricesFromMenu(_:)),
        keyEquivalent: ""
    )
    private let resetFollowMenuItem = NSMenuItem(title: "重置跟随位置", action: #selector(resetFollowPositionFromMenu(_:)), keyEquivalent: "")
    private let openConfigMenuItem = NSMenuItem(title: "打开配置文件", action: #selector(openConfigFileFromMenu(_:)), keyEquivalent: ",")
    private var refreshTimer: Timer?
    private var taskProgressTimer: Timer?
    private var btcRefreshTimer: Timer?
    private var followTimer: Timer?
    private var isRefreshing = false
    private var isRefreshingTaskProgress = false
    private var isRefreshingBTCPrice = false
    private var isRefreshingETHPrice = false
    private var showsMarketPrices = initialMarketPricesEnabled
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
        quotaView.showsMarketPrices = showsMarketPrices
        writeHealth(status: "started", panelVisible: false, locationSource: nil, force: true)
        followPet()
        refreshQuota()
        refreshTaskProgress()
        if showsMarketPrices {
            refreshBTCPrice()
            refreshETHPrice()
        }

        followTimer = Timer.scheduledTimer(withTimeInterval: followInterval, repeats: true) { [weak self] _ in
            self?.followPet()
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refreshQuota()
        }
        taskProgressTimer = Timer.scheduledTimer(
            withTimeInterval: taskProgressRefreshInterval,
            repeats: true
        ) { [weak self] _ in
            self?.refreshTaskProgress()
        }
        if showsMarketPrices {
            btcRefreshTimer = Timer.scheduledTimer(withTimeInterval: btcRefreshInterval, repeats: true) { [weak self] _ in
                self?.refreshBTCPrice()
                self?.refreshETHPrice()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        taskProgressTimer?.invalidate()
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
            toggleMarketPricesMenuItem,
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
            isRefreshing: isRefreshing,
            showsMarketPrices: showsMarketPrices
        )
        let signature = [
            codexTitle,
            followTitle,
            String(controlState.showPanelEnabled),
            String(controlState.hidePanelEnabled),
            controlState.collapseTitle,
            String(controlState.refreshQuotaEnabled),
            String(controlState.marketPricesEnabled),
        ].joined(separator: "|")

        if force || signature != lastStatusMenuSignature {
            codexStatusMenuItem.title = codexTitle
            followStatusMenuItem.title = followTitle
            showPanelMenuItem.isEnabled = controlState.showPanelEnabled
            hidePanelMenuItem.isEnabled = controlState.hidePanelEnabled
            collapsePanelMenuItem.title = controlState.collapseTitle
            refreshQuotaMenuItem.isEnabled = controlState.refreshQuotaEnabled
            toggleMarketPricesMenuItem.state = controlState.marketPricesEnabled
                ? .on
                : .off
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
            contentRect: NSRect(origin: .zero, size: currentExpandedPanelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = quotaView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
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
        panel.setContentSize(
            quotaView.isCollapsed
                ? collapsedPanelSize
                : currentExpandedPanelSize
        )
        panel.invalidateShadow()
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

    @objc private func toggleMarketPricesFromMenu(_ sender: Any?) {
        setMarketPricesEnabled(!showsMarketPrices)
    }

    private func setMarketPricesEnabled(_ enabled: Bool) {
        guard showsMarketPrices != enabled else {
            updateStatusMenu()
            return
        }

        showsMarketPrices = enabled
        UserDefaults.standard.set(enabled, forKey: marketPricesPreferenceKey)
        quotaView.showsMarketPrices = enabled

        if enabled {
            refreshBTCPrice()
            refreshETHPrice()
            if btcRefreshTimer == nil {
                btcRefreshTimer = Timer.scheduledTimer(
                    withTimeInterval: btcRefreshInterval,
                    repeats: true
                ) { [weak self] _ in
                    self?.refreshBTCPrice()
                    self?.refreshETHPrice()
                }
            }
        } else {
            btcRefreshTimer?.invalidate()
            btcRefreshTimer = nil
        }

        currentExpandedPanelSize = panelSizeForTaskRows(
            quotaView.taskProgress.rowCount,
            showsMarketPrices: enabled
        )
        if !quotaView.isCollapsed {
            panel.setContentSize(currentExpandedPanelSize)
        }
        if !isPanelHiddenByUser {
            followPet(forceStandaloneFallback: isManualStandaloneEnabled)
        }
        writeHealth(
            status: enabled ? "market-prices-shown" : "market-prices-hidden",
            panelVisible: panel.isVisible,
            locationSource: lastLocationSource,
            force: true
        )
        updateStatusMenu(force: true)
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
        let currentPanelSize = quotaView.isCollapsed
            ? collapsedPanelSize
            : currentExpandedPanelSize
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
        let currentPanelSize = quotaView.isCollapsed
            ? collapsedPanelSize
            : currentExpandedPanelSize
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
            let errorText: String?
            if case .failure(let error) = result {
                errorText = quotaErrorDisplayText(error) {
                    CodexConfigurationReader.modelProvider(
                        at: codexConfigurationURL()
                    )
                }
            } else {
                errorText = nil
            }

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
                    self.quotaView.errorText = errorText
                        ?? error.localizedDescription
                    self.quotaView.statusText = "重试中"
                }
                self.updateStatusMenu()
            }
        }
    }

    private func refreshTaskProgress() {
        guard !isRefreshingTaskProgress else { return }
        isRefreshingTaskProgress = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let snapshot = self.taskProgressReader.read()
            DispatchQueue.main.async {
                self.isRefreshingTaskProgress = false
                self.quotaView.taskProgress = snapshot
                let nextSize = panelSizeForTaskRows(
                    snapshot.rowCount,
                    showsMarketPrices: self.showsMarketPrices
                )
                guard nextSize != self.currentExpandedPanelSize else {
                    return
                }

                self.currentExpandedPanelSize = nextSize
                if !self.quotaView.isCollapsed {
                    self.panel.setContentSize(nextSize)
                }
                if !self.isPanelHiddenByUser {
                    self.followPet(
                        forceStandaloneFallback: self.isManualStandaloneEnabled
                    )
                }
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
            marketPricesEnabled: showsMarketPrices,
            panelHeight: currentExpandedPanelSize.height,
            gap: gap,
            centerError: centerError,
            force: force
        )
    }

    private func refreshBTCPrice() {
        guard showsMarketPrices, !isRefreshingBTCPrice else { return }
        isRefreshingBTCPrice = true

        btcPriceClient.fetch { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRefreshingBTCPrice = false
                guard self.showsMarketPrices else { return }
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
        guard showsMarketPrices, !isRefreshingETHPrice else { return }
        isRefreshingETHPrice = true

        ethPriceClient.fetch { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRefreshingETHPrice = false
                guard self.showsMarketPrices else { return }
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
            + "marketPricesEnabled=\(initialMarketPricesEnabled) "
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

private func runTaskProgressSelfTest() -> Never {
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

    let truncated = TaskProgressSnapshot.displaying((0..<7).map { index in
        TaskProgressItem(title: "任务 \(index + 1)", kind: .running, startedAt: now)
    })
    let sameTitleThreads = TaskProgressSnapshot.displaying([
        TaskProgressItem(title: "相同任务", kind: .running, startedAt: now),
        TaskProgressItem(title: "  相同任务  ", kind: .completed, startedAt: now),
    ])
    guard truncated.items.count == maximumVisibleTaskRows,
          truncated.items.last?.title == "任务 5",
          sameTitleThreads.items.count == 2
    else {
        fputs("task list truncation or same-title thread display failed\n", stderr)
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

    let fixtureDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "codex-status-panel-tasks-\(UUID().uuidString)",
            isDirectory: true
        )
    func fixtureSessionDirectory(for date: Date) -> URL {
        let components = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day],
            from: date
        )
        return fixtureDirectory.appendingPathComponent(
            String(
                format: "sessions/%04d/%02d/%02d",
                components.year ?? 0,
                components.month ?? 0,
                components.day ?? 0
            ),
            isDirectory: true
        )
    }
    let sessionsDirectory = fixtureSessionDirectory(for: now)
    let staleSessionsDirectory = fixtureSessionDirectory(
        for: now.addingTimeInterval(-7 * 24 * 60 * 60)
    )
    let freshRollout = sessionsDirectory.appendingPathComponent(
        "rollout-2026-07-23T12-00-00-11111111-1111-4111-8111-111111111111.jsonl"
    )
    let longRunningRollout = sessionsDirectory.appendingPathComponent(
        "rollout-2026-07-23T10-00-00-22222222-2222-4222-8222-222222222222.jsonl"
    )
    let partialMetadataRollout = sessionsDirectory.appendingPathComponent(
        "rollout-2026-07-23T12-01-00-33333333-3333-4333-8333-333333333333.jsonl"
    )
    let staleRollout = staleSessionsDirectory.appendingPathComponent(
        "rollout-2026-07-16T12-00-00-55555555-5555-4555-8555-555555555555.jsonl"
    )
    let metadata = #"{"type":"session_meta","payload":{"thread_source":"user","source":{"cli":{}}}}"#
    let freshTitle = #"{"type":"event_msg","payload":{"type":"user_message","message":"缓存刷新任务"}}"#
    let longTitle = #"{"type":"event_msg","payload":{"type":"user_message","message":"长时间任务"}}"#
    let recoveredTitle = #"{"type":"event_msg","payload":{"type":"user_message","message":"恢复后的任务"}}"#
    let staleTitle = #"{"type":"event_msg","payload":{"type":"user_message","message":"历史异常残留"}}"#
    let unreadStateURL = fixtureDirectory.appendingPathComponent(
        ".codex-global-state.json"
    )
    let readStateJSON = #"{"electron-persisted-atom-state":{"unread-thread-ids-by-host-v1":{"local":["11111111-1111-4111-8111-111111111111"]}}}"#
    let previousCodexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
    var integrationFailures: [String] = []

    do {
        try FileManager.default.createDirectory(
            at: sessionsDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: staleSessionsDirectory,
            withIntermediateDirectories: true
        )
        try Data("\(metadata)\n\(freshTitle)\n\(started)\n".utf8)
            .write(to: freshRollout)
        try Data("\(metadata)\n\(longTitle)\n\(started)\n".utf8)
            .write(to: longRunningRollout)
        try Data("{\"type\":\"session_me".utf8)
            .write(to: partialMetadataRollout)
        try Data("\(metadata)\n\(staleTitle)\n\(started)\n".utf8)
            .write(to: staleRollout)
        try Data(readStateJSON.utf8).write(to: unreadStateURL)
        for index in 0..<13 {
            let suffix = String(format: "%012d", index + 1)
            let terminalURL = sessionsDirectory.appendingPathComponent(
                "rollout-2026-07-23T11-\(String(format: "%02d", index))-00-"
                    + "44444444-4444-4444-8444-\(suffix).jsonl"
            )
            let terminalTitle =
                #"{"type":"event_msg","payload":{"type":"user_message","message":"已读终态 "#
                + "\(index + 1)"
                + #""}}"#
            try Data(
                "\(metadata)\n\(terminalTitle)\n\(started)\n\(completed)\n".utf8
            ).write(to: terminalURL)
        }
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-45 * 60)],
            ofItemAtPath: longRunningRollout.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-7 * 24 * 60 * 60)],
            ofItemAtPath: staleRollout.path
        )

        setenv("CODEX_HOME", fixtureDirectory.path, 1)
        let reader = CodexTaskProgressReader()
        let initial = reader.read(at: now)
        if !initial.items.contains(where: {
            $0.title == "长时间任务" && $0.kind == .running
        }) {
            integrationFailures.append("long-running")
        }
        if initial.items.contains(where: { $0.title == "Codex 任务" }) {
            integrationFailures.append("partial-metadata-hidden")
        }
        if initial.items.contains(where: { $0.title.hasPrefix("已读终态") }) {
            integrationFailures.append("read-terminal-filtering")
        }
        if initial.items.contains(where: { $0.title == "历史异常残留" }) {
            integrationFailures.append("stale-running-hidden")
        }

        try Data("\(metadata)\n\(freshTitle)\n\(started)\n\(completed)\n".utf8)
            .write(to: freshRollout)
        try Data("\(metadata)\n\(recoveredTitle)\n\(started)\n".utf8)
            .write(to: partialMetadataRollout)
        let updatedDate = Date().addingTimeInterval(1)
        try FileManager.default.setAttributes(
            [.modificationDate: updatedDate],
            ofItemAtPath: freshRollout.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: updatedDate],
            ofItemAtPath: partialMetadataRollout.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-8 * 60 * 60)],
            ofItemAtPath: longRunningRollout.path
        )

        let refreshed = reader.read(
            at: now.addingTimeInterval(taskProgressRefreshInterval + 0.1)
        )
        if !refreshed.items.contains(where: {
            $0.title == "缓存刷新任务" && $0.kind == .completed
        }) {
            integrationFailures.append("cached-mtime-refresh")
        }
        if !refreshed.items.contains(where: {
            $0.title == "恢复后的任务" && $0.kind == .running
        }) {
            integrationFailures.append("partial-metadata-retry")
        }
        if !refreshed.items.contains(where: {
            $0.title == "长时间任务" && $0.kind == .running
        }) {
            integrationFailures.append("tracked-running-retained")
        }
    } catch {
        integrationFailures.append("fixture: \(error.localizedDescription)")
    }

    if let previousCodexHome {
        setenv("CODEX_HOME", previousCodexHome, 1)
    } else {
        unsetenv("CODEX_HOME")
    }
    try? FileManager.default.removeItem(at: fixtureDirectory)

    guard integrationFailures.isEmpty else {
        fputs(
            "task progress integration failed: "
                + integrationFailures.joined(separator: ", ")
                + "\n",
            stderr
        )
        exit(1)
    }

    print("task-progress-self-test: lifecycle=7/7; title=pass; visibility=pass; filtering=pass; integration=7/7; animation=4/4; list=pass; layout=pass; icons=4/4")
    exit(0)
}

private func runAuthenticationFallbackSelfTest() -> Never {
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

private func renderPreviewOnce(to outputPath: String, collapsed: Bool) -> Never {
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

if CommandLine.arguments.contains("--self-test-task-progress") {
    runTaskProgressSelfTest()
}

if CommandLine.arguments.contains("--self-test-authentication-fallback") {
    runAuthenticationFallbackSelfTest()
}

if CommandLine.arguments.contains("--print-panel-config") {
    printPanelConfiguration()
}

if let previewFlag = CommandLine.arguments.firstIndex(of: "--render-preview") {
    guard CommandLine.arguments.indices.contains(previewFlag + 1) else {
        fputs("用法：CodexStatusPanel --render-preview <output.png> [--collapsed]\n", stderr)
        exit(1)
    }
    renderPreviewOnce(
        to: CommandLine.arguments[previewFlag + 1],
        collapsed: CommandLine.arguments.contains("--collapsed")
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
    withExtendedLifetime((singleInstanceLock, delegate)) {
        application.run()
    }
}

runPanelApplication()
