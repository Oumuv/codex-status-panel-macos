// Codex 额度响应模型，以及本机任务日志的发现、解析和展示状态整理。
// 阅读任务逻辑时，可从 TaskProgressSnapshot.displaying() 和 CodexTaskProgressReader.read() 开始。

import Darwin
import Foundation

struct RateLimitWindow: Decodable {
    let usedPercent: Int
    let windowDurationMins: Int64?
    let resetsAt: Int64?
}

struct SpendControlLimit: Decodable {
    let remainingPercent: Int
    let resetsAt: Int64
}

struct RateLimitSnapshot: Decodable {
    let limitId: String?
    let limitName: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
    let individualLimit: SpendControlLimit?
}

struct RateLimitsResult: Decodable {
    let rateLimits: RateLimitSnapshot
    let rateLimitsByLimitId: [String: RateLimitSnapshot]?
}

struct RPCError: Decodable {
    let message: String
}

struct RPCResponse: Decodable {
    let id: Int?
    let result: RateLimitsResult?
    let error: RPCError?
}

enum TaskProgressKind: String, Hashable {
    case reading
    case running
    case waitingForInput
    case completed
    case failed
    case idle
}

enum TaskProgressSource: String, Hashable {
    case codex
    case pi
}

enum CodexTaskClient: String, Equatable {
    case cli
    case app
    case orca
    case t3
    case pi
    case unknown
}

struct TaskProgressTarget: Equatable {
    let threadID: String?
    let client: CodexTaskClient
    let workingDirectory: String?
    let rolloutPath: String
    let processID: pid_t?

    init(
        threadID: String?,
        client: CodexTaskClient,
        workingDirectory: String?,
        rolloutPath: String,
        processID: pid_t? = nil
    ) {
        self.threadID = threadID
        self.client = client
        self.workingDirectory = workingDirectory
        self.rolloutPath = rolloutPath
        self.processID = processID
    }
}

struct TaskProgressItem: Equatable {
    let title: String
    let kind: TaskProgressKind
    let startedAt: Date
    let statusOverride: String?
    let source: TaskProgressSource
    let taskID: String?
    let target: TaskProgressTarget?

    init(
        title: String,
        kind: TaskProgressKind,
        startedAt: Date = .distantPast,
        statusOverride: String? = nil,
        source: TaskProgressSource = .codex,
        taskID: String? = nil,
        target: TaskProgressTarget? = nil
    ) {
        self.title = title
        self.kind = kind
        self.startedAt = startedAt
        self.statusOverride = statusOverride
        self.source = source
        self.taskID = taskID
        self.target = target
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

/// 某次刷新后真正交给 UI 的任务列表快照。
/// `Equatable` 允许视图通过 `oldValue` 判断数据是否变化，从而避免无意义重绘。
struct TaskProgressSnapshot: Equatable {
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

        // Codex 的周期任务每次运行都会新建线程；紧凑面板无法区分同名线程，
        // 因此只保留排序后优先级最高、时间最新的那一条。
        var seenItems = Set<String>()
        let deduplicated = sourceItems.filter { item in
            let normalizedTitle = item.title
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .lowercased()
            let key = item.taskID.map {
                "\(item.source.rawValue):id:\($0.lowercased())"
            } ?? "\(item.source.rawValue):title:\(normalizedTitle)"
            return seenItems.insert(key).inserted
        }
        guard !deduplicated.isEmpty else { return .idle }
        return TaskProgressSnapshot(items: Array(
            deduplicated.prefix(maximumVisibleTaskRows)
        ))
    }
}

struct TaskProgressReadResult: Equatable {
    let allItems: [TaskProgressItem]
    let snapshot: TaskProgressSnapshot
}

func sortedTaskProgressItems(
    _ sourceItems: [TaskProgressItem]
) -> [TaskProgressItem] {
    sourceItems.sorted {
        let leftTerminal = $0.kind == .completed || $0.kind == .failed
        let rightTerminal = $1.kind == .completed || $1.kind == .failed
        if leftTerminal != rightTerminal { return !leftTerminal }
        if $0.startedAt == $1.startedAt { return $0.title < $1.title }
        if leftTerminal { return $0.startedAt > $1.startedAt }
        return $0.startedAt < $1.startedAt
    }
}

/// 从本机 Codex rollout JSONL 日志中恢复用户可见任务的当前状态。
/// 读取过程分为：发现候选文件 → 解析尾部事件 → 合并标题 → 过滤与排序。
final class CodexTaskProgressReader {
    struct ReadDiagnostics: Equatable {
        var bytesRead = 0
        var fullRebuildCount = 0
        var incrementalReadCount = 0
        var cacheHitCount = 0
        var completeLineCount = 0
        var stringFilterLineCount = 0
        var jsonDecodingAttemptCount = 0
        var cacheEntryCount = 0
    }

