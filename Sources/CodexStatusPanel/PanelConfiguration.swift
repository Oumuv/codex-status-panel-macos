// 面板配置与共享尺寸常量。
// 初次阅读建议先看 PanelConfig.fallback，再看 loadPanelConfig() 的配置覆盖顺序。

import AppKit
import Foundation

let panelVersion = "1.2.2"
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
    var usageProvider: UsageProviderConfiguration?
    var theme: PanelTheme
    var widgets: PanelWidgets
    var tracking: PanelTracking
    var refresh: PanelRefresh

    private enum CodingKeys: String, CodingKey {
        case version, usageProvider, theme, widgets, tracking, refresh
    }

    init(
        version: Int,
        usageProvider: UsageProviderConfiguration?,
        theme: PanelTheme,
        widgets: PanelWidgets,
        tracking: PanelTracking,
        refresh: PanelRefresh
    ) {
        self.version = version
        self.usageProvider = usageProvider
        self.theme = theme
        self.widgets = widgets
        self.tracking = tracking
        self.refresh = refresh
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        theme = try container.decode(PanelTheme.self, forKey: .theme)
        widgets = try container.decode(PanelWidgets.self, forKey: .widgets)
        tracking = try container.decode(PanelTracking.self, forKey: .tracking)
        refresh = try container.decode(PanelRefresh.self, forKey: .refresh)

        let providerIsMissing = !container.contains(.usageProvider)
        let providerIsNull = providerIsMissing
            ? false : try container.decodeNil(forKey: .usageProvider)
        if providerIsMissing || providerIsNull {
            usageProvider = nil
        } else {
            do {
                usageProvider = try container.decode(
                    UsageProviderConfiguration.self,
                    forKey: .usageProvider
                )
            } catch {
                // Provider 的类型错误必须保留为显式失败，不能让整个配置源
                // 解码失败后继续回退到内置 Codex 账户。
                usageProvider = .invalidFormat
            }
        }
    }

    static let fallback = PanelConfig(
        version: 1,
        usageProvider: nil,
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

struct UsageProviderConfiguration: Decodable, Equatable {
    let baseUrl: String
    let apiKey: String
    let modelProvider: String
    let validationError: UsageProviderConfigurationError?

    init(
        baseUrl: String = "",
        apiKey: String = "",
        modelProvider: String = "sub2api",
        validationError: UsageProviderConfigurationError? = nil
    ) {
        self.baseUrl = baseUrl
        self.apiKey = apiKey
        self.modelProvider = modelProvider
        self.validationError = validationError
    }

    static let invalidFormat = UsageProviderConfiguration(
        validationError: .invalidFormat
    )

    private enum CodingKeys: String, CodingKey {
        case baseUrl
        case apiKey
        case modelProvider
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var hasInvalidField = false

        func decodeString(
            _ key: CodingKeys,
            default defaultValue: String
        ) -> String {
            do {
                return try container.decodeIfPresent(
                    String.self,
                    forKey: key
                ) ?? defaultValue
            } catch {
                hasInvalidField = true
                return defaultValue
            }
        }

        baseUrl = decodeString(.baseUrl, default: "")
        apiKey = decodeString(.apiKey, default: "")
        modelProvider = decodeString(
            .modelProvider,
            default: "sub2api"
        )
        validationError = hasInvalidField ? .invalidFormat : nil
    }
}

enum ResolvedUsageProviderConfiguration: Equatable {
    case codex
    case sub2api(baseURL: URL, apiKey: String)
}

enum UsageProviderConfigurationError: LocalizedError, Equatable {
    case missingBaseURL
    case missingAPIKey
    case invalidBaseURL
    case invalidAPIKey
    case invalidFormat
    case unsupportedModelProvider

    var errorDescription: String? {
        switch self {
        case .missingBaseURL:
            return "第三方用量配置缺少 baseUrl"
        case .missingAPIKey:
            return "第三方用量配置缺少 apiKey"
        case .invalidBaseURL:
            return "第三方用量配置的 baseUrl 无效"
        case .invalidAPIKey:
            return "第三方用量配置的 apiKey 无效"
        case .invalidFormat:
            return "第三方用量配置格式无效"
        case .unsupportedModelProvider:
            return "第三方用量目前只支持 sub2api"
        }
    }
}

struct UsageProviderDiagnosticSummary: Equatable {
    let provider: String
    let isConfigured: Bool
}

func resolveUsageProviderConfiguration(
    _ configuration: UsageProviderConfiguration?
) -> Result<ResolvedUsageProviderConfiguration, UsageProviderConfigurationError> {
    guard let configuration else { return .success(.codex) }
    if let validationError = configuration.validationError {
        return .failure(validationError)
    }

    let baseURLText = configuration.baseUrl.trimmingCharacters(
        in: .whitespacesAndNewlines
    )
    let apiKey = configuration.apiKey.trimmingCharacters(
        in: .whitespacesAndNewlines
    )
    let rawProvider = configuration.modelProvider.trimmingCharacters(
        in: .whitespacesAndNewlines
    )
    let provider = rawProvider.isEmpty
        ? "sub2api"
        : rawProvider.lowercased()

    if baseURLText.isEmpty && apiKey.isEmpty {
        return .success(.codex)
    }
    guard !baseURLText.isEmpty else { return .failure(.missingBaseURL) }
    guard !apiKey.isEmpty else { return .failure(.missingAPIKey) }
    guard apiKey.utf8.count <= 128,
          !apiKey.unicodeScalars.contains(where: {
              CharacterSet.controlCharacters.contains($0)
          })
    else {
        return .failure(.invalidAPIKey)
    }
    guard provider == "sub2api" else {
        return .failure(.unsupportedModelProvider)
    }

    guard var components = URLComponents(string: baseURLText),
          let scheme = components.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          components.host?.isEmpty == false,
          components.user == nil,
          components.password == nil,
          components.query == nil,
          components.fragment == nil
    else {
        return .failure(.invalidBaseURL)
    }
    components.scheme = scheme
    guard let baseURL = components.url else {
        return .failure(.invalidBaseURL)
    }
    return .success(.sub2api(baseURL: baseURL, apiKey: apiKey))
}

func usageProviderDiagnosticSummary(
    _ configuration: UsageProviderConfiguration?
) -> UsageProviderDiagnosticSummary {
    switch resolveUsageProviderConfiguration(configuration) {
    case .success(.codex):
        return UsageProviderDiagnosticSummary(
            provider: "codex",
            isConfigured: false
        )
    case .success(.sub2api):
        return UsageProviderDiagnosticSummary(
            provider: "sub2api",
            isConfigured: true
        )
    case .failure:
        return UsageProviderDiagnosticSummary(
            provider: "invalid",
            isConfigured: true
        )
    }
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
