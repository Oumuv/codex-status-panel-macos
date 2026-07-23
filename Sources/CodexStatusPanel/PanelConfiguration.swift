// 面板配置与共享尺寸常量。
// 初次阅读建议先看 PanelConfig.fallback，再看 loadPanelConfig() 的配置覆盖顺序。

import AppKit
import Foundation

let panelVersion = "1.2.1"
let defaultBundleIdentifier = "io.github.mayday-materials.codex-status-panel"
let panelBundleIdentifier = Bundle.main.bundleIdentifier ?? defaultBundleIdentifier
let panelClientName = "codex-status-panel"

private func isFalseEnvironmentValue(_ rawValue: String) -> Bool {
    ["0", "false", "no", "off"].contains(rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
}

private func defaultMarketPricesEnabledFromEnvironment() -> Bool {
    guard let rawValue = ProcessInfo.processInfo.environment["CODEX_STATUS_PANEL_SHOW_MARKET_PRICES"] else {
        return true
    }
    return !isFalseEnvironmentValue(rawValue)
}

/// `Decodable` 让 JSONDecoder 可以直接把 panel-config.json 转成这个结构。
/// `fallback` 是所有外部配置都不可用时仍能启动面板的内置默认值。
struct PanelConfig: Decodable {
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

struct PanelTheme: Decodable {
    var id: String
    var displayName: String
    var title: String
    var backgroundImage: String
}

struct PanelWidgets: Decodable {
    var codexQuota: Bool
    var codexConnection: Bool
    var followStatus: Bool
    var marketPrices: Bool
}

struct PanelTracking: Decodable {
    var mode: String
    var gapPoints: CGFloat
    var mascotTopPaddingPoints: CGFloat
    var fallback: String
}

struct PanelRefresh: Decodable {
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

func ensureEditablePanelConfigFile() -> URL? {
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

/// 按“环境变量指定文件 → 用户文件 → App 内置文件 → 代码默认值”的顺序加载。
/// 某一级解析失败时先记录警告，再继续尝试下一级，而不是让整个 App 启动失败。
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

// 顶层 let 在首次访问时初始化一次，后续各组件共享同一份配置快照。
private let loadedPanelConfig = loadPanelConfig()
let panelConfig = loadedPanelConfig.config
private let panelConfigWarnings = loadedPanelConfig.warnings
let panelConfigFileURL = loadedPanelConfig.sourceURL ?? defaultUserPanelConfigURL()
let editablePanelConfigFileURL: URL = {
    switch loadedPanelConfig.sourceKind {
    case .environment, .user:
        return panelConfigFileURL
    case .bundle, .fallback:
        return defaultUserPanelConfigURL()
    }
}()
let refreshInterval: TimeInterval = max(1, panelConfig.refresh.quotaSeconds)
let btcRefreshInterval: TimeInterval = max(1, panelConfig.refresh.marketSeconds)
let taskProgressRefreshInterval: TimeInterval = 2
private let configuredMarketPricesEnabled: Bool = {
    if let rawValue = ProcessInfo.processInfo.environment[
        "CODEX_STATUS_PANEL_SHOW_MARKET_PRICES"
    ] {
        return !isFalseEnvironmentValue(rawValue)
    }
    return panelConfig.widgets.marketPrices
}()
let marketPricesPreferenceKey = "showsMarketPrices"
func resolvedMarketPricesEnabled(
    storedValue: Bool?,
    configuredDefault: Bool
) -> Bool {
    // `??` 表示左侧可选值为 nil 时才使用右侧默认值。
    storedValue ?? configuredDefault
}
let initialMarketPricesEnabled = resolvedMarketPricesEnabled(
    storedValue: UserDefaults.standard.object(
        forKey: marketPricesPreferenceKey
    ) as? Bool,
    configuredDefault: configuredMarketPricesEnabled
)
// 桌宠动画移动时需要较高频率跟踪，才能让面板与桌宠之间的视觉间距保持稳定。
let followInterval: TimeInterval = max(0.01, panelConfig.refresh.followSeconds)
let panelHorizontalCanvasInset: CGFloat = 7
let panelVerticalCanvasInset: CGFloat = 4
let panelPointerLength: CGFloat = 10
let taskProgressRowHeight: CGFloat = 23
let marketPriceRowHeight: CGFloat = 23
let maximumVisibleTaskRows = 5
private let baseExpandedPanelHeight: CGFloat = 120
func panelSizeForTaskRows(
    _ count: Int,
    showsMarketPrices: Bool
) -> NSSize {
    // 至少保留一行状态，最多展示 maximumVisibleTaskRows 行，避免窗口无限增高。
    let safeCount = max(1, min(maximumVisibleTaskRows, count))
    let marketHeight = showsMarketPrices ? marketPriceRowHeight * 2 : 0
    return NSSize(
        width: 232,
        height: baseExpandedPanelHeight
            + taskProgressRowHeight * CGFloat(safeCount)
            + marketHeight
    )
}
let expandedPanelSize = panelSizeForTaskRows(
    1,
    showsMarketPrices: initialMarketPricesEnabled
)
let collapsedPanelSize = NSSize(width: 72, height: 48)
let panelPetGap: CGFloat = panelConfig.tracking.gapPoints
let panelScreenMargin: CGFloat = 8
let pointerTipBottomInset = panelVerticalCanvasInset
let pointerHorizontalSafeInset = panelHorizontalCanvasInset + 12
// v2 桌宠图片在保存的锚点顶部包含少量透明区域；扣除它后，间距才从可见头顶计算。
let petSpriteTopPaddingInsideAnchor: CGFloat = panelConfig.tracking.mascotTopPaddingPoints

func reportPanelConfigWarnings() {
    for warning in panelConfigWarnings {
        fputs("\(warning)\n", stderr)
    }
}
