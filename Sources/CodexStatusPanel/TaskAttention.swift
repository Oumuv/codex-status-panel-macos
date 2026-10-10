// 将轮询得到的任务状态转换为只触发一次的状态跃迁事件。

import Foundation

struct TaskAttentionEvent: Equatable {
    let taskID: String
    let previousKind: TaskProgressKind?
    let item: TaskProgressItem

    var kind: TaskProgressKind { item.kind }
}

final class TaskAttentionTracker {
    private var knownKinds: [String: TaskProgressKind] = [:]
    private var hasEstablishedBaseline = false

    func update(with items: [TaskProgressItem]) -> [TaskAttentionEvent] {
        let identifiedItems = items.compactMap { item -> (String, TaskProgressItem)? in
            guard let taskID = taskAttentionIdentifier(for: item) else { return nil }
            return (taskID, item)
        }

        guard hasEstablishedBaseline else {
            for (taskID, item) in identifiedItems {
                knownKinds[taskID] = item.kind
            }
            hasEstablishedBaseline = true
            return []
        }

        var events: [TaskAttentionEvent] = []
        for (taskID, item) in identifiedItems {
            let previousKind = knownKinds[taskID]
            knownKinds[taskID] = item.kind
            guard previousKind != item.kind else { continue }

            if previousKind != nil || item.kind.requiresEntranceAttention {
                events.append(TaskAttentionEvent(
                    taskID: taskID,
                    previousKind: previousKind,
                    item: item
                ))
            }
        }
        return events
    }
}

func taskAttentionIdentifier(for item: TaskProgressItem) -> String? {
    if let target = item.target {
        if let threadID = target.threadID, !threadID.isEmpty {
            return "thread:\(threadID.lowercased())"
        }
        if !target.rolloutPath.isEmpty {
            return "rollout:\(target.rolloutPath)"
        }
    }

    guard item.kind != .reading, item.kind != .idle else { return nil }
    let normalizedTitle = item.title
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
        .lowercased()
    guard !normalizedTitle.isEmpty, item.startedAt != .distantPast else { return nil }
    return "local:\(item.startedAt.timeIntervalSinceReferenceDate.bitPattern):\(normalizedTitle)"
}

func dominantTaskProgressKind(in items: [TaskProgressItem]) -> TaskProgressKind {
    items.map(\.kind).max {
        taskAmbientPriority($0) < taskAmbientPriority($1)
    } ?? .idle
}

func taskAttentionPriority(_ kind: TaskProgressKind) -> Int {
    switch kind {
    case .failed:
        return 5
    case .waitingForInput:
        return 4
    case .completed:
        return 3
    case .running:
        return 2
    case .reading:
        return 1
    case .idle:
        return 0
    }
}

private func taskAmbientPriority(_ kind: TaskProgressKind) -> Int {
    switch kind {
    case .failed:
        return 5
    case .waitingForInput:
        return 4
    case .running:
        return 3
    case .reading:
        return 2
    case .completed:
        return 1
    case .idle:
        return 0
    }
}

func shouldAnimateTaskEffects(
    isWindowVisible: Bool,
    isWindowOccluded: Bool,
    reduceMotion: Bool
) -> Bool {
    isWindowVisible && !isWindowOccluded && !reduceMotion
}

private extension TaskProgressKind {
    var requiresEntranceAttention: Bool {
        switch self {
        case .waitingForInput, .completed, .failed:
            return true
        case .reading, .running, .idle:
            return false
        }
    }
}
