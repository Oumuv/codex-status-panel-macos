// 面板配置与共享尺寸常量。
// 初次阅读建议先看 PanelConfig.fallback，再看 loadPanelConfig() 的配置覆盖顺序。

import AppKit
import Foundation

let panelVersion: String = {
    guard let version = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleShortVersionString"
    ) as? String,
        !version.isEmpty
    else {
        fatalError("应用 Info.plist 缺少 CFBundleShortVersionString")
    }
    return version
}()
let defaultBundleIdentifier = "io.github.mayday-materials.codex-status-panel"
let panelBundleIdentifier = Bundle.main.bundleIdentifier ?? defaultBundleIdentifier
let panelClientName = "codex-status-panel"

private func isFalseEnvironmentValue(_ rawValue: String) -> Bool {
    ["0", "false", "no", "off"].contains(rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
}

private func defaultCryptoPricesEnabledFromEnvironment() -> Bool {
    guard let rawValue = ProcessInfo.processInfo.environment["CODEX_STATUS_PANEL_SHOW_MARKET_PRICES"] else {
        return false
    }
    return !isFalseEnvironmentValue(rawValue)
}

private func defaultStockPricesEnabledFromEnvironment() -> Bool {
    guard let rawValue = ProcessInfo.processInfo.environment[
        "CODEX_STATUS_PANEL_SHOW_STOCK_PRICES"
    ] else {
        return false
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
    var markets: PanelMarkets
    var tracking: PanelTracking
    var refresh: PanelRefresh

    private enum CodingKeys: String, CodingKey {
        case version, usageProvider, theme, widgets, markets, tracking, refresh
    }

    init(
        version: Int,
        usageProvider: UsageProviderConfiguration?,
        theme: PanelTheme,
        widgets: PanelWidgets,
        markets: PanelMarkets,
        tracking: PanelTracking,
        refresh: PanelRefresh
    ) {
        self.version = version
        self.usageProvider = usageProvider
        self.theme = theme
        self.widgets = widgets
        self.markets = markets
        self.tracking = tracking
        self.refresh = refresh
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        theme = try container.decode(PanelTheme.self, forKey: .theme)
        widgets = try container.decode(PanelWidgets.self, forKey: .widgets)
        markets = try container.decodeIfPresent(
            PanelMarkets.self,
            forKey: .markets
        ) ?? .defaults
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
            cryptoPrices: defaultCryptoPricesEnabledFromEnvironment(),
            stockPrices: defaultStockPricesEnabledFromEnvironment()
        ),
        markets: .defaults,
        tracking: PanelTracking(
            mode: "follow-current-codex-desktop",
            gapPoints: 14,
            mascotTopPaddingPoints: 7,
            fallback: "top-right"
        ),
        refresh: PanelRefresh(
            quotaSeconds: 300,
            cryptoSeconds: 5,
            stockSeconds: 30,
            stockClosedSeconds: 300,
            stockCacheWriteSeconds: 300,
            followSeconds: 0.05
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
    var cryptoPrices: Bool
    var stockPrices: Bool

    private enum CodingKeys: String, CodingKey {
        case codexQuota
        case codexConnection
        case followStatus
        case cryptoPrices
        case marketPrices
        case stockPrices
    }

    init(
        codexQuota: Bool,
        codexConnection: Bool,
        followStatus: Bool,
        cryptoPrices: Bool,
        stockPrices: Bool
    ) {
        self.codexQuota = codexQuota
        self.codexConnection = codexConnection
        self.followStatus = followStatus
        self.cryptoPrices = cryptoPrices
        self.stockPrices = stockPrices
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        codexQuota = try container.decode(Bool.self, forKey: .codexQuota)
        codexConnection = try container.decode(Bool.self, forKey: .codexConnection)
        followStatus = try container.decode(Bool.self, forKey: .followStatus)
        cryptoPrices = try container.decodeIfPresent(
            Bool.self,
            forKey: .cryptoPrices
        ) ?? container.decodeIfPresent(
            Bool.self,
            forKey: .marketPrices
        ) ?? false
        stockPrices = try container.decodeIfPresent(
            Bool.self,
            forKey: .stockPrices
        ) ?? false
    }
}

struct PanelConfigurationValidationError: LocalizedError, Equatable {
    let path: String
    let reason: String

    var errorDescription: String? {
        "panel-config: \(path) \(reason)"
    }
}

func isValidStockSecID(_ value: String) -> Bool {
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2,
          parts[0] == "0" || parts[0] == "1",
          parts[1].utf8.count == 6,
          parts[1].utf8.allSatisfy({ $0 >= 48 && $0 <= 57 })
    else { return false }
    return true
}

struct StockQuoteConfiguration: Decodable, Equatable {
    let secid: String
    let name: String?
    let badge: String?
    let enabled: Bool

    private enum CodingKeys: String, CodingKey {
        case secid, name, badge, enabled
    }

    init(
        secid: String,
        name: String?,
        badge: String?,
        enabled: Bool
    ) {
        self.secid = secid
        self.name = name
        self.badge = badge
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let index = decoder.codingPath.last?.intValue ?? 0
        let path = "markets.stockQuotes[\(index)]"
        let rawSecID = try container.decode(String.self, forKey: .secid)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidStockSecID(rawSecID) else {
            throw PanelConfigurationValidationError(
                path: "\(path).secid",
                reason: "必须是 0|1.六位代码"
            )
        }

        let rawName = try container.decodeIfPresent(String.self, forKey: .name)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let rawName, rawName.count > 32 {
            throw PanelConfigurationValidationError(
                path: "\(path).name",
                reason: "最多 32 个字符"
            )
        }

        let rawBadge = try container.decodeIfPresent(String.self, forKey: .badge)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let rawBadge, rawBadge.count > 2 {
            throw PanelConfigurationValidationError(
                path: "\(path).badge",
                reason: "最多 2 个字符"
            )
        }

        secid = rawSecID
        name = rawName?.isEmpty == false ? rawName : nil
        badge = rawBadge?.isEmpty == false ? rawBadge : nil
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
            ?? true
    }
}

struct PanelMarkets: Decodable, Equatable {
    var stockQuotes: [StockQuoteConfiguration]

    private enum CodingKeys: String, CodingKey {
        case stockQuotes
    }

    init(stockQuotes: [StockQuoteConfiguration]) {
        self.stockQuotes = stockQuotes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let quotes = try container.decodeIfPresent(
            [StockQuoteConfiguration].self,
            forKey: .stockQuotes
        ) ?? Self.defaults.stockQuotes
        var seen = Set<String>()
        for (index, quote) in quotes.enumerated() {
            guard seen.insert(quote.secid).inserted else {
                throw PanelConfigurationValidationError(
                    path: "markets.stockQuotes[\(index)].secid",
                    reason: "与前面的配置重复"
                )
            }
        }
        guard quotes.filter(\.enabled).count <= maximumVisibleStockRows else {
            throw PanelConfigurationValidationError(
                path: "markets.stockQuotes",
                reason: "最多启用 \(maximumVisibleStockRows) 项"
            )
        }
        stockQuotes = quotes
    }

    static let defaults = PanelMarkets(stockQuotes: [
        StockQuoteConfiguration(
            secid: "1.000001",
            name: "上证指数",
            badge: "沪",
            enabled: true
        ),
        StockQuoteConfiguration(
            secid: "0.399001",
            name: "深证成指",
            badge: "深",
            enabled: true
        ),
        StockQuoteConfiguration(
            secid: "0.399006",
            name: "创业板指",
            badge: "创",
            enabled: true
        ),
        StockQuoteConfiguration(
            secid: "1.000300",
            name: "沪深300",
            badge: "沪",
            enabled: true
        ),
    ])
}

struct PanelTracking: Decodable {
    var mode: String
    var gapPoints: CGFloat
    var mascotTopPaddingPoints: CGFloat
    var fallback: String
}

struct PanelRefresh: Decodable {
    var quotaSeconds: TimeInterval
    var cryptoSeconds: TimeInterval
    var stockSeconds: TimeInterval
    var stockClosedSeconds: TimeInterval
    var stockCacheWriteSeconds: TimeInterval
    var followSeconds: TimeInterval

    private enum CodingKeys: String, CodingKey {
        case quotaSeconds
        case cryptoSeconds
        case marketSeconds
        case stockSeconds
        case stockClosedSeconds
        case stockCacheWriteSeconds
        case followSeconds
    }

    init(
        quotaSeconds: TimeInterval,
        cryptoSeconds: TimeInterval,
        stockSeconds: TimeInterval,
        stockClosedSeconds: TimeInterval,
        stockCacheWriteSeconds: TimeInterval,
        followSeconds: TimeInterval
    ) {
        self.quotaSeconds = quotaSeconds
        self.cryptoSeconds = cryptoSeconds
        self.stockSeconds = stockSeconds
        self.stockClosedSeconds = stockClosedSeconds
        self.stockCacheWriteSeconds = stockCacheWriteSeconds
        self.followSeconds = followSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        quotaSeconds = try container.decode(
            TimeInterval.self,
            forKey: .quotaSeconds
        )
        followSeconds = try container.decode(
            TimeInterval.self,
            forKey: .followSeconds
        )
        cryptoSeconds = try Self.configuredInterval(
            container,
            key: .cryptoSeconds,
            legacyKey: .marketSeconds,
            default: 5,
            path: "refresh.cryptoSeconds",
            minimum: 5
        )
        stockSeconds = try Self.configuredInterval(
            container,
            key: .stockSeconds,
            default: 30,
            path: "refresh.stockSeconds",
            minimum: 15
        )
        stockClosedSeconds = try Self.configuredInterval(
            container,
            key: .stockClosedSeconds,
            default: 300,
            path: "refresh.stockClosedSeconds",
            minimum: 60
        )
        stockCacheWriteSeconds = try Self.configuredInterval(
            container,
            key: .stockCacheWriteSeconds,
            default: 300,
            path: "refresh.stockCacheWriteSeconds",
            minimum: 60
        )
    }

    private static func configuredInterval(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys,
        legacyKey: CodingKeys? = nil,
        default defaultValue: TimeInterval,
        path: String,
        minimum: TimeInterval
    ) throws -> TimeInterval {
        let value: TimeInterval
        do {
            if let configured = try container.decodeIfPresent(
                TimeInterval.self,
                forKey: key
            ) {
                value = configured
            } else if let legacyKey,
                      let legacy = try container.decodeIfPresent(
                        TimeInterval.self,
                        forKey: legacyKey
                      )
            {
                value = legacy
            } else {
                value = defaultValue
            }
        } catch {
            throw intervalError(path: path, minimum: minimum)
        }
        return try interval(value, path: path, minimum: minimum)
    }

    private static func interval(
        _ value: TimeInterval,
        path: String,
        minimum: TimeInterval
    ) throws -> TimeInterval {
        guard value.isFinite, value >= minimum, value <= 86_400 else {
            throw intervalError(path: path, minimum: minimum)
        }
        return value
    }

    private static func intervalError(
        path: String,
        minimum: TimeInterval
    ) -> PanelConfigurationValidationError {
        PanelConfigurationValidationError(
            path: path,
            reason: "必须在 \(Int(minimum))...86400 秒之间"
        )
    }
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
    var warnings: [String] = []

    func decodeConfig(from url: URL, source: String) -> PanelConfig? {
        do {
            return try decodePanelConfig(at: url)
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

func decodePanelConfig(from data: Data) throws -> PanelConfig {
    try JSONDecoder().decode(PanelConfig.self, from: data)
}

func decodePanelConfig(at url: URL) throws -> PanelConfig {
    try decodePanelConfig(from: Data(contentsOf: url))
}

// 启动时先加载一次；菜单热加载成功后再原子替换这份运行时配置。
private let loadedPanelConfig = loadPanelConfig()
private(set) var panelConfig = loadedPanelConfig.config
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

@discardableResult
func reloadPanelConfig() throws -> PanelConfig {
    let configURL = ensureEditablePanelConfigFile()
        ?? editablePanelConfigFileURL
    let reloadedConfig = try decodePanelConfig(at: configURL)
    panelConfig = reloadedConfig
    return reloadedConfig
}

var refreshInterval: TimeInterval {
    max(1, panelConfig.refresh.quotaSeconds)
}
var cryptoRefreshInterval: TimeInterval {
    panelConfig.refresh.cryptoSeconds
}
var stockRefreshInterval: TimeInterval {
    panelConfig.refresh.stockSeconds
}
var stockClosedRefreshInterval: TimeInterval {
    panelConfig.refresh.stockClosedSeconds
}
var stockCacheWriteInterval: TimeInterval {
    panelConfig.refresh.stockCacheWriteSeconds
}
let taskProgressRefreshInterval: TimeInterval = 2
func configuredMarketPricesEnabled(for config: PanelConfig) -> Bool {
    if let rawValue = ProcessInfo.processInfo.environment[
        "CODEX_STATUS_PANEL_SHOW_MARKET_PRICES"
    ] {
        return !isFalseEnvironmentValue(rawValue)
    }
    return config.widgets.cryptoPrices
}
let marketPricesPreferenceKey = "showsMarketPrices"
let standalonePanelOriginPreferenceKey = "standalonePanelOrigin"
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
    configuredDefault: configuredMarketPricesEnabled(for: panelConfig)
)
func configuredStockPricesEnabled(for config: PanelConfig) -> Bool {
    if let rawValue = ProcessInfo.processInfo.environment[
        "CODEX_STATUS_PANEL_SHOW_STOCK_PRICES"
    ] {
        return !isFalseEnvironmentValue(rawValue)
    }
    return config.widgets.stockPrices
}
let stockPricesPreferenceKey = "showsStockPrices"
let initialStockPricesEnabled = resolvedMarketPricesEnabled(
    storedValue: UserDefaults.standard.object(
        forKey: stockPricesPreferenceKey
    ) as? Bool,
    configuredDefault: configuredStockPricesEnabled(for: panelConfig)
)
var enabledStockQuoteConfigurations: [StockQuoteConfiguration] {
    panelConfig.markets.stockQuotes.filter(\.enabled)
}
// 20 Hz 足以保持跟随平滑，同时避免高频窗口查询持续占用主线程。
var followInterval: TimeInterval {
    max(0.05, panelConfig.refresh.followSeconds)
}
let panelHorizontalCanvasInset: CGFloat = 7
let panelVerticalCanvasInset: CGFloat = 4
let panelPointerLength: CGFloat = 10
let taskProgressRowHeight: CGFloat = 23
let marketPriceRowHeight: CGFloat = 23
let stockMarketHeaderHeight: CGFloat = 20
let maximumVisibleTaskRows = 5
let maximumVisibleStockRows = 5
private let baseExpandedPanelHeight: CGFloat = 120
func panelSizeForTaskRows(
    _ count: Int,
    showsMarketPrices: Bool,
    showsStockPrices: Bool = false,
    stockRowCount: Int = 0
) -> NSSize {
    // 至少保留一行状态，最多展示 maximumVisibleTaskRows 行，避免窗口无限增高。
    let safeCount = max(1, min(maximumVisibleTaskRows, count))
    let marketHeight = showsMarketPrices ? marketPriceRowHeight * 2 : 0
    let safeStockCount = max(
        1,
        min(maximumVisibleStockRows, stockRowCount)
    )
    let stockHeight = showsStockPrices
        ? stockMarketHeaderHeight
            + marketPriceRowHeight * CGFloat(safeStockCount)
        : 0
    return NSSize(
        width: 232,
        height: baseExpandedPanelHeight
            + taskProgressRowHeight * CGFloat(safeCount)
            + marketHeight
            + stockHeight
    )
}
let expandedPanelSize = panelSizeForTaskRows(
    1,
    showsMarketPrices: initialMarketPricesEnabled,
    showsStockPrices: initialStockPricesEnabled,
    stockRowCount: enabledStockQuoteConfigurations.count
)
let collapsedPanelSize = NSSize(width: 72, height: 48)
var panelPetGap: CGFloat {
    panelConfig.tracking.gapPoints
}
let panelScreenMargin: CGFloat = 8
let pointerTipBottomInset = panelVerticalCanvasInset
let pointerHorizontalSafeInset = panelHorizontalCanvasInset + 12
// v2 桌宠图片在保存的锚点顶部包含少量透明区域；扣除它后，间距才从可见头顶计算。
var petSpriteTopPaddingInsideAnchor: CGFloat {
    panelConfig.tracking.mascotTopPaddingPoints
}

func reportPanelConfigWarnings() {
    for warning in panelConfigWarnings {
        fputs("\(warning)\n", stderr)
    }
}
