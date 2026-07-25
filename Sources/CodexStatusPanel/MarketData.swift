// 行情数据模型、东方财富客户端、交易时段判断和固定快照缓存。

import Foundation

struct StockQuote: Codable, Equatable {
    let secid: String
    let code: String
    let name: String
    let latest: Double
    let change: Double
    let changePercent: Double
    let volume: Double?
    let amount: Double?
    let fetchedAt: Date

    var activitySignature: String {
        let components: [String] = [
            secid,
            String(latest),
            String(change),
            String(changePercent),
            volume.map { String($0) } ?? "-",
            amount.map { String($0) } ?? "-",
        ]
        return components.joined(separator: "|")
    }

    func hasSameMarketValues(as other: StockQuote) -> Bool {
        activitySignature == other.activitySignature
    }
}

struct StockQuotePresentation: Equatable {
    let configuration: StockQuoteConfiguration
    var quote: StockQuote?
    var isCached: Bool
    var isOffline: Bool

    var displayName: String {
        configuration.name ?? quote?.name ?? configuration.secid
    }

    var badge: String {
        configuration.badge ?? (configuration.secid.hasPrefix("1.") ? "沪" : "深")
    }

    var direction: Int {
        guard let percent = quote?.changePercent else { return 0 }
        return percent > 0 ? 1 : (percent < 0 ? -1 : 0)
    }
}

enum StockMarketDisplayState: String, Equatable {
    case unconfigured
    case loading
    case cached
    case verifying
    case trading
    case preOpen
    case lunchClosed
    case closed
    case weekend
    case stale
    case offline

    var text: String {
        switch self {
        case .unconfigured: return "未配置"
        case .loading: return "读取中"
        case .cached: return "上次数据"
        case .verifying: return "核验中"
        case .trading: return "交易中"
        case .preOpen: return "未开盘"
        case .lunchClosed: return "午间休市"
        case .closed: return "已收盘"
        case .weekend: return "休市"
        case .stale: return "未更新"
        case .offline: return "离线"
        }
    }

    var symbolName: String {
        switch self {
        case .unconfigured: return "slider.horizontal.3"
        case .loading: return "arrow.clockwise"
        case .cached: return "clock.fill"
        case .verifying: return "ellipsis.circle"
        case .trading: return "play.circle.fill"
        case .preOpen: return "clock.fill"
        case .lunchClosed, .closed, .weekend:
            return "pause.circle.fill"
        case .stale: return "exclamationmark.triangle.fill"
        case .offline: return "wifi.slash"
        }
    }

    var usesClosedRefreshInterval: Bool {
        switch self {
        case .unconfigured, .preOpen, .lunchClosed, .closed, .weekend, .stale, .offline:
            return true
        case .loading, .cached, .verifying, .trading:
            return false
        }
    }

    var dimsQuotes: Bool {
        self != .trading && self != .verifying && self != .loading
    }
}

enum StockSessionPeriod: Equatable {
    case preOpen
    case morningTrading
    case lunchClosed
    case afternoonTrading
    case closed
    case weekend

    var expectsTrading: Bool {
        self == .morningTrading || self == .afternoonTrading
    }

    var displayState: StockMarketDisplayState {
        switch self {
        case .preOpen: return .preOpen
        case .morningTrading, .afternoonTrading: return .verifying
        case .lunchClosed: return .lunchClosed
        case .closed: return .closed
        case .weekend: return .weekend
        }
    }
}

struct StockActivityTracker {
    private(set) var lastSignature: String?
    private(set) var unchangedCount = 0
    private(set) var unchangedSince: Date?
    private(set) var hasObservedActivity = false

    mutating func reset(signature: String?) {
        lastSignature = signature
        unchangedCount = 0
        unchangedSince = nil
        hasObservedActivity = false
    }

    mutating func observe(
        signature: String,
        at date: Date
    ) -> StockMarketDisplayState {
        if let previous = lastSignature, previous == signature {
            unchangedCount += 1
            if unchangedSince == nil {
                unchangedSince = date
            }
            let duration = date.timeIntervalSince(unchangedSince ?? date)
            if unchangedCount >= 3 && duration >= 90 {
                return .stale
            }
            return hasObservedActivity ? .trading : .verifying
        }

        hasObservedActivity = lastSignature != nil
        lastSignature = signature
        unchangedCount = 0
        unchangedSince = nil
        return hasObservedActivity ? .trading : .verifying
    }
}

func stockMarketCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "zh_CN")
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar
}

