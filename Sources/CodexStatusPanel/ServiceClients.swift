// 外部数据访问层：读取 Codex 配置、调用本机 app-server 获取额度、查询行情。
// 客户端通过 completion 闭包异步返回 Result，调用方不需要了解进程或网络细节。

import Foundation

private struct BinanceTickerResponse: Decodable {
    let symbol: String
    let price: String
}

func codexSnapshot(from response: RateLimitsResult) -> RateLimitSnapshot {
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

enum PointerSide: Equatable {
    case left
    case right
    case bottom
}

enum QuotaClientError: LocalizedError {
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

/// 只读取 config.toml 顶层的 model_provider，避免为一个错误提示加载和解析完整配置。
struct CodexConfigurationReader {
    private enum TopLevelLineResult {
        case skip
        case stop
        case provider(String)
    }

    private static let maximumConfigBytes = 64 * 1_024
    private static let configReadChunkBytes = 4 * 1_024

    static func modelProvider(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        // 无论从哪个 return 离开函数，defer 都会负责关闭文件句柄。
        defer { try? handle.close() }

        // 分块读取并设置 64 KiB 上限，防止异常配置文件占用过多内存。
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
        // 一旦进入首个 TOML 表，就不再接受后续同名键，确保只读取顶层配置。
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

func codexConfigurationURL() -> URL {
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

func quotaErrorDisplayText(
    _ error: Error,
    modelProviderLoader: () -> String?
) -> String {
    guard let quotaError = error as? QuotaClientError else {
        return error.localizedDescription
    }
    switch quotaError {
    case .authentication(let message):
        // 只有认证错误才执行这个闭包，普通失败不会额外读取用户配置文件。
        return quotaErrorDisplayText(
            message,
            modelProvider: modelProviderLoader()
        )
    default:
        return error.localizedDescription
    }
}

func quotaErrorDisplayText(
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

/// 通过 `codex app-server --stdio` 的 JSON-RPC 协议读取账户额度。
final class CodexQuotaClient {
    private let decoder = JSONDecoder()

    func fetch(completion: @escaping (Result<RateLimitsResult, Error>) -> Void) {
        // `@escaping` 表示 completion 会在函数返回后、后台队列完成工作时再调用。
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

        // JSON-RPC 必须先 initialize；收到 id=1 的响应后才能发送额度读取请求。
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

        // readLoop 标签让内层 while 收到最终响应后可以直接跳出两层循环。
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

/// 使用 URLSession 异步读取单个交易对的最新价格。
final class MarketPriceClient {
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

        // 捕获列表 `[decoder]` 只把解码器带入闭包，避免整个客户端被网络任务长期持有。
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
