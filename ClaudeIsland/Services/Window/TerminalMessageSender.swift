//
//  TerminalMessageSender.swift
//  ClaudeIsland
//
//  Sends input to live non-tmux terminal sessions.
//

import AppKit
import Foundation

actor TerminalMessageSender {
    static let shared = TerminalMessageSender()

    private init() {}

    func sendMessage(_ message: String, to session: SessionState) async -> Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let resolvedProcess = ProcessTreeBuilder.shared.activeCodexProcess(for: session)
        let terminal = terminalTarget(for: session, resolvedProcess: resolvedProcess)
        let resolvedTTY = session.tty ?? resolvedProcess?.tty

        if let tty = resolvedTTY,
           sendViaTTY(trimmed, tty: tty) {
            return true
        }

        if let terminal,
           let tty = resolvedTTY,
           await sendDirectMessage(trimmed, to: terminal, tty: tty) {
            return true
        }

        let focusedWindow: Bool
        if let pid = resolvedProcess?.pid ?? session.pid {
            focusedWindow = await YabaiController.shared.focusWindow(forClaudePid: pid)
        } else {
            focusedWindow = await YabaiController.shared.focusWindow(forWorkingDirectory: session.cwd)
        }

        if let terminal {
            terminal.application.activate()
        } else if !focusedWindow {
            return false
        }
        try? await Task.sleep(for: .milliseconds(220))

        if let terminal {
            return await sendWithSystemEvents(trimmed, to: terminal)
        }
        return await sendWithSystemEvents(trimmed)
    }

    private nonisolated func terminalTarget(for session: SessionState, resolvedProcess: ActiveCodexProcess?) -> TerminalTarget? {
        let pid = resolvedProcess?.pid ?? session.pid
        guard let pid else { return nil }

        let tree = ProcessTreeBuilder.shared.buildTree()
        guard let terminalPid = ProcessTreeBuilder.shared.findTerminalPid(forProcess: pid, tree: tree),
              let application = NSRunningApplication(processIdentifier: pid_t(terminalPid)),
              let bundleIdentifier = application.bundleIdentifier else {
            return nil
        }

        return TerminalTarget(
            bundleIdentifier: bundleIdentifier,
            application: application
        )
    }

    private func sendDirectMessage(_ message: String, to target: TerminalTarget, tty: String) async -> Bool {
        let normalizedTTY = Self.normalizeTTY(tty)

        switch target.bundleIdentifier {
        case "com.apple.Terminal":
            return await runAppleScript(Self.terminalScript, arguments: [normalizedTTY, message])
        case "com.googlecode.iterm2":
            return await runAppleScript(Self.iTermScript, arguments: [normalizedTTY, message])
        default:
            return false
        }
    }

    private func sendWithSystemEvents(_ message: String, to target: TerminalTarget) async -> Bool {
        await runAppleScript(Self.systemEventsScript, arguments: [target.bundleIdentifier, message])
    }

    private func sendWithSystemEvents(_ message: String) async -> Bool {
        await runAppleScript(Self.genericSystemEventsScript, arguments: [message])
    }

    private func runAppleScript(_ script: String, arguments: [String]) async -> Bool {
        let result = await ProcessExecutor.shared.runWithResult(
            "/usr/bin/osascript",
            arguments: ["-e", script] + arguments
        )

        switch result {
        case .success(let output):
            return output.exitCode == 0
        case .failure:
            return false
        }
    }

    private struct TerminalTarget {
        let bundleIdentifier: String
        let application: NSRunningApplication
    }

    private nonisolated static func normalizeTTY(_ tty: String) -> String {
        let trimmed = tty.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/dev/") {
            return String(trimmed.dropFirst(5))
        }
        return trimmed
    }

    private nonisolated func sendViaTTY(_ message: String, tty: String) -> Bool {
        let normalizedTTY = Self.normalizeTTY(tty)
        let deviceURL = URL(fileURLWithPath: "/dev/\(normalizedTTY)")

        guard FileManager.default.isWritableFile(atPath: deviceURL.path),
              let data = "\(message)\n".data(using: .utf8) else {
            return false
        }

        do {
            let handle = try FileHandle(forWritingTo: deviceURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            return true
        } catch {
            return false
        }
    }

    private static let terminalScript = """
    on run argv
        set targetTTY to item 1 of argv
        set targetMessage to item 2 of argv
        tell application id "com.apple.Terminal"
            repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                    try
                        set ttyValue to tty of aTab
                        if ttyValue is targetTTY or ttyValue is "/dev/" & targetTTY then
                            do script targetMessage in aTab
                            return "ok"
                        end if
                    end try
                end repeat
            end repeat
        end tell
        return "not_found"
    end run
    """

    private static let iTermScript = """
    on run argv
        set targetTTY to item 1 of argv
        set targetMessage to item 2 of argv
        tell application id "com.googlecode.iterm2"
            repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                    repeat with aSession in sessions of aTab
                        try
                            set ttyValue to tty of aSession
                            if ttyValue is targetTTY or ttyValue is "/dev/" & targetTTY then
                                tell aSession to write text targetMessage
                                return "ok"
                            end if
                        end try
                    end repeat
                end repeat
            end repeat
        end tell
        return "not_found"
    end run
    """

    private static let systemEventsScript = """
    on run argv
        set targetBundleId to item 1 of argv
        set targetMessage to item 2 of argv
        tell application id targetBundleId to activate
        delay 0.15
        tell application "System Events"
            keystroke targetMessage
            key code 36
        end tell
        return "ok"
    end run
    """

    private static let genericSystemEventsScript = """
    on run argv
        set targetMessage to item 1 of argv
        tell application "System Events"
            keystroke targetMessage
            key code 36
        end tell
        return "ok"
    end run
    """
}
