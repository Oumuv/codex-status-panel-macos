// Pi CLI 桥接状态读取，以及 Codex/Pi 任务结果的统一聚合。

import Darwin
import Foundation

private enum PiBridgeStatus: String, Decodable {
    case idle
    case running
    case waitingForInput
    case completed
    case failed
}

private struct PiBridgeState: Decodable {
    let schemaVersion: Int
    let source: String
    let pid: Int32
    let sessionId: String
    let sessionFile: String?
    let mode: String
    let cwd: String
    let title: String
    let status: PiBridgeStatus
    let startedAt: String
    let stateChangedAt: String
    let heartbeatAt: String
}

final class PiTaskProgressReader {
    private let fileManager: FileManager
    private let stateDirectoryURL: URL
    private let activeFreshness: TimeInterval
    private let terminalVisibility: TimeInterval
    private let maximumStateFileBytes = 65_536
    private let maximumCandidates = 128

    init(
        fileManager: FileManager = .default,
        stateDirectoryURL: URL? = nil,
        activeFreshness: TimeInterval = 20,
        terminalVisibility: TimeInterval = 2 * 60
    ) {
        self.fileManager = fileManager
        self.stateDirectoryURL = stateDirectoryURL
            ?? Self.defaultStateDirectoryURL(fileManager: fileManager)
        self.activeFreshness = activeFreshness
        self.terminalVisibility = terminalVisibility
    }

    func read(at now: Date = Date()) -> TaskProgressSnapshot {
        readResult(at: now).snapshot
    }

    func readResult(at now: Date = Date()) -> TaskProgressReadResult {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: stateDirectoryURL,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .fileSizeKey,
                .isRegularFileKey,
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return TaskProgressReadResult(allItems: [], snapshot: .idle)
        }

        let candidates = urls.compactMap { url -> (URL, Date)? in
            guard url.pathExtension == "json",
                  let values = try? url.resourceValues(forKeys: [
                      .contentModificationDateKey,
                      .fileSizeKey,
                      .isRegularFileKey,
                  ]),
                  values.isRegularFile == true,
                  let size = values.fileSize,
                  size > 0,
                  size <= maximumStateFileBytes,
                  let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) <= max(
                      activeFreshness,
                      terminalVisibility
                  ),
                  modified <= now.addingTimeInterval(5 * 60)
            else { return nil }
            return (url, modified)
        }.sorted { $0.1 > $1.1 }.prefix(maximumCandidates)

        let items = candidates.compactMap { candidate -> TaskProgressItem? in
            let url = candidate.0
            guard let data = try? Data(contentsOf: url) else { return nil }
            return Self.item(
                from: data,
                stateURL: url,
                now: now,
                activeFreshness: activeFreshness,
                terminalVisibility: terminalVisibility
            )
        }
        let sortedItems = sortedTaskProgressItems(items)
        return TaskProgressReadResult(
            allItems: sortedItems,
            snapshot: .displaying(sortedItems)
        )
    }

    static func item(
        from data: Data,
        stateURL: URL,
        now: Date,
        activeFreshness: TimeInterval = 20,
        terminalVisibility: TimeInterval = 2 * 60
    ) -> TaskProgressItem? {
        guard data.count <= 65_536,
              let state = try? JSONDecoder().decode(PiBridgeState.self, from: data),
              state.schemaVersion == 1,
              state.source == "pi",
              state.pid > 1,
              stateURL.deletingPathExtension().lastPathComponent
                  == String(state.pid),
              UUID(uuidString: state.sessionId) != nil,
              state.sessionId.utf8.count <= 128,
              ["tui", "rpc", "json", "print"].contains(state.mode),
              state.cwd.hasPrefix("/"),
              state.cwd.utf8.count <= 4_096,
              (state.sessionFile.map { sessionFile in
                  sessionFile.hasPrefix("/")
                      && sessionFile.utf8.count <= 4_096
              } ?? true),
              !state.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              state.title.count <= 80,
              let startedAt = parseDate(state.startedAt),
              let stateChangedAt = parseDate(state.stateChangedAt),
              let heartbeatAt = parseDate(state.heartbeatAt),
              startedAt <= now.addingTimeInterval(5 * 60),
              stateChangedAt <= now.addingTimeInterval(5 * 60),
              heartbeatAt <= now.addingTimeInterval(5 * 60)
        else { return nil }

        let kind: TaskProgressKind
        switch state.status {
        case .idle:
            return nil
        case .running:
            guard now.timeIntervalSince(heartbeatAt) <= activeFreshness else {
                return nil
            }
            kind = .running
        case .waitingForInput:
            guard now.timeIntervalSince(heartbeatAt) <= activeFreshness else {
                return nil
            }
            kind = .waitingForInput
        case .completed:
            guard now.timeIntervalSince(stateChangedAt) <= terminalVisibility else {
                return nil
            }
            kind = .completed
        case .failed:
            guard now.timeIntervalSince(stateChangedAt) <= terminalVisibility else {
                return nil
            }
            kind = .failed
        }

        let title = state.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let workingDirectory: String? = {
            guard !state.cwd.isEmpty else { return nil }
            return URL(fileURLWithPath: state.cwd).standardizedFileURL.path
        }()
        let sessionFile = state.sessionFile?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let rolloutPath = sessionFile?.isEmpty == false
            ? sessionFile!
            : stateURL.path
        let stableID = "\(state.sessionId):\(state.pid)"

        return TaskProgressItem(
            title: "π \(title)",
            kind: kind,
            startedAt: startedAt,
            source: .pi,
            taskID: stableID,
            target: TaskProgressTarget(
                threadID: state.sessionId,
                client: .pi,
                workingDirectory: workingDirectory,
                rolloutPath: rolloutPath,
                processID: pid_t(state.pid)
            )
        )
    }

    private static func defaultStateDirectoryURL(
        fileManager: FileManager
    ) -> URL {
        if let override = ProcessInfo.processInfo.environment[
            "CODEX_STATUS_PANEL_PI_STATE_DIR"
        ], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/"
                    + defaultBundleIdentifier
                    + "/pi-sessions",
                isDirectory: true
            )
    }

    private static func parseDate(_ value: String) -> Date? {
        iso8601WithFractional.date(from: value) ?? iso8601.date(from: value)
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

final class CombinedTaskProgressReader {
    private let codexReader: CodexTaskProgressReader
    private let piReader: PiTaskProgressReader

    init(
        codexReader: CodexTaskProgressReader = CodexTaskProgressReader(),
        piReader: PiTaskProgressReader = PiTaskProgressReader()
    ) {
        self.codexReader = codexReader
        self.piReader = piReader
    }

    func read(at now: Date = Date()) -> TaskProgressSnapshot {
        readResult(at: now).snapshot
    }

    func readResult(at now: Date = Date()) -> TaskProgressReadResult {
        let codexResult = codexReader.readResult(at: now)
        let piResult = piReader.readResult(at: now)
        return Self.merged([codexResult, piResult])
    }

    static func merged(
        _ results: [TaskProgressReadResult]
    ) -> TaskProgressReadResult {
        let items = sortedTaskProgressItems(results.flatMap(\.allItems))
        return TaskProgressReadResult(
            allItems: items,
            snapshot: .displaying(items)
        )
    }
}