    private struct RolloutCandidate {
        let url: URL
        let modificationDate: Date
    }

    private struct FileIdentity: Equatable {
        let systemNumber: UInt64
        let fileNumber: UInt64
    }

    private struct FileMetadata {
        let identity: FileIdentity
        let size: UInt64
        let modificationDate: Date
    }

    private struct LifecycleState {
        var lifecycle: TaskProgressKind?
        var pendingInteractionCalls = Set<String>()
        var latestUserTitle: String?
        var activeTaskTitle: String?
        var pendingResponseUserTitle: String?
        var activeResponseUserTitle: String?
        var taskStartedAt: Date?
        var taskEndedAt: Date?
    }

    private struct ParsedCacheEntry {
        let identity: FileIdentity
        var fileSize: UInt64
        var offset: UInt64
        var modificationDate: Date
        var pendingLineData: Data
        var isDiscardingLeadingFragment: Bool
        var lifecycleState: LifecycleState
        let target: TaskProgressTarget
        var snapshot: TaskProgressSnapshot
    }

    private struct RolloutSessionInfo {
        let isUserVisible: Bool
        let target: TaskProgressTarget
    }

    private struct SessionInfoCacheEntry {
        let identity: FileIdentity
        let info: RolloutSessionInfo
    }

    private let fileManager: FileManager
    private let rolloutURLsProvider: (() -> [URL])?
    private let threadTitlesOverride: [String: String]?
    private let unreadThreadIDsOverride: Set<String>?
    private let maximumTailBytes: UInt64 = 1_048_576
    private let rolloutRescanInterval: TimeInterval = 5
    private let activeTaskFreshness: TimeInterval = 30 * 60
    private static let completedTaskVisibility: TimeInterval = 2 * 60
    private static let failedTaskVisibility: TimeInterval = 5 * 60
    private var cachedRollouts: [RolloutCandidate] = []
    private var sessionInfoCache: [String: SessionInfoCacheEntry] = [:]
    private var parsedCache: [String: ParsedCacheEntry] = [:]
    private var cachedThreadTitles: [String: String] = [:]
    private var cachedThreadIndexModificationDate: Date?
    private var cachedUnreadThreadIDs = Set<String>()
    private var cachedUnreadStateModificationDate: Date?
    private var nextRolloutScanAt = Date.distantPast

    private(set) var lastReadDiagnostics = ReadDiagnostics()

    init(
        fileManager: FileManager = .default,
        rolloutURLsProvider: (() -> [URL])? = nil,
        threadTitlesOverride: [String: String]? = nil,
        unreadThreadIDsOverride: Set<String>? = nil
    ) {
        self.fileManager = fileManager
        self.rolloutURLsProvider = rolloutURLsProvider
        self.threadTitlesOverride = threadTitlesOverride
        self.unreadThreadIDsOverride = unreadThreadIDsOverride
    }

    func read(at now: Date = Date()) -> TaskProgressSnapshot {
        readResult(at: now).snapshot
    }