func stockSessionPeriod(
    at date: Date,
    calendar: Calendar = stockMarketCalendar()
) -> StockSessionPeriod {
    let weekday = calendar.component(.weekday, from: date)
    if weekday == 1 || weekday == 7 { return .weekend }

    let minute = calendar.component(.hour, from: date) * 60
        + calendar.component(.minute, from: date)
    switch minute {
    case ..<570: return .preOpen
    case 570..<690: return .morningTrading
    case 690..<780: return .lunchClosed
    case 780..<900: return .afternoonTrading
    default: return .closed
    }
}

func nextStockSessionBoundary(
    after date: Date,
    calendar: Calendar = stockMarketCalendar()
) -> Date? {
    let boundaryMinutes = [570, 690, 780, 900]
    for dayOffset in 0...7 {
        guard let day = calendar.date(byAdding: .day, value: dayOffset, to: date) else {
            continue
        }
        let weekday = calendar.component(.weekday, from: day)
        guard weekday != 1 && weekday != 7 else { continue }
        for minute in boundaryMinutes {
            guard let candidate = calendar.date(
                bySettingHour: minute / 60,
                minute: minute % 60,
                second: 0,
                of: day
            ), candidate > date else { continue }
            return candidate
        }
    }
    return nil
}

private struct FlexibleMarketNumber: Decodable {
    let value: Double?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = nil
        } else if let number = try? container.decode(Double.self) {
            value = number.isFinite ? number : nil
        } else if let text = try? container.decode(String.self),
                  text != "-",
                  let number = Double(text),
                  number.isFinite
        {
            value = number
        } else {
            value = nil
        }
    }
}

private struct EastMoneyQuoteResponse: Decodable {
    struct Payload: Decodable {
        let f43: FlexibleMarketNumber
        let f47: FlexibleMarketNumber
        let f48: FlexibleMarketNumber
        let f57: String
        let f58: String
        let f169: FlexibleMarketNumber
        let f170: FlexibleMarketNumber
    }

    let rc: Int
    let data: Payload?
}

enum EastMoneyMarketClientError: LocalizedError, Equatable {
    case invalidSecID(String)
    case invalidURL(String)
    case invalidResponse(String)
    case server(String, Int)
    case api(String, Int)
    case missingData(String)
    case invalidQuote(String)
    case responseTooLarge(String)

    var errorDescription: String? {
        switch self {
        case .invalidSecID(let secid):
            return "\(secid) 行情代码无效"
        case .invalidURL(let secid):
            return "\(secid) 行情地址无法构造"
        case .invalidResponse(let secid):
            return "\(secid) 行情响应无效"
        case .server(let secid, let status):
            return "\(secid) 行情接口返回 HTTP \(status)"
        case .api(let secid, let rc):
            return "\(secid) 行情接口返回 rc=\(rc)"
        case .missingData(let secid):
            return "\(secid) 行情接口没有数据"
        case .invalidQuote(let secid):
            return "\(secid) 行情字段格式异常"
        case .responseTooLarge(let secid):
            return "\(secid) 行情响应超过 64 KiB"
        }
    }
}

final class EastMoneyMarketClient {
    static let maximumResponseBytes = 64 * 1024

    private let loader: HTTPDataLoading

    init(
        loader: HTTPDataLoading = BoundedURLSessionDataLoader(
            maximumResponseBytes: EastMoneyMarketClient.maximumResponseBytes,
            allowedRedirectHosts: [
                "push2.eastmoney.com",
                "push2delay.eastmoney.com",
            ],
            maximumRedirects: 2
        )
    ) {
        self.loader = loader
    }

