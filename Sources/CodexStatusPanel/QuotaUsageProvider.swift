// 统一额度 Provider 契约，以及各平台响应到 UI 展示模型的映射。
// AppDelegate 和视图只依赖 QuotaPresentation，不解析具体平台回参。

import Foundation

struct QuotaRateLimitOption: Equatable {
    let id: String
    let displayName: String
    let valueText: String
    let progressPercent: Int
    let isDepleted: Bool

    var compactDisplayName: String {
        displayName.replacingOccurrences(of: " ", with: "")
    }
}

struct QuotaPresentation: Equatable {
    let sourceName: String
    let valueText: String
    let progressPercent: Int?
    let detailText: String
    let dailyTokenText: String?
    let showsInlineUsageMetrics: Bool
    let rateLimitOptions: [QuotaRateLimitOption]
    let selectedRateLimitID: String?
    let isDepleted: Bool

    init(
        sourceName: String,
        valueText: String,
        progressPercent: Int?,
        detailText: String,
        dailyTokenText: String? = nil,
        showsInlineUsageMetrics: Bool = false,
        rateLimitOptions: [QuotaRateLimitOption] = [],
        selectedRateLimitID: String? = nil,
        isDepleted: Bool
    ) {
        self.sourceName = sourceName
        self.valueText = valueText
        self.progressPercent = progressPercent
        self.detailText = detailText
        self.dailyTokenText = dailyTokenText
        self.showsInlineUsageMetrics = showsInlineUsageMetrics
        self.rateLimitOptions = rateLimitOptions
        self.selectedRateLimitID = selectedRateLimitID
        self.isDepleted = isDepleted
    }

    var selectedRateLimitOption: QuotaRateLimitOption? {
        guard let selectedRateLimitID else { return nil }
        return rateLimitOptions.first {
            $0.id == selectedRateLimitID
        }
    }

    var hasSwitchableRateLimits: Bool {
        rateLimitOptions.count > 1
    }

    func selectingRateLimit(id: String) -> QuotaPresentation {
        guard let option = rateLimitOptions.first(where: { $0.id == id }) else {
            return self
        }
        return QuotaPresentation(
            sourceName: sourceName,
            valueText: option.valueText,
            progressPercent: option.progressPercent,
            detailText: detailText,
            dailyTokenText: dailyTokenText,
            showsInlineUsageMetrics: showsInlineUsageMetrics,
            rateLimitOptions: rateLimitOptions,
            selectedRateLimitID: option.id,
            isDepleted: option.isDepleted
        )
    }

    func cyclingRateLimit() -> QuotaPresentation {
        guard hasSwitchableRateLimits else { return self }
        let currentIndex = rateLimitOptions.firstIndex {
            $0.id == selectedRateLimitID
        } ?? -1
        let nextIndex = (currentIndex + 1) % rateLimitOptions.count
        return selectingRateLimit(id: rateLimitOptions[nextIndex].id)
    }
}

enum QuotaDisplayTone: Equatable {
    case normal
    case warning
    case danger
}

func quotaDisplayTone(remainingPercent: Int) -> QuotaDisplayTone {
    if remainingPercent <= 20 { return .danger }
    if remainingPercent <= 45 { return .warning }
    return .normal
}

func quotaDisplayTone(
    for presentation: QuotaPresentation
) -> QuotaDisplayTone {
    if let percent = presentation.progressPercent {
        return quotaDisplayTone(remainingPercent: percent)
    }
    return presentation.isDepleted ? .danger : .normal
}

func quotaPresentationAfterRefresh(
    previous: QuotaPresentation?,
    result: Result<QuotaPresentation, Error>
) -> QuotaPresentation? {
    switch result {
    case .success(let presentation):
        if let selectedRateLimitID = previous?.selectedRateLimitID {
            return presentation.selectingRateLimit(id: selectedRateLimitID)
        }
        return presentation
    case .failure:
        return previous
    }
}

protocol QuotaUsageFetching: AnyObject {
    var sourceDisplayName: String { get }

    func fetch(
        completion: @escaping (Result<QuotaPresentation, Error>) -> Void
    )
}

enum QuotaPresentationError: LocalizedError, Equatable {
    case noDisplayableUsage

    var errorDescription: String? {
        "额度接口没有返回可展示的数据"
    }
}