    func readResult(at now: Date = Date()) -> TaskProgressReadResult {
        lastReadDiagnostics = ReadDiagnostics()
        let threadTitles = threadTitlesOverride ?? readThreadTitleIndex()
        let unreadThreadIDs = unreadThreadIDsOverride ?? readUnreadThreadIDs()
        var items: [TaskProgressItem] = []

        let candidates = recentRollouts(at: now, unreadThreadIDs: unreadThreadIDs)
        for candidate in candidates {
            let cacheKey = candidate.url.path
            guard let metadata = fileMetadata(for: candidate.url),
                  let snapshot = readSnapshot(
                      from: candidate.url,
                      metadata: metadata,
                      cacheKey: cacheKey,
                      now: now
                  )
            else { continue }

            guard var item = snapshot.items.first, item.kind != .idle else { continue }
            let resolvedTitle = Self.resolvedTitle(
                for: candidate.url,
                indexedTitles: threadTitles,
                fallback: item.title
            )
            item = TaskProgressItem(
                title: resolvedTitle,
                kind: item.kind,
                startedAt: item.startedAt,
                statusOverride: item.statusOverride,
                source: item.source,
                taskID: item.taskID,
                target: item.target
            )

            items.append(item)
        }

        let activePaths = Set(candidates.map { $0.url.path })
        parsedCache = parsedCache.filter { activePaths.contains($0.key) }
        lastReadDiagnostics.cacheEntryCount = parsedCache.count

        let sortedItems = sortedTaskProgressItems(items)
        return TaskProgressReadResult(
            allItems: sortedItems,
            snapshot: .displaying(sortedItems)
        )
    }

    private func readSnapshot(
        from url: URL,
        metadata: FileMetadata,
        cacheKey: String,
        now: Date
    ) -> TaskProgressSnapshot? {
        if var cached = parsedCache[cacheKey], cached.identity == metadata.identity {
            if cached.fileSize == metadata.size,
               cached.offset == metadata.size,
               cached.modificationDate == metadata.modificationDate
            {
                lastReadDiagnostics.cacheHitCount += 1
                cached.snapshot = Self.snapshot(
                    from: cached.lifecycleState,
                    modificationDate: metadata.modificationDate,
                    now: now,
                    target: cached.target
                )
                parsedCache[cacheKey] = cached
                return cached.snapshot
            }

            if cached.offset == cached.fileSize, metadata.size > cached.offset {
                let appendedByteCount = metadata.size - cached.offset
                if appendedByteCount <= maximumTailBytes,
                   let data = readData(
                       from: url,
                       offset: cached.offset,
                       byteCount: Int(appendedByteCount)
                   )
                {
                    lastReadDiagnostics.bytesRead += data.count
                    lastReadDiagnostics.incrementalReadCount += 1
                    consume(
                        data,
                        into: &cached,
                        modificationDate: metadata.modificationDate
                    )
                    cached.fileSize = metadata.size
                    cached.offset = metadata.size
                    cached.modificationDate = metadata.modificationDate
                    cached.snapshot = Self.snapshot(
                        from: cached.lifecycleState,
                        modificationDate: metadata.modificationDate,
                        now: now,
                        target: cached.target
                    )
                    parsedCache[cacheKey] = cached
                    return cached.snapshot
                }
            }
        }

        guard let currentMetadata = fileMetadata(for: url),
              let rebuilt = rebuildCache(
                  from: url,
                  metadata: currentMetadata,
                  now: now
              )
        else { return nil }
        parsedCache[cacheKey] = rebuilt
        return rebuilt.snapshot
    }

    private func rebuildCache(
        from url: URL,
        metadata: FileMetadata,
        now: Date
    ) -> ParsedCacheEntry? {
        let startOffset = metadata.size > maximumTailBytes
            ? metadata.size - maximumTailBytes
            : 0
        let byteCount = Int(metadata.size - startOffset)
        guard let data = readData(
            from: url,
            offset: startOffset,
            byteCount: byteCount
        ) else { return nil }

        lastReadDiagnostics.bytesRead += data.count
        lastReadDiagnostics.fullRebuildCount += 1
        let target = sessionInfo(
            for: url,
            metadata: metadata
        ).target
        var entry = ParsedCacheEntry(
            identity: metadata.identity,
            fileSize: metadata.size,
            offset: startOffset + UInt64(data.count),
            modificationDate: metadata.modificationDate,
            pendingLineData: Data(),
            isDiscardingLeadingFragment: startOffset > 0,
            lifecycleState: LifecycleState(),
            target: target,
            snapshot: .idle
        )
        consume(
            data,
            into: &entry,
            modificationDate: metadata.modificationDate
        )
        entry.snapshot = Self.snapshot(
            from: entry.lifecycleState,
            modificationDate: metadata.modificationDate,
            now: now,
            target: target
        )
        return entry
    }

