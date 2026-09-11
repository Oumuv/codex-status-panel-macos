// Codex 额度响应模型，以及本机任务日志的发现、解析和展示状态整理。
// 阅读任务逻辑时，可从 TaskProgressSnapshot.displaying() 和 CodexTaskProgressReader.read() 开始。

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

enum TaskProgressKind: String, Equatable {
    case reading
    case running
    case waitingForInput
    case completed
    case failed
    case idle
}

struct TaskProgressItem: Equatable {
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
        var seenTitles = Set<String>()
        let deduplicated = sourceItems.filter { item in
            let key = item.title
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .lowercased()
            return seenTitles.insert(key).inserted
        }
        guard !deduplicated.isEmpty else { return .idle }
        return TaskProgressSnapshot(items: Array(
            deduplicated.prefix(maximumVisibleTaskRows)
        ))
    }
}

func shouldAnimateRunningArrow(
    isWindowVisible: Bool,
    isCollapsed: Bool,
    hasRunningTask: Bool
) -> Bool {
    isWindowVisible && !isCollapsed && hasRunningTask
}

/// 从本机 Codex rollout JSONL 日志中恢复用户可见任务的当前状态。
/// 读取过程分为：发现候选文件 → 解析尾部事件 → 合并标题 → 过滤与排序。
final class CodexTaskProgressReader {
    struct UnreadThreadState {
        let ids: Set<String>
        let isAvailable: Bool
    }

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
        var taskStartedAt: Date?
    }

    private struct ParsedCacheEntry {
        let identity: FileIdentity
        var fileSize: UInt64
        var offset: UInt64
        var modificationDate: Date
        var pendingLineData: Data
        var isDiscardingLeadingFragment: Bool
        var lifecycleState: LifecycleState
        var snapshot: TaskProgressSnapshot
    }

    private let fileManager: FileManager
    private let rolloutURLsProvider: (() -> [URL])?
    private let threadTitlesOverride: [String: String]?
    private let unreadStateOverride: UnreadThreadState?
    private let maximumTailBytes: UInt64 = 1_048_576
    private let rolloutRescanInterval: TimeInterval = 5
    private let activeTaskFreshness: TimeInterval = 30 * 60
    private let completedTaskVisibility: TimeInterval = 2 * 60
    private var cachedRollouts: [RolloutCandidate] = []
    private var cachedRolloutVisibility: [String: Bool] = [:]
    private var parsedCache: [String: ParsedCacheEntry] = [:]
    private var cachedThreadTitles: [String: String] = [:]
    private var cachedThreadIndexModificationDate: Date?
    private var cachedUnreadThreadIDs = Set<String>()
    private var cachedUnreadStateModificationDate: Date?
    private var hasCachedUnreadState = false
    private var nextRolloutScanAt = Date.distantPast

    private(set) var lastReadDiagnostics = ReadDiagnostics()

    init(
        fileManager: FileManager = .default,
        rolloutURLsProvider: (() -> [URL])? = nil,
        threadTitlesOverride: [String: String]? = nil,
        unreadStateOverride: UnreadThreadState? = nil
    ) {
        self.fileManager = fileManager
        self.rolloutURLsProvider = rolloutURLsProvider
        self.threadTitlesOverride = threadTitlesOverride
        self.unreadStateOverride = unreadStateOverride
    }

    func read(at now: Date = Date()) -> TaskProgressSnapshot {
        lastReadDiagnostics = ReadDiagnostics()
        let threadTitles = threadTitlesOverride ?? readThreadTitleIndex()
        let unreadState = unreadStateOverride ?? readUnreadThreadState()
        var items: [TaskProgressItem] = []

        let candidates = recentRollouts(at: now, unreadThreadIDs: unreadState.ids)
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
                modificationDate: metadata.modificationDate,
                now: now,
                unreadState: unreadState,
                fallbackVisibility: completedTaskVisibility
            ) else { continue }
            items.append(item)
        }

        let activePaths = Set(candidates.map { $0.url.path })
        parsedCache = parsedCache.filter { activePaths.contains($0.key) }
        lastReadDiagnostics.cacheEntryCount = parsedCache.count

        // 进行中的任务排在终态任务之前；同组内再按开始时间稳定排序。
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
                    now: now
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
                        now: now
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
        var entry = ParsedCacheEntry(
            identity: metadata.identity,
            fileSize: metadata.size,
            offset: startOffset + UInt64(data.count),
            modificationDate: metadata.modificationDate,
            pendingLineData: Data(),
            isDiscardingLeadingFragment: startOffset > 0,
            lifecycleState: LifecycleState(),
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
            now: now
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
        now: Date
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
            now: now
        )
    }

    private static func consumeRelevantLine(
        in data: Data,
        range: Range<Data.Index>,
        state: inout LifecycleState,
        modificationDate: Date,
        diagnostics: inout ReadDiagnostics
    ) {
        guard relevantLineMarkers.contains(where: {
            data.range(of: $0, options: [], in: range) != nil
        }) else { return }

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
                state.latestUserTitle = title
            } else if payloadType == "task_started" {
                state.lifecycle = .running
                state.pendingInteractionCalls.removeAll()
                state.activeTaskTitle = state.latestUserTitle ?? state.activeTaskTitle
                state.taskStartedAt = timestamp(from: record) ?? modificationDate
            } else if payloadType == "task_complete" {
                state.lifecycle = .completed
                state.pendingInteractionCalls.removeAll()
            } else if ["task_failed", "turn_aborted", "error"].contains(payloadType) {
                state.lifecycle = .failed
                state.pendingInteractionCalls.removeAll()
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
        now: Date
    ) -> TaskProgressSnapshot {
        let title = state.activeTaskTitle ?? state.latestUserTitle ?? "Codex 任务"
        let taskStartedAt = state.taskStartedAt ?? modificationDate
        if state.lifecycle == .running, !state.pendingInteractionCalls.isEmpty {
            return TaskProgressSnapshot(items: [TaskProgressItem(
                title: title,
                kind: .waitingForInput,
                startedAt: taskStartedAt
            )])
        }
        if let lifecycle = state.lifecycle {
            return TaskProgressSnapshot(items: [TaskProgressItem(
                title: title,
                kind: lifecycle,
                startedAt: taskStartedAt
            )])
        }
        if !state.pendingInteractionCalls.isEmpty {
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
        let lineEnd = data.firstIndex(of: 0x0A) ?? data.endIndex
        let firstLineData = data.subdata(in: data.startIndex..<lineEnd)
        guard let record = try? JSONSerialization.jsonObject(
            with: firstLineData
        ) as? [String: Any],
              record["type"] as? String == "session_meta",
              let payload = record["payload"] as? [String: Any]
        else {
            return true
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
        if let cached = cachedRolloutVisibility[url.path] { return cached }

        var isVisible = true
        if let handle = try? FileHandle(forReadingFrom: url) {
            // defer 会在当前作用域退出时执行，确保所有分支都能关闭文件句柄。
            defer { try? handle.close() }
            if let data = try? handle.read(upToCount: 262_144) {
                isVisible = Self.isUserVisibleSessionMetadata(data: data)
            }
        }
        cachedRolloutVisibility[url.path] = isVisible
        return isVisible
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