func codexQuotaPresentation(
    from response: RateLimitsResult
) throws -> QuotaPresentation {
    let snapshot = codexSnapshot(from: response)
    if let primary = snapshot.primary {
        let remaining = max(0, min(100, 100 - primary.usedPercent))
        return QuotaPresentation(
            sourceName: "Codex",
            valueText: "剩余 \(remaining)%",
            progressPercent: remaining,
            detailText: "已用 \(100 - remaining)%",
            isDepleted: remaining <= 0
        )
    }
    if let individual = snapshot.individualLimit {
        let remaining = max(
            0,
            min(100, individual.remainingPercent)
        )
        return QuotaPresentation(
            sourceName: "Codex",
            valueText: "剩余 \(remaining)%",
            progressPercent: remaining,
            detailText: "已用 \(100 - remaining)%",
            isDepleted: remaining <= 0
        )
    }
    throw QuotaPresentationError.noDisplayableUsage
}

final class CodexQuotaUsageProvider: QuotaUsageFetching {
    let sourceDisplayName = "Codex"
    private let client: CodexQuotaClient

    init(client: CodexQuotaClient = CodexQuotaClient()) {
        self.client = client
    }

    func fetch(
        completion: @escaping (Result<QuotaPresentation, Error>) -> Void
    ) {
        client.fetch { result in
            switch result {
            case .success(let response):
                do {
                    completion(.success(
                        try codexQuotaPresentation(from: response)
                    ))
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
}

protocol HTTPDataTasking: AnyObject {
    func cancel()
}

extension URLSessionTask: HTTPDataTasking {}

protocol HTTPDataLoading: AnyObject {
    @discardableResult
    func loadData(
        with request: URLRequest,
        completion: @escaping (Data?, URLResponse?, Error?) -> Void
    ) -> HTTPDataTasking
}

struct BoundedHTTPResponseBuffer {
    let maximumBytes: Int
    private(set) var data = Data()

    init(maximumBytes: Int) {
        self.maximumBytes = max(0, maximumBytes)
    }

    mutating func append(_ chunk: Data) -> Bool {
        guard chunk.count <= maximumBytes - data.count else {
            return false
        }
        data.append(chunk)
        return true
    }
}

enum HTTPDataLoaderError: Error {
    case responseTooLarge
}

func permittedHTTPRedirectRequest(
    from sourceURL: URL?,
    to proposedRequest: URLRequest,
    allowedHosts: Set<String>
) -> URLRequest? {
    guard let sourceHost = sourceURL?.host?.lowercased(),
          let targetURL = proposedRequest.url,
          targetURL.scheme?.lowercased() == "https",
          targetURL.port == nil || targetURL.port == 443,
          let targetHost = targetURL.host?.lowercased(),
          allowedHosts.contains(sourceHost),
          allowedHosts.contains(targetHost),
          targetURL.user == nil,
          targetURL.password == nil,
          proposedRequest.httpMethod == nil || proposedRequest.httpMethod == "GET"
    else { return nil }

    var sanitized = proposedRequest
    sanitized.setValue(nil, forHTTPHeaderField: "Authorization")
    sanitized.setValue(nil, forHTTPHeaderField: "Cookie")
    return sanitized
}

/// 使用 data delegate 流式收集响应；超过上限时立即取消，不让产品代码
/// 在 completion 前持有无界响应体。重定向一律拒绝，避免 Bearer Key 离开
/// 用户配置且已校验的 origin。
final class BoundedURLSessionDataLoader: NSObject,
    HTTPDataLoading,
    URLSessionDataDelegate,
    URLSessionTaskDelegate
{
    static let shared = BoundedURLSessionDataLoader(
        maximumResponseBytes: Sub2APIUsageClient.maximumResponseBytes
    )

    private final class RequestState {
        var buffer: BoundedHTTPResponseBuffer
        var response: URLResponse?
        var redirectCount = 0
        let completion: (Data?, URLResponse?, Error?) -> Void

        init(
            maximumResponseBytes: Int,
            completion: @escaping (Data?, URLResponse?, Error?) -> Void
        ) {
            buffer = BoundedHTTPResponseBuffer(
                maximumBytes: maximumResponseBytes
            )
            self.completion = completion
        }
    }

    private let maximumResponseBytes: Int
    private let allowedRedirectHosts: Set<String>
    private let maximumRedirects: Int
    private let stateLock = NSLock()
    private var requestStates: [Int: RequestState] = [:]
    private let delegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "CodexStatusPanel.Sub2API.HTTP"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: delegateQueue
        )
    }()

    init(
        maximumResponseBytes: Int,
        allowedRedirectHosts: Set<String> = [],
        maximumRedirects: Int = 0
    ) {
        self.maximumResponseBytes = max(0, maximumResponseBytes)
        self.allowedRedirectHosts = Set(
            allowedRedirectHosts.map { $0.lowercased() }
        )
        self.maximumRedirects = max(0, maximumRedirects)
        super.init()
    }

    @discardableResult
    func loadData(
        with request: URLRequest,
        completion: @escaping (Data?, URLResponse?, Error?) -> Void
    ) -> HTTPDataTasking {
        let task = session.dataTask(with: request)
        let state = RequestState(
            maximumResponseBytes: maximumResponseBytes,
            completion: completion
        )
        stateLock.lock()
        requestStates[task.taskIdentifier] = state
        stateLock.unlock()
        task.resume()
        return task
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        var disposition = URLSession.ResponseDisposition.allow
        var earlyCompletion: ((Data?, URLResponse?, Error?) -> Void)?
        var earlyError: Error?
        stateLock.lock()
        if let state = requestStates[dataTask.taskIdentifier] {
            state.response = response
            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode)
            {
                // 客户端只需要状态码：响应头到达后立刻完成并取消正文，
                // 避免慢速或无限错误页覆盖已知的 401/429/5xx。
                requestStates.removeValue(forKey: dataTask.taskIdentifier)
                earlyCompletion = state.completion
                disposition = .cancel
            } else if response.expectedContentLength
                > Int64(maximumResponseBytes)
            {
                requestStates.removeValue(forKey: dataTask.taskIdentifier)
                earlyCompletion = state.completion
                earlyError = HTTPDataLoaderError.responseTooLarge
                disposition = .cancel
            }
        }
        stateLock.unlock()
        completionHandler(disposition)
        earlyCompletion?(Data(), response, earlyError)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        var earlyCompletion: ((Data?, URLResponse?, Error?) -> Void)?
        var response: URLResponse?
        stateLock.lock()
        if let state = requestStates[dataTask.taskIdentifier],
           !state.buffer.append(data)
        {
            requestStates.removeValue(forKey: dataTask.taskIdentifier)
            earlyCompletion = state.completion
            response = state.response
        }
        stateLock.unlock()
        if let earlyCompletion {
            dataTask.cancel()
            earlyCompletion(
                nil,
                response,
                HTTPDataLoaderError.responseTooLarge
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        stateLock.lock()
        let state = requestStates.removeValue(
            forKey: task.taskIdentifier
        )
        stateLock.unlock()
        guard let state else { return }
        state.completion(
            state.buffer.data,
            state.response,
            error
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var redirectedRequest: URLRequest?
        stateLock.lock()
        if let state = requestStates[task.taskIdentifier],
           state.redirectCount < maximumRedirects,
           let permitted = permittedHTTPRedirectRequest(
            from: response.url,
            to: request,
            allowedHosts: allowedRedirectHosts
           )
        {
            state.redirectCount += 1
            redirectedRequest = permitted
        }
        stateLock.unlock()
        completionHandler(redirectedRequest)
    }
}

private final class HTTPCompletionGate {
    private let lock = NSLock()
    private var isCompleted = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isCompleted else { return false }
        isCompleted = true
        return true
    }
}

func sub2APIUsageURL(from baseURL: URL) throws -> URL {
    guard var components = URLComponents(
        url: baseURL,
        resolvingAgainstBaseURL: false
    ), components.query == nil, components.fragment == nil else {
        throw UsageProviderConfigurationError.invalidBaseURL
    }

    var path = components.path
    while path.count > 1 && path.hasSuffix("/") {
        path.removeLast()
    }
    if path.isEmpty || path == "/" {
        path = "/v1/usage"
    } else if path.hasSuffix("/v1/usage") {
        // 已是完整端点。
    } else if path.hasSuffix("/v1") {
        path += "/usage"
    } else {
        path += "/v1/usage"
    }
    components.path = path
    guard let url = components.url else {
        throw UsageProviderConfigurationError.invalidBaseURL
    }
    return url
}

private struct Sub2APIUsagePayload: Decodable {
    let mode: String
    let isValid: Bool?
    let planName: String?
    let remaining: Double?
    let balance: Double?
    let unit: String?
    let quota: Quota?
    let rateLimits: [RateLimit]?
    let subscription: Subscription?
    let usage: Usage?

    struct Quota: Decodable {
        let limit: Double
        let used: Double?
        let remaining: Double?
        let unit: String?
    }

    struct RateLimit: Decodable {
        let window: String
        let limit: Double
        let used: Double?
        let remaining: Double?
        let resetAt: String?

        enum CodingKeys: String, CodingKey {
            case window, limit, used, remaining
            case resetAt = "reset_at"
        }
    }

    struct Subscription: Decodable {
        let dailyUsageUSD: Double?
        let weeklyUsageUSD: Double?
        let monthlyUsageUSD: Double?
        let dailyLimitUSD: Double?
        let weeklyLimitUSD: Double?
        let monthlyLimitUSD: Double?
        let weeklyWindowStart: String?

        enum CodingKeys: String, CodingKey {
            case dailyUsageUSD = "daily_usage_usd"
            case weeklyUsageUSD = "weekly_usage_usd"
            case monthlyUsageUSD = "monthly_usage_usd"
            case dailyLimitUSD = "daily_limit_usd"
            case weeklyLimitUSD = "weekly_limit_usd"
            case monthlyLimitUSD = "monthly_limit_usd"
            case weeklyWindowStart = "weekly_window_start"
        }
    }

    struct Usage: Decodable {
        let today: Today?

        struct Today: Decodable {
            let totalTokens: Int64?

            enum CodingKeys: String, CodingKey {
                case totalTokens = "total_tokens"
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case mode, isValid, remaining, balance, unit, quota, subscription, usage
        case planName
        case rateLimits = "rate_limits"
    }
}

enum Sub2APIUsageError: LocalizedError, Equatable {
    case unauthorized
    case rateLimited
    case httpStatus(Int)
    case emptyResponse
    case responseTooLarge
    case invalidResponse
    case inactiveKey
    case timedOut
    case networkUnavailable
    case tlsFailure
    case requestFailed

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Sub2API API Key 无效或无权限"
        case .rateLimited:
            return "Sub2API 请求过于频繁"
        case .httpStatus(let code):
            return "Sub2API 接口返回 HTTP \(code)"
        case .emptyResponse:
            return "Sub2API 返回了空响应"
        case .responseTooLarge:
            return "Sub2API 响应过大"
        case .invalidResponse:
            return "Sub2API 响应格式异常"
        case .inactiveKey:
            return "Sub2API API Key 当前不可用"
        case .timedOut:
            return "Sub2API 请求超时"
        case .networkUnavailable:
            return "无法连接 Sub2API"
        case .tlsFailure:
            return "Sub2API TLS 连接失败"
        case .requestFailed:
            return "Sub2API 请求失败"
        }
    }
}

enum Sub2APIUsageMapper {
    private struct Cycle {
        let id: String
        let name: String
        let limit: Double
        let used: Double
        let remaining: Double
        let resetAt: Date?
    }

    static func presentation(
        from data: Data,
        now: Date = Date()
    ) throws -> QuotaPresentation {
        let payload: Sub2APIUsagePayload
        do {
            payload = try JSONDecoder().decode(
                Sub2APIUsagePayload.self,
                from: data
            )
        } catch {
            throw Sub2APIUsageError.invalidResponse
        }
        if payload.isValid == false {
            throw Sub2APIUsageError.inactiveKey
        }
        let dailyTokenText = todayTokenDetail(
            payload.usage?.today?.totalTokens
        )

        switch payload.mode.lowercased() {
        case "quota_limited":
            let candidates = (payload.rateLimits ?? []).compactMap {
                entry -> Cycle? in
                let normalizedWindow = entry.window
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                guard !normalizedWindow.isEmpty,
                      entry.limit.isFinite,
                      entry.limit > 0,
                      entry.used?.isFinite != false,
                      entry.remaining?.isFinite != false,
                      entry.remaining != nil || entry.used != nil
                else { return nil }
                let remaining = max(
                    0,
                    entry.remaining
                        ?? entry.limit - (entry.used ?? 0)
                )
                let used = max(
                    0,
                    entry.used ?? entry.limit - remaining
                )
                return Cycle(
                    id: normalizedWindow,
                    name: windowName(normalizedWindow),
                    limit: entry.limit,
                    used: used,
                    remaining: remaining,
                    resetAt: parseISO8601(entry.resetAt)
                )
            }
            if !candidates.isEmpty {
                let dailyCycle = candidates.first {
                    $0.name == "1 天"
                } ?? candidates[0]
                return try rateLimitPresentation(
                    cycles: candidates,
                    detail: usedAmountDetail(
                        used: dailyCycle.used,
                        limit: max(dailyCycle.limit, dailyCycle.used),
                        unit: payload.unit
                    ),
                    unit: payload.unit,
                    dailyTokenText: dailyTokenText
                )
            }

            // 旧版或精简响应可能只返回 quota；没有有效 rate_limits 时继续兼容。
            if let quota = payload.quota {
                guard quota.limit.isFinite else {
                    throw Sub2APIUsageError.invalidResponse
                }
                if let remaining = quota.remaining,
                   !remaining.isFinite
                {
                    throw Sub2APIUsageError.invalidResponse
                }
                if let used = quota.used, !used.isFinite {
                    throw Sub2APIUsageError.invalidResponse
                }
            }
            if let quota = payload.quota,
               quota.limit > 0,
               quota.remaining != nil || quota.used != nil
            {
                let remaining = max(
                    0,
                    quota.remaining ?? quota.limit - (quota.used ?? 0)
                )
                return try percentagePresentation(
                    remaining: remaining,
                    limit: quota.limit,
                    detail: usedAmountDetail(
                        used: quota.limit - remaining,
                        limit: quota.limit,
                        unit: quota.unit ?? payload.unit
                    ),
                    unit: quota.unit ?? payload.unit,
                    dailyTokenText: dailyTokenText
                )
            }
            throw Sub2APIUsageError.invalidResponse

        case "unrestricted":
            if let subscription = payload.subscription {
                var cycles: [Cycle] = []
                appendCycle(
                    name: "日额度",
                    limit: subscription.dailyLimitUSD,
                    used: subscription.dailyUsageUSD,
                    resetAt: nil,
                    to: &cycles
                )
                var weeklyReset = parseISO8601(
                    subscription.weeklyWindowStart
                ).map {
                    $0.addingTimeInterval(7 * 24 * 60 * 60)
                }
                while let reset = weeklyReset, reset <= now {
                    weeklyReset = reset.addingTimeInterval(7 * 24 * 60 * 60)
                }
                appendCycle(
                    name: "周额度",
                    limit: subscription.weeklyLimitUSD,
                    used: subscription.weeklyUsageUSD,
                    resetAt: weeklyReset,
                    to: &cycles
                )
                appendCycle(
                    name: "月额度",
                    limit: subscription.monthlyLimitUSD,
                    used: subscription.monthlyUsageUSD,
                    resetAt: nil,
                    to: &cycles
                )
                if let tightest = tightestCycle(cycles) {
                    let remaining = max(
                        0,
                        tightest.limit - tightest.used
                    )
                    let dailyUsed = subscription.dailyUsageUSD.flatMap {
                        $0.isFinite ? max(0, $0) : nil
                    }
                    return try percentagePresentation(
                        remaining: remaining,
                        limit: tightest.limit,
                        detail: dailyUsed.map {
                            usedAmountDetail(
                                used: $0,
                                limit: max(tightest.limit, $0),
                                unit: payload.unit
                            )
                        } ?? "",
                        unit: payload.unit,
                        dailyTokenText: dailyTokenText
                    )
                }
            }
            guard let balance = payload.balance ?? payload.remaining else {
                throw Sub2APIUsageError.invalidResponse
            }
            guard balance.isFinite else {
                throw Sub2APIUsageError.invalidResponse
            }
            return QuotaPresentation(
                sourceName: "Sub2API",
                valueText: "剩余 \(money(balance, unit: payload.unit))",
                progressPercent: nil,
                detailText: "",
                dailyTokenText: dailyTokenText,
                showsInlineUsageMetrics: true,
                isDepleted: balance <= 0
            )

        default:
            throw Sub2APIUsageError.invalidResponse
        }
    }

    private static func rateLimitPresentation(
        cycles: [Cycle],
        detail: String,
        unit: String?,
        dailyTokenText: String?
    ) throws -> QuotaPresentation {
        let options = try cycles.map { cycle -> QuotaRateLimitOption in
            guard cycle.remaining.isFinite,
                  cycle.limit.isFinite,
                  cycle.limit > 0
            else {
                throw Sub2APIUsageError.invalidResponse
            }
            let boundedRemaining = min(
                cycle.limit,
                max(0, cycle.remaining)
            )
            let percent = Int(
                (boundedRemaining / cycle.limit * 100).rounded()
            )
            return QuotaRateLimitOption(
                id: cycle.id,
                displayName: cycle.name,
                valueText: "剩余 \(money(boundedRemaining, unit: unit))",
                progressPercent: percent,
                isDepleted: boundedRemaining <= 0
            )
        }
        guard let first = options.first else {
            throw Sub2APIUsageError.invalidResponse
        }
        return QuotaPresentation(
            sourceName: "Sub2API",
            valueText: first.valueText,
            progressPercent: first.progressPercent,
            detailText: detail,
            dailyTokenText: dailyTokenText,
            showsInlineUsageMetrics: true,
            rateLimitOptions: options,
            selectedRateLimitID: first.id,
            isDepleted: first.isDepleted
        )
    }

    private static func percentagePresentation(
        remaining: Double,
        limit: Double,
        detail: String,
        unit: String?,
        dailyTokenText: String?
    ) throws -> QuotaPresentation {
        guard remaining.isFinite, limit.isFinite, limit > 0 else {
            throw Sub2APIUsageError.invalidResponse
        }
        let boundedRemaining = min(limit, max(0, remaining))
        let percent = Int(
            (boundedRemaining / limit * 100).rounded()
        )
        return QuotaPresentation(
            sourceName: "Sub2API",
            valueText: "剩余 \(money(boundedRemaining, unit: unit))",
            progressPercent: percent,
            detailText: detail,
            dailyTokenText: dailyTokenText,
            showsInlineUsageMetrics: true,
            isDepleted: boundedRemaining <= 0
        )
    }

    private static func todayTokenDetail(_ totalTokens: Int64?) -> String? {
        guard let totalTokens, totalTokens >= 0 else {
            return nil
        }
        let value = Double(totalTokens) / 100_000_000
        let formatted = String(
            format: "%.2f",
            locale: Locale(identifier: "en_US_POSIX"),
            value
        )
        return "今日Token \(formatted)亿"
    }

    private static func appendCycle(
        name: String,
        limit: Double?,
        used: Double?,
        resetAt: Date?,
        to cycles: inout [Cycle]
    ) {
        guard let limit, limit.isFinite, limit > 0,
              let used, used.isFinite
        else { return }
        let normalizedUsed = max(0, used)
        cycles.append(Cycle(
            id: name,
            name: name,
            limit: limit,
            used: normalizedUsed,
            remaining: max(0, limit - normalizedUsed),
            resetAt: resetAt
        ))
    }

    private static func tightestCycle(_ cycles: [Cycle]) -> Cycle? {
        cycles.min {
            $0.remaining / $0.limit < $1.remaining / $1.limit
        }
    }

    private static func windowName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "5h": return "5 小时"
        case "1d": return "1 天"
        case "7d": return "7 天"
        default: return raw
        }
    }

    private static func money(_ amount: Double, unit: String?) -> String {
        let value = String(
            format: "%.2f",
            locale: Locale(identifier: "en_US_POSIX"),
            amount
        )
        let normalizedUnit = (unit ?? "USD").uppercased()
        return normalizedUnit == "USD"
            ? "$\(value)" : "\(normalizedUnit) \(value)"
    }

    private static func usedAmountDetail(
        used: Double,
        limit: Double,
        unit: String?
    ) -> String {
        "今日已用 \(money(min(limit, max(0, used)), unit: unit))"
    }

    private static func parseISO8601(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        return fractional.date(from: raw)
            ?? ISO8601DateFormatter().date(from: raw)
    }
}

final class Sub2APIUsageClient: QuotaUsageFetching {
    static let maximumResponseBytes = 1_048_576
    let sourceDisplayName = "Sub2API"
    private let usageURL: URL
    private let apiKey: String
    private let loader: HTTPDataLoading
    private let now: () -> Date
    private let totalTimeout: TimeInterval