    private func consume(
        _ newData: Data,
        into entry: inout ParsedCacheEntry,
        modificationDate: Date
    ) {
        var data = newData
        if entry.isDiscardingLeadingFragment {
            guard let firstNewline = data.firstIndex(of: 0x0A) else { return }
            let firstCompleteIndex = data.index(after: firstNewline)
            data = firstCompleteIndex < data.endIndex
                ? data.subdata(in: firstCompleteIndex..<data.endIndex)
                : Data()
            entry.isDiscardingLeadingFragment = false
        }

        if !entry.pendingLineData.isEmpty {
            var combined = entry.pendingLineData
            combined.append(data)
            data = combined
            entry.pendingLineData.removeAll(keepingCapacity: false)
        }

        var lineStart = data.startIndex
        while lineStart < data.endIndex,
              let newline = data[lineStart...].firstIndex(of: 0x0A)
        {
            let lineRange = lineStart..<newline
            if !lineRange.isEmpty {
                lastReadDiagnostics.completeLineCount += 1
                if lineRange.count <= maximumTailBytes {
                    Self.consumeRelevantLine(
                        in: data,
                        range: lineRange,
                        state: &entry.lifecycleState,
                        modificationDate: modificationDate,
                        diagnostics: &lastReadDiagnostics
                    )
                }
            }
            lineStart = data.index(after: newline)
        }

        guard lineStart < data.endIndex else { return }
        let fragment = data.subdata(in: lineStart..<data.endIndex)
        if fragment.count <= maximumTailBytes {
            entry.pendingLineData = fragment
        } else {
            entry.isDiscardingLeadingFragment = true
        }
    }

