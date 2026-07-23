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

struct QuotaRow {
    let name: String
    let remainingPercent: Int
    let resetsAt: Date?
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

    private struct RolloutCandidate {
        let url: URL
        let modificationDate: Date
    }

    private struct ParsedCacheEntry {
        let modificationDate: Date
        let snapshot: TaskProgressSnapshot
    }

    private let fileManager = FileManager.default
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

    func read() -> TaskProgressSnapshot {
        let now = Date()
        let threadTitles = readThreadTitleIndex()
        let unreadState = readUnreadThreadState()
        var items: [TaskProgressItem] = []

        // 文件修改时间未变时直接复用解析结果，避免每两秒重复解析同一个大日志。
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
            // 先用字符串筛选可能相关的行，再做 JSON 解析，降低大日志的刷新成本。
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

            // request_user_input 发出后记录 call_id；收到对应输出才视为用户已响应。
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

    static func isUserVisibleSessionMetadata(line: String) -> Bool {
        guard let data = line.data(using: .utf8),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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
            if let data = try? handle.read(upToCount: 262_144),
               let text = String(data: data, encoding: .utf8),
               let firstLine = text.split(
                   separator: "\n",
                   maxSplits: 1
               ).first
            {
                isVisible = Self.isUserVisibleSessionMetadata(
                    line: String(firstLine)
                )
            }
        }
        cachedRolloutVisibility[url.path] = isVisible
        return isVisible
    }

    private func readTailLines(from url: URL) -> [String]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        // 只读取末尾最多 1 MiB；任务生命周期事件位于日志尾部，无需加载整个文件。
        let fileSize = (try? handle.seekToEnd()) ?? 0
        let startOffset = fileSize > maximumTailBytes
            ? fileSize - maximumTailBytes
            : 0
        do {
            try handle.seek(toOffset: startOffset)
            guard var data = try handle.readToEnd(), !data.isEmpty else {
                return []
            }
            // 从文件中间开始时，第一段通常是不完整 JSON，丢到首个换行符之后再解析。
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
