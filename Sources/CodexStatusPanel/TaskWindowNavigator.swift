// 将任务面板中的 rollout 定位到 Codex App 或承载 Codex CLI 的终端窗口。

import AppKit
import Darwin
import Foundation

enum TaskTerminalKind: Equatable {
    case terminal
    case iTerm2
    case ghostty
    case other
}

final class TaskWindowNavigator {
    private struct CommandResult {
        let status: Int32
        let output: String
    }

    func open(_ target: TaskProgressTarget) {
        if target.client == .app {
            openInCodexApp(target)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.openCLIOrFallback(target)
        }
    }

    static func codexDeepLink(threadID: String?) -> URL? {
        guard let threadID,
              UUID(uuidString: threadID) != nil
        else { return nil }
        return URL(string: "codex://threads/\(threadID.lowercased())")
    }

    static func processIDs(
        fromLsofOutput output: String,
        rolloutPath: String
    ) -> [pid_t] {
        var currentPID: pid_t?
        var result: [pid_t] = []
        var seen = Set<pid_t>()

        for line in output.split(whereSeparator: \.isNewline) {
            if line.first == "p" {
                currentPID = pid_t(line.dropFirst())
                continue
            }
            guard line.first == "n",
                  line.dropFirst() == rolloutPath[...],
                  let currentPID,
                  seen.insert(currentPID).inserted
            else { continue }
            result.append(currentPID)
        }
        return result
    }