    init(
        baseURL: URL,
        apiKey: String,
        loader: HTTPDataLoading = BoundedURLSessionDataLoader.shared,
        now: @escaping () -> Date = Date.init,
        totalTimeout: TimeInterval = 10
    ) throws {
        usageURL = try sub2APIUsageURL(from: baseURL)
        self.apiKey = apiKey
        self.loader = loader
        self.now = now
        self.totalTimeout = max(0.001, totalTimeout)
    }

    func fetch(
        completion: @escaping (Result<QuotaPresentation, Error>) -> Void
    ) {
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = totalTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Accept"
        )
        request.setValue(
            "Bearer \(apiKey)",
            forHTTPHeaderField: "Authorization"
        )

        let completionGate = HTTPCompletionGate()
        let task = loader.loadData(with: request) {
            [now] data, response, error in
            guard completionGate.claim() else { return }
            if let http = response as? HTTPURLResponse {
                switch http.statusCode {
                case 200...299:
                    break
                case 401, 403:
                    completion(.failure(Sub2APIUsageError.unauthorized))
                    return
                case 429:
                    completion(.failure(Sub2APIUsageError.rateLimited))
                    return
                default:
                    completion(.failure(
                        Sub2APIUsageError.httpStatus(http.statusCode)
                    ))
                    return
                }
            }
            if let error {
                completion(.failure(Self.sanitizedNetworkError(error)))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(Sub2APIUsageError.invalidResponse))
                return
            }
            if http.expectedContentLength > Self.maximumResponseBytes {
                completion(.failure(Sub2APIUsageError.responseTooLarge))
                return
            }
            guard let data, !data.isEmpty else {
                completion(.failure(Sub2APIUsageError.emptyResponse))
                return
            }
            guard data.count <= Self.maximumResponseBytes else {
                completion(.failure(Sub2APIUsageError.responseTooLarge))
                return
            }
            do {
                completion(.success(
                    try Sub2APIUsageMapper.presentation(
                        from: data,
                        now: now()
                    )
                ))
            } catch let error as Sub2APIUsageError {
                completion(.failure(error))
            } catch {
                completion(.failure(Sub2APIUsageError.invalidResponse))
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + totalTimeout
        ) {
            guard completionGate.claim() else { return }
            task.cancel()
            completion(.failure(Sub2APIUsageError.timedOut))
        }
    }