    private func readData(
        from url: URL,
        offset: UInt64,
        byteCount: Int
    ) -> Data? {
        guard byteCount >= 0,
              let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: offset)
            guard byteCount > 0 else { return Data() }
            guard let data = try handle.read(upToCount: byteCount),
                  data.count == byteCount
            else { return nil }
            return data
        } catch {
            return nil
        }
    }

    private func sessionInfo(
        for url: URL,
        metadata: FileMetadata
    ) -> RolloutSessionInfo {
        if let cached = sessionInfoCache[url.path],
           cached.identity == metadata.identity
        {
            return cached.info
        }

        let maximumMetadataBytes = 262_144
        let data = readData(
            from: url,
            offset: 0,
            byteCount: Int(min(UInt64(maximumMetadataBytes), metadata.size))
        ) ?? Data()
        let payload = Self.sessionMetadataPayload(data: data)
        let info = RolloutSessionInfo(
            isUserVisible: payload.map(Self.isUserVisibleSessionMetadata) ?? true,
            target: Self.taskTarget(payload: payload, rolloutURL: url)
        )
        sessionInfoCache[url.path] = SessionInfoCacheEntry(
            identity: metadata.identity,
            info: info
        )
        return info
    }

    private func fileMetadata(for url: URL) -> FileMetadata? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              let modificationDate = attributes[.modificationDate] as? Date,
              let systemNumber = attributes[.systemNumber] as? NSNumber,
              let fileNumber = attributes[.systemFileNumber] as? NSNumber
        else { return nil }
        return FileMetadata(
            identity: FileIdentity(
                systemNumber: systemNumber.uint64Value,
                fileNumber: fileNumber.uint64Value
            ),
            size: size.uint64Value,
            modificationDate: modificationDate
        )
    }

    static func parse(
        lines: [String],
        modificationDate: Date,
        now: Date,
        target: TaskProgressTarget? = nil
    ) -> TaskProgressSnapshot {
        var state = LifecycleState()

        for line in lines {
            // 先用字符串筛选可能相关的行，再做 JSON 解析，降低大日志的刷新成本。
            guard isPotentiallyRelevant(line: line) else { continue }

            guard let data = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(
                      with: data
                  ) as? [String: Any]
            else { continue }
            apply(
                record: record,
                to: &state,
                modificationDate: modificationDate
            )
        }

        return snapshot(
            from: state,
            modificationDate: modificationDate,
            now: now,
            target: target
        )
    }

    private static func consumeRelevantLine(
        in data: Data,
        range: Range<Data.Index>,
        state: inout LifecycleState,
        modificationDate: Date,
        diagnostics: inout ReadDiagnostics
    ) {
        func contains(_ marker: Data) -> Bool {
            data.range(of: marker, options: [], in: range) != nil
        }
        guard relevantLineMarkers.contains(where: contains)
                || responseUserMarkers.allSatisfy(contains)
        else { return }

        diagnostics.jsonDecodingAttemptCount += 1
        let lineData = data.subdata(in: range)
        guard let record = try? JSONSerialization.jsonObject(
            with: lineData
        ) as? [String: Any] else { return }
        apply(
            record: record,
            to: &state,
            modificationDate: modificationDate
        )
    }

    private static func apply(
        record: [String: Any],
        to state: inout LifecycleState,
        modificationDate: Date
    ) {
        guard let payload = record["payload"] as? [String: Any],
              let payloadType = payload["type"] as? String
        else { return }

        if record["type"] as? String == "event_msg" {
            if payloadType == "user_message",
               let message = payload["message"] as? String,
               let title = taskTitle(from: message)
            {
                if state.lifecycle == .running {
                    state.activeTaskTitle = title
                } else {
                    state.latestUserTitle = title
                }
            } else if payloadType == "task_started" {
                state.lifecycle = .running
                state.pendingInteractionCalls.removeAll()
                state.activeTaskTitle = state.latestUserTitle
                state.latestUserTitle = nil
                state.activeResponseUserTitle = state.pendingResponseUserTitle
                state.pendingResponseUserTitle = nil
                state.taskStartedAt = timestamp(from: record) ?? modificationDate
                state.taskEndedAt = nil
            } else if payloadType == "task_complete" {
                if state.lifecycle != .completed || state.taskEndedAt == nil {
                    state.taskEndedAt = timestamp(from: record)
                }
                state.lifecycle = .completed
                state.pendingInteractionCalls.removeAll()
            } else if ["task_failed", "turn_aborted", "error"].contains(payloadType) {
                if state.lifecycle != .failed || state.taskEndedAt == nil {
                    state.taskEndedAt = timestamp(from: record)
                }
                state.lifecycle = .failed
                state.pendingInteractionCalls.removeAll()
            }
            return
        }

        // Orca 等客户端可能只写 response_item；用户消息通常在 task_started 之后到达。
        if record["type"] as? String == "response_item", payloadType == "message",
           payload["role"] as? String == "user"
        {
            if state.lifecycle == .running {
                if state.activeResponseUserTitle == nil {
                    state.activeResponseUserTitle = responseUserTitle(from: payload)
                }
            } else if state.pendingResponseUserTitle == nil {
                state.pendingResponseUserTitle = responseUserTitle(from: payload)
            }
            return
        }

        // 用户输入或命令审批发出后记录 call_id；收到对应输出才视为用户已响应。
        if ["function_call", "custom_tool_call"].contains(payloadType),
           isPendingInteractionCall(payload),
           let callID = payload["call_id"] as? String
        {
            state.pendingInteractionCalls.insert(callID)
            return
        }

        if ["function_call_output", "custom_tool_call_output"].contains(payloadType),
           let callID = payload["call_id"] as? String
        {
            state.pendingInteractionCalls.remove(callID)
        }
    }

    private static func isPendingInteractionCall(_ payload: [String: Any]) -> Bool {
        guard let name = payload["name"] as? String else { return false }
        if name == "request_user_input" { return true }

        if name == "exec_command",
           let rawArguments = payload["arguments"] as? String,
           let data = rawArguments.data(using: .utf8),
           let arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            return arguments["sandbox_permissions"] as? String == "require_escalated"
        }

        guard name == "exec",
              let input = payload["input"] as? String,
              input.contains("tools.exec_command")
        else { return false }
        return input.range(
            of: #"[\"']?sandbox_permissions[\"']?\s*:\s*[\"']require_escalated[\"']"#,
            options: .regularExpression
        ) != nil
    }

    private static func snapshot(
        from state: LifecycleState,
        modificationDate: Date,
        now: Date,
        target: TaskProgressTarget?
    ) -> TaskProgressSnapshot {
        let title = state.activeTaskTitle ?? state.activeResponseUserTitle
            ?? (state.lifecycle == nil
                ? state.latestUserTitle ?? state.pendingResponseUserTitle : nil)
            ?? "Codex 任务"
        let taskStartedAt = state.taskStartedAt ?? modificationDate
        if state.lifecycle == .running, !state.pendingInteractionCalls.isEmpty {
            return TaskProgressSnapshot(items: [TaskProgressItem(
                title: title,
                kind: .waitingForInput,
                startedAt: taskStartedAt,
                target: target
            )])
        }
        if let lifecycle = state.lifecycle {
            if lifecycle == .completed || lifecycle == .failed {
                // 只信任结束事件的时间，避免旧任务因日志补写或重启重新显示。
                guard let endedAt = state.taskEndedAt else { return .idle }
                let visibility = lifecycle == .completed
                    ? completedTaskVisibility : failedTaskVisibility
                let elapsed = now.timeIntervalSince(endedAt)
                guard elapsed >= 0, elapsed < visibility else { return .idle }
            }
            return TaskProgressSnapshot(items: [TaskProgressItem(
                title: title,
                kind: lifecycle,
                startedAt: taskStartedAt,
                target: target
            )])
        }
        if !state.pendingInteractionCalls.isEmpty {
            return TaskProgressSnapshot(items: [TaskProgressItem(
                title: title,
                kind: .waitingForInput,
                startedAt: taskStartedAt,
                target: target
            )])
        }
        if now.timeIntervalSince(modificationDate) <= 30 * 60 {
            return TaskProgressSnapshot(items: [TaskProgressItem(
                title: title,
                kind: .running,
                startedAt: taskStartedAt,
                target: target
            )])
        }
        return .idle
    }

    private static func isPotentiallyRelevant(line: String) -> Bool {
        line.contains("task_started")
            || line.contains("task_complete")
            || line.contains("task_failed")
            || line.contains("turn_aborted")
            || line.contains(#""error""#)
            || line.contains("user_message")
            || line.contains("request_user_input")
            || line.contains("require_escalated")
            || line.contains("function_call_output")
            || line.contains("custom_tool_call_output")
            || (line.contains(#""response_item""#)
                && line.contains(#""role""#) && line.contains(#""user""#))
    }

    private static let relevantLineMarkers = [
        Data("task_started".utf8),
        Data("task_complete".utf8),
        Data("task_failed".utf8),
        Data("turn_aborted".utf8),
        Data(#""type":"error""#.utf8),
        Data(#""error""#.utf8),
        Data("user_message".utf8),
        Data("request_user_input".utf8),
        Data("require_escalated".utf8),
        Data("function_call_output".utf8),
        Data("custom_tool_call_output".utf8),
    ]

    private static let responseUserMarkers = [
        Data(#""response_item""#.utf8), Data(#""role""#.utf8), Data(#""user""#.utf8),
    ]

    private static func responseUserTitle(from payload: [String: Any]) -> String? {
        guard let content = payload["content"] as? [[String: Any]] else { return nil }
        let text = content.compactMap { item -> String? in
            guard item["type"] as? String == "input_text",
                  let raw = item["text"] as? String
            else { return nil }
            var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let context = value.lowercased()
            guard !context.hasPrefix("# agents.md"),
                  !context.hasPrefix("<environment_context>"),
                  !context.hasPrefix("<system-reminder>"),
                  !context.hasPrefix("[from the result of "),
                  !context.hasPrefix("<image "),
                  context != "<image>", context != "</image>"
            else { return nil }
            if context.hasPrefix("[image #"), let boundary = value.firstIndex(of: "]") {
                value = String(value[value.index(after: boundary)...])
            }
            return value
        }.joined(separator: "\n")
        return taskTitle(from: text)
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

    static func isUserVisibleSessionMetadata(line: String) -> Bool {
        isUserVisibleSessionMetadata(data: Data(line.utf8))
    }

    static func isUserVisibleSessionMetadata(data: Data) -> Bool {
        guard let payload = sessionMetadataPayload(data: data) else { return true }
        return isUserVisibleSessionMetadata(payload: payload)
    }

    static func taskTarget(
        sessionMetadataLine: String,
        rolloutURL: URL
    ) -> TaskProgressTarget {
        taskTarget(
            payload: sessionMetadataPayload(data: Data(sessionMetadataLine.utf8)),
            rolloutURL: rolloutURL
        )
    }

    private static func isUserVisibleSessionMetadata(
        payload: [String: Any]
    ) -> Bool {
        let threadSource = (payload["thread_source"] as? String)?.lowercased()
        if threadSource == "subagent" || threadSource == "automation" {
            return false
        }
        if let source = payload["source"] as? [String: Any], source["subagent"] != nil {
            return false
        }
        return true
    }

    private static func sessionMetadataPayload(data: Data) -> [String: Any]? {
        let lineEnd = data.firstIndex(of: 0x0A) ?? data.endIndex
        let firstLineData = data.subdata(in: data.startIndex..<lineEnd)
        guard let record = try? JSONSerialization.jsonObject(
            with: firstLineData
        ) as? [String: Any],
        record["type"] as? String == "session_meta"
        else { return nil }
        return record["payload"] as? [String: Any]
    }

    private static func taskTarget(
        payload: [String: Any]?,
        rolloutURL: URL
    ) -> TaskProgressTarget {
        let payloadThreadID = (payload?["id"] as? String)
            ?? (payload?["thread_id"] as? String)
        let normalizedPayloadThreadID = payloadThreadID.flatMap(normalizedThreadID)
        let workingDirectory: String? = (payload?["cwd"] as? String).flatMap {
            rawValue -> String? in
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return URL(fileURLWithPath: trimmed).standardizedFileURL.path
        }

        return TaskProgressTarget(
            threadID: normalizedPayloadThreadID ?? threadID(from: rolloutURL),
            client: taskClient(from: payload),
            workingDirectory: workingDirectory,
            rolloutPath: rolloutURL.path
        )
    }

    private static func normalizedThreadID(_ value: String) -> String? {
        let pattern = #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#
        guard value.range(of: pattern, options: .regularExpression) != nil else {
            return nil
        }
        return value.lowercased()
    }

    private static func taskClient(from payload: [String: Any]?) -> CodexTaskClient {
        let originator = (payload?["originator"] as? String)?.lowercased() ?? ""
        let sourceName: String
        if let source = payload?["source"] as? String {
            sourceName = source.lowercased()
        } else if let source = payload?["source"] as? [String: Any] {
            sourceName = source.keys.map { $0.lowercased() }.joined(separator: " ")
        } else {
            sourceName = ""
        }

        // app-server 的 source 也可能是 vscode；originator 才能区分宿主。
        // 先识别第三方及 TUI，不能把 orca_desktop 当成 Codex Desktop。
        if originator == "orca" || originator.hasPrefix("orca_")
            || originator.hasPrefix("orca-") { return .orca }
        if ["t3 code", "t3-code", "t3_code", "t3code"].contains(where: {
            originator == $0 || originator.hasPrefix($0 + "-")
                || originator.hasPrefix($0 + "_")
        }) { return .t3 }
        if originator.contains("codex-tui") || originator.contains("codex_cli") {
            return .cli
        }
        if ["codex desktop", "codex_desktop", "codex-desktop", "codex_work"].contains(originator) {
            return .app
        }
        if sourceName == "cli" {
            return .cli
        }
        return .unknown
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

    private func readUnreadThreadIDs() -> Set<String> {
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
            return cachedUnreadThreadIDs
        }
        if cachedUnreadStateModificationDate == modificationDate {
            return cachedUnreadThreadIDs
        }

        guard let data = try? Data(contentsOf: stateURL),
              let unreadThreadIDs = Self.unreadThreadIDs(from: data)
        else {
            return cachedUnreadThreadIDs
        }

        cachedUnreadThreadIDs = unreadThreadIDs
        cachedUnreadStateModificationDate = modificationDate
        return unreadThreadIDs
    }

    static func unreadThreadIDs(from data: Data) -> Set<String>? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if let rawThreadReadState = root["electron-thread-read-state-v1"] {
            guard let threadReadState = rawThreadReadState as? [String: Any],
                  let unreadByIdentity = threadReadState[
                      "unreadByIdentity"
                  ] as? [String: Any]
            else { return nil }

            var ids = Set<String>()
            for value in unreadByIdentity.values {
                guard let unreadByHost = value as? [String: Any],
                      let identityIDs = unreadThreadIDs(from: unreadByHost)
                else { return nil }
                ids.formUnion(identityIDs)
            }
            return ids
        }

        guard let atomState = root[
            "electron-persisted-atom-state"
        ] as? [String: Any],
        let unreadByHost = atomState[
            "unread-thread-ids-by-host-v1"
        ] as? [String: Any],
        let ids = unreadThreadIDs(from: unreadByHost)
        else { return nil }
        return ids
    }

    private static func unreadThreadIDs(
        from unreadByHost: [String: Any]
    ) -> Set<String>? {
        var ids = Set<String>()
        for value in unreadByHost.values {
            guard let hostIDs = value as? [String] else { return nil }
            ids.formUnion(hostIDs.map { $0.lowercased() })
        }
        return ids
    }

    private func recentRollouts(
        at now: Date,
        unreadThreadIDs: Set<String>
    ) -> [RolloutCandidate] {
        if let rolloutURLsProvider {
            return rolloutURLsProvider().compactMap { url in
                guard isUserVisibleRollout(url) else { return nil }
                let modified = (try? url.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate) ?? now
                return RolloutCandidate(url: url, modificationDate: modified)
            }
        }

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

        // 两次目录扫描之间复用候选列表，但会剔除已经消失的文件。
        if now < nextRolloutScanAt, !cachedRollouts.isEmpty {
            return cachedRollouts.filter {
                fileManager.fileExists(atPath: $0.url.path)
            }
        }

        nextRolloutScanAt = now.addingTimeInterval(rolloutRescanInterval)
        let codexHome = codexHomeURL()
        let sessionsURL = codexHome.appendingPathComponent(
            "sessions",
            isDirectory: true
        )
        guard let enumerator = fileManager.enumerator(
            at: sessionsURL,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .isRegularFileKey,
            ],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            cachedRollouts = []
            return []
        }

        var candidates: [RolloutCandidate] = []
        // enumerator 返回 Any；`for case let ... as URL` 只遍历能够转换成 URL 的元素。
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  url.lastPathComponent.hasPrefix("rollout-"),
                  let values = try? url.resourceValues(
                      forKeys: [.contentModificationDateKey, .isRegularFileKey]
                  ),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate
            else { continue }
            let threadID = Self.threadID(from: url)
            let isUnread = threadID.map { unreadThreadIDs.contains($0) } ?? false
            // 未读仅用于发现候选，不能延长结束态的展示时间。
            guard now.timeIntervalSince(modified) <= activeTaskFreshness || isUnread,
                  isUserVisibleRollout(url)
            else {
                continue
            }
            candidates.append(RolloutCandidate(
                url: url,
                modificationDate: modified
            ))
        }

        cachedRollouts = Array(candidates.sorted {
            $0.modificationDate > $1.modificationDate
        }.prefix(12))
        let activePaths = Set(cachedRollouts.map { $0.url.path })
        parsedCache = parsedCache.filter { activePaths.contains($0.key) }
        return cachedRollouts
    }

    private func isUserVisibleRollout(_ url: URL) -> Bool {
        guard let metadata = fileMetadata(for: url) else { return true }
        return sessionInfo(for: url, metadata: metadata).isUserVisible
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