    static func tty(fromLsofOutput output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("n/dev/tty") else { continue }
            return String(line.dropFirst())
        }
        return nil
    }

    static func terminalKind(forBundleIdentifier bundleIdentifier: String) -> TaskTerminalKind {
        switch bundleIdentifier.lowercased() {
        case "com.apple.terminal":
            return .terminal
        case "com.googlecode.iterm2":
            return .iTerm2
        case "com.mitchellh.ghostty":
            return .ghostty
        default:
            return .other
        }
    }

    static func appleScriptResult(from output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2,
              trimmed.first == "\"",
              trimmed.last == "\""
        else { return trimmed }
        return String(trimmed.dropFirst().dropLast())
    }

    private func openCLIOrFallback(_ target: TaskProgressTarget) {
        let processIDs = codexProcessIDs(for: target.rolloutPath)
        guard !processIDs.isEmpty else {
            openInCodexApp(target)
            return
        }

        for processID in processIDs {
            guard let tty = tty(for: processID) else { continue }
            if let owner = owningApplication(for: processID) {
                focus(
                    terminalKind: Self.terminalKind(
                        forBundleIdentifier: owner.bundleIdentifier ?? ""
                    ),
                    application: owner,
                    tty: tty,
                    workingDirectory: target.workingDirectory
                )
                return
            }

            if focusKnownTerminal(
                tty: tty,
                workingDirectory: target.workingDirectory
            ) {
                return
            }
        }

        openInCodexApp(target)
    }

    private func codexProcessIDs(for rolloutPath: String) -> [pid_t] {
        let result = runCommand(
            executable: "/usr/sbin/lsof",
            arguments: ["-a", "-c", "codex", "-Fpn", "--", rolloutPath]
        )
        guard result.status == 0 else { return [] }
        return Self.processIDs(
            fromLsofOutput: result.output,
            rolloutPath: rolloutPath
        )
    }

    private func tty(for processID: pid_t) -> String? {
        let result = runCommand(
            executable: "/usr/sbin/lsof",
            arguments: ["-a", "-p", String(processID), "-Fn"]
        )
        guard result.status == 0 else { return nil }
        return Self.tty(fromLsofOutput: result.output)
    }

    private func owningApplication(for processID: pid_t) -> NSRunningApplication? {
        var currentPID = processID
        var visited = Set<pid_t>()

        for _ in 0..<16 where currentPID > 1 && visited.insert(currentPID).inserted {
            if let application = NSRunningApplication(processIdentifier: currentPID),
               let bundleIdentifier = application.bundleIdentifier,
               bundleIdentifier != Bundle.main.bundleIdentifier
            {
                return application
            }
            guard let parentPID = parentProcessID(of: currentPID) else { break }
            currentPID = parentPID
        }
        return nil
    }

    private func parentProcessID(of processID: pid_t) -> pid_t? {
        let result = runCommand(
            executable: "/bin/ps",
            arguments: ["-o", "ppid=", "-p", String(processID)]
        )
        guard result.status == 0 else { return nil }
        return pid_t(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func focus(
        terminalKind: TaskTerminalKind,
        application: NSRunningApplication,
        tty: String,
        workingDirectory: String?
    ) {
        let focused: Bool
        switch terminalKind {
        case .terminal:
            focused = runAppleScript(Self.terminalScript, argument: tty) == "focused"
        case .iTerm2:
            focused = runAppleScript(Self.iTerm2Script, argument: tty) == "focused"
        case .ghostty:
            focused = workingDirectory.map {
                runAppleScript(Self.ghosttyScript, argument: $0) == "focused"
            } ?? false
        case .other:
            focused = false
        }

        if !focused {
            activate(application)
        }
    }

    private func focusKnownTerminal(
        tty: String,
        workingDirectory: String?
    ) -> Bool {
        if runningApplication(bundleIdentifier: "com.apple.Terminal") != nil,
           runAppleScript(Self.terminalScript, argument: tty) == "focused"
        {
            return true
        }
        if runningApplication(bundleIdentifier: "com.googlecode.iterm2") != nil,
           runAppleScript(Self.iTerm2Script, argument: tty) == "focused"
        {
            return true
        }
        if let ghostty = runningApplication(
            bundleIdentifier: "com.mitchellh.ghostty"
        ),
        let workingDirectory
        {
            let result = runAppleScript(
                Self.ghosttyScript,
                argument: workingDirectory
            )
            if result == "focused" { return true }
            if result == "ambiguous" {
                activate(ghostty)
                return true
            }
        }
        return false
    }

    private func openInCodexApp(_ target: TaskProgressTarget) {
        guard let url = Self.codexDeepLink(threadID: target.threadID) else {
            fputs("task-navigation: 任务缺少有效 thread ID，无法打开\n", stderr)
            return
        }
        DispatchQueue.main.async {
            if !NSWorkspace.shared.open(url) {
                fputs("task-navigation: Codex App 无法打开 \(url.absoluteString)\n", stderr)
            }
        }
    }

    private func runningApplication(bundleIdentifier: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).first
    }

    private func activate(_ application: NSRunningApplication) {
        DispatchQueue.main.async {
            if !application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps]) {
                fputs("task-navigation: 无法激活终端应用\n", stderr)
            }
        }
    }

    private func runAppleScript(_ script: String, argument: String) -> String? {
        let result = runCommand(
            executable: "/usr/bin/osascript",
            arguments: ["-e", script, "--", argument]
        )
        guard result.status == 0 else {
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            fputs("task-navigation: 终端自动化失败：\(detail)\n", stderr)
            return nil
        }
        return Self.appleScriptResult(from: result.output)
    }

    private func runCommand(
        executable: String,
        arguments: [String]
    ) -> CommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return CommandResult(
                status: -1,
                output: "\(executable): \(error.localizedDescription)"
            )
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(
            status: process.terminationStatus,
            output: String(data: data, encoding: .utf8) ?? ""
        )
    }

    private static let terminalScript = """
    on run argv
        set targetTTY to item 1 of argv
        tell application "Terminal"
            repeat with candidateWindow in windows
                repeat with candidateTab in tabs of candidateWindow
                    if tty of candidateTab is targetTTY then
                        set selected of candidateTab to true
                        set index of candidateWindow to 1
                        activate
                        return "focused"
                    end if
                end repeat
            end repeat
        end tell
        return "missing"
    end run
    """

    private static let iTerm2Script = """
    on run argv
        set targetTTY to item 1 of argv
        tell application "iTerm2"
            repeat with candidateWindow in windows
                repeat with candidateTab in tabs of candidateWindow
                    repeat with candidateSession in sessions of candidateTab
                        if tty of candidateSession is targetTTY then
                            select candidateSession
                            select candidateTab
                            select candidateWindow
                            activate
                            return "focused"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "missing"
    end run
    """

    private static let ghosttyScript = """
    on run argv
        set targetDirectory to item 1 of argv
        set matchedTerminals to {}
        tell application "Ghostty"
            repeat with candidateTerminal in terminals
                if working directory of candidateTerminal is targetDirectory then
                    set end of matchedTerminals to candidateTerminal
                end if
            end repeat
            if (count of matchedTerminals) is 1 then
                focus item 1 of matchedTerminals
                return "focused"
            end if
            if (count of matchedTerminals) is greater than 1 then
                return "ambiguous"
            end if
        end tell
        return "missing"
    end run
    """
}