    @discardableResult
    func fetch(
        secid: String,
        completion: @escaping (Result<StockQuote, Error>) -> Void
    ) -> HTTPDataTasking? {
        let request: URLRequest
        do {
            request = try Self.request(secid: secid)
        } catch {
            completion(.failure(error))
            return nil
        }

        return loader.loadData(with: request) { data, response, error in
            if let error {
                let mapped: Error = error is HTTPDataLoaderError
                    ? EastMoneyMarketClientError.responseTooLarge(secid)
                    : error
                completion(.failure(mapped))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(
                    EastMoneyMarketClientError.invalidResponse(secid)
                ))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                completion(.failure(
                    EastMoneyMarketClientError.server(secid, http.statusCode)
                ))
                return
            }
            guard let data else {
                completion(.failure(
                    EastMoneyMarketClientError.invalidResponse(secid)
                ))
                return
            }
            completion(Self.decodeQuote(data: data, secid: secid))
        }
    }

    static func request(secid: String) throws -> URLRequest {
        guard isValidStockSecID(secid) else {
            throw EastMoneyMarketClientError.invalidSecID(secid)
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "push2.eastmoney.com"
        components.path = "/api/qt/stock/get"
        components.queryItems = [
            URLQueryItem(name: "secid", value: secid),
            URLQueryItem(name: "fltt", value: "2"),
            URLQueryItem(name: "invt", value: "2"),
            URLQueryItem(
                name: "fields",
                value: "f43,f47,f48,f57,f58,f169,f170"
            ),
        ]
        guard let url = components.url else {
            throw EastMoneyMarketClientError.invalidURL(secid)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(
            "application/json,text/plain,*/*",
            forHTTPHeaderField: "Accept"
        )
        return request
    }

    static func decodeQuote(
        data: Data,
        secid: String,
        fetchedAt: Date = Date()
    ) -> Result<StockQuote, Error> {
        guard data.count <= maximumResponseBytes else {
            return .failure(
                EastMoneyMarketClientError.responseTooLarge(secid)
            )
        }
        let response: EastMoneyQuoteResponse
        do {
            response = try JSONDecoder().decode(
                EastMoneyQuoteResponse.self,
                from: data
            )
        } catch {
            return .failure(EastMoneyMarketClientError.invalidResponse(secid))
        }
        guard response.rc == 0 else {
            return .failure(
                EastMoneyMarketClientError.api(secid, response.rc)
            )
        }
        guard let payload = response.data else {
            return .failure(EastMoneyMarketClientError.missingData(secid))
        }
        guard let latest = payload.f43.value,
              latest > 0,
              let change = payload.f169.value,
              let changePercent = payload.f170.value,
              !payload.f57.isEmpty,
              !payload.f58.isEmpty
        else {
            return .failure(EastMoneyMarketClientError.invalidQuote(secid))
        }
        return .success(StockQuote(
            secid: secid,
            code: payload.f57,
            name: String(payload.f58.prefix(32)),
            latest: latest,
            change: change,
            changePercent: changePercent,
            volume: payload.f47.value,
            amount: payload.f48.value,
            fetchedAt: fetchedAt
        ))
    }
}

struct StockQuoteCacheSnapshot: Equatable {
    let savedAt: Date
    let quotes: [StockQuote]
}

final class StockQuoteCache {
    static let maximumBytes = 64 * 1024

    private struct Payload: Codable {
        let version: Int
        let savedAt: Date
        let quotes: [StockQuote]
    }

    private let fileURL: URL
    private let fileManager: FileManager

    init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Caches/\(defaultBundleIdentifier)/stock-quotes.json"
            )
    }

    func load(allowedSecIDs: Set<String>) -> StockQuoteCacheSnapshot? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let values = try fileURL.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]
            )
            guard values.isRegularFile == true,
                  let size = values.fileSize,
                  size <= Self.maximumBytes
            else {
                fputs("stock-cache: 文件超过 64 KiB 或不是普通文件，已忽略\n", stderr)
                return nil
            }
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            let data = try handle.read(
                upToCount: Self.maximumBytes + 1
            ) ?? Data()
            guard data.count <= Self.maximumBytes else {
                fputs("stock-cache: 文件超过 64 KiB，已忽略\n", stderr)
                return nil
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let payload = try decoder.decode(Payload.self, from: data)
            guard payload.version == 1, payload.quotes.count <= maximumVisibleStockRows else {
                fputs("stock-cache: 快照版本或条目数量无效，已忽略\n", stderr)
                return nil
            }
            let quotes = payload.quotes.filter {
                allowedSecIDs.contains($0.secid)
            }
            if quotes.count != payload.quotes.count {
                fputs("stock-cache: 包含当前配置之外的条目，已忽略\n", stderr)
            }
            return StockQuoteCacheSnapshot(
                savedAt: payload.savedAt,
                quotes: quotes
            )
        } catch {
            fputs("stock-cache: 无法读取，已忽略：\(error.localizedDescription)\n", stderr)
            return nil
        }
    }

    func save(quotes: [StockQuote], savedAt: Date = Date()) throws {
        guard quotes.count <= maximumVisibleStockRows else {
            throw PanelConfigurationValidationError(
                path: "stock-cache.quotes",
                reason: "最多保存 \(maximumVisibleStockRows) 项"
            )
        }
        let payload = Payload(version: 1, savedAt: savedAt, quotes: quotes)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        guard data.count <= Self.maximumBytes else {
            throw EastMoneyMarketClientError.responseTooLarge("stock-cache")
        }
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }
}