    private static func sanitizedNetworkError(
        _ error: Error
    ) -> Sub2APIUsageError {
        if error is HTTPDataLoaderError {
            return .responseTooLarge
        }
        guard let urlError = error as? URLError else {
            return .requestFailed
        }
        switch urlError.code {
        case .timedOut:
            return .timedOut
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .notConnectedToInternet, .networkConnectionLost:
            return .networkUnavailable
        case .secureConnectionFailed, .serverCertificateHasBadDate,
             .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .clientCertificateRejected:
            return .tlsFailure
        default:
            return .requestFailed
        }
    }
}

private final class FailedQuotaUsageProvider: QuotaUsageFetching {
    let sourceDisplayName: String
    private let error: Error

    init(sourceDisplayName: String, error: Error) {
        self.sourceDisplayName = sourceDisplayName
        self.error = error
    }

    func fetch(
        completion: @escaping (Result<QuotaPresentation, Error>) -> Void
    ) {
        completion(.failure(error))
    }
}

func makeQuotaUsageProvider(
    configuration: UsageProviderConfiguration?,
    loader: HTTPDataLoading = BoundedURLSessionDataLoader.shared
) -> QuotaUsageFetching {
    switch resolveUsageProviderConfiguration(configuration) {
    case .success(.codex):
        return CodexQuotaUsageProvider()
    case let .success(.sub2api(baseURL, apiKey)):
        do {
            return try Sub2APIUsageClient(
                baseURL: baseURL,
                apiKey: apiKey,
                loader: loader
            )
        } catch {
            return FailedQuotaUsageProvider(
                sourceDisplayName: "Sub2API",
                error: error
            )
        }
    case .failure(let error):
        let normalized = configuration?.modelProvider
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return FailedQuotaUsageProvider(
            sourceDisplayName: normalized == "sub2api"
                || normalized?.isEmpty == true
                ? "Sub2API" : "第三方额度",
            error: error
        )
    }
}
