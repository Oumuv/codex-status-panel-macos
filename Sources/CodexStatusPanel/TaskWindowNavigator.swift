// 按会话来源和当前进程宿主定位任务；定位失败时禁止跨工具回退。

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
            if target.client == .pi {
                self?.openPiCLI(target)
            } else {
                self?.openCodexTask(target)
            }
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
            // /dev/tty 是通用控制终端设备，不是可用于匹配窗口的具体 TTY。
            guard line.hasPrefix("n/dev/ttys"), line.count > "n/dev/ttys".count else { continue }
            return String(line.dropFirst())
        }
        return nil
    }

    static func fallbackApplicationBundleIdentifier(for client: CodexTaskClient) -> String? {
        switch client {
        case .orca: return "com.stablyai.orca"
        case .t3: return "com.t3tools.t3code"
        default: return nil
        }
    }

    static func hostBundleIdentifier(forExecutablePath path: String) -> String? {
        // Orca 的 terminal-host 是独立 daemon，父进程可能已是 launchd，且没有 TTY。
        if path.contains("/Orca Agents.app/Contents/MacOS/") {
            return "com.stablyai.orca"
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

    private func openPiCLI(_ target: TaskProgressTarget) {
        guard let processID = target.processID, processID > 1 else {
            fputs("task-navigation: Pi 任务缺少有效进程 ID，无法定位终端\n", stderr)
            return
        }
        guard focusProcess(
            processID: processID,
            workingDirectory: target.workingDirectory
        ) else {
            fputs(
                "task-navigation: 无法定位 Pi 进程 \(processID) 所在的终端窗口\n",
                stderr
            )
            return
        }
    }

    private func openCodexTask(_ target: TaskProgressTarget) {
        let processIDs = codexProcessIDs(for: target.rolloutPath)
        for processID in processIDs {
            if focusProcess(
                processID: processID,
                workingDirectory: target.workingDirectory
            ) {
                return
            }
        }

        if let bundleID = Self.fallbackApplicationBundleIdentifier(for: target.client),
                  let application = runningApplication(bundleIdentifier: bundleID) {
            activate(application)
            reportApplicationOnlyNavigation()
        } else {
            fputs("task-navigation: 无法定位 \(target.client.rawValue) 任务的原窗口；未回退到其他工具\n", stderr)
        }
    }

    private func focusProcess(
        processID: pid_t,
        workingDirectory: String?
    ) -> Bool {
        if let owner = owningApplication(for: processID) {
            let kind = Self.terminalKind(forBundleIdentifier: owner.bundleIdentifier ?? "")
            // GUI app-server 没有 TTY 也应回到其宿主，不应改开 Codex App。
            guard kind != .other else {
                activate(owner)
                reportApplicationOnlyNavigation()
                return true
            }
            guard let tty = tty(for: processID) else {
                activate(owner)
                reportApplicationOnlyNavigation()
                return true
            }
            focus(
                terminalKind: kind,
                application: owner,
                tty: tty,
                workingDirectory: workingDirectory
            )
            return true
        }

        guard let tty = tty(for: processID) else { return false }
        return focusKnownTerminal(
            tty: tty,
            workingDirectory: workingDirectory
        )
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
        if result.status == 0, let tty = Self.tty(fromLsofOutput: result.output) { return tty }
        let psResult = runCommand(executable: "/bin/ps", arguments: ["-o", "tty=", "-p", String(processID)])
        let name = psResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard psResult.status == 0, name.hasPrefix("ttys"),
              name.dropFirst(4).allSatisfy(\.isNumber), name.count > 4 else { return nil }
        return "/dev/" + name
    }

    private func owningApplication(for processID: pid_t) -> NSRunningApplication? {
        var currentPID = processID
        var visited = Set<pid_t>()

        for _ in 0..<16 where currentPID > 1 && visited.insert(currentPID).inserted {
            if let path = executablePath(of: currentPID),
               let hostID = Self.hostBundleIdentifier(forExecutablePath: path),
               let host = runningApplication(bundleIdentifier: hostID) {
                return host
            }
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

    private func executablePath(of processID: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE 是 Swift 不导入的复合 C 宏 (4 * MAXPATHLEN)。
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(processID, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    private func reportApplicationOnlyNavigation() {
        fputs("task-navigation: 仅激活已确认的宿主 App；尚未定位具体任务标签页\n", stderr)
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
            reportApplicationOnlyNavigation()
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
                reportApplicationOnlyNavigation()
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
