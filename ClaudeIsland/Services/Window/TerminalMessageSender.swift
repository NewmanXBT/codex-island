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

        guard let terminal = terminalTarget(for: session) else { return false }

        if let tty = session.tty, await sendDirectMessage(trimmed, to: terminal, tty: tty) {
            return true
        }

        let focused: Bool
        if let pid = session.pid {
            focused = await YabaiController.shared.focusWindow(forClaudePid: pid)
        } else {
            focused = await YabaiController.shared.focusWindow(forWorkingDirectory: session.cwd)
        }

        guard focused else { return false }

        terminal.application.activate(options: [.activateIgnoringOtherApps])
        try? await Task.sleep(for: .milliseconds(120))

        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == terminal.bundleIdentifier else {
            return false
        }

        return await sendWithSystemEvents(trimmed)
    }

    private func terminalTarget(for session: SessionState) -> TerminalTarget? {
        guard let pid = session.pid else { return nil }

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
        switch target.bundleIdentifier {
        case "com.apple.Terminal":
            return await runAppleScript(Self.terminalScript, arguments: [tty, message])
        case "com.googlecode.iterm2":
            return await runAppleScript(Self.iTermScript, arguments: [tty, message])
        default:
            return false
        }
    }

    private func sendWithSystemEvents(_ message: String) async -> Bool {
        await runAppleScript(Self.systemEventsScript, arguments: [message])
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

    private static let terminalScript = """
    on run argv
        set targetTTY to item 1 of argv
        set targetMessage to item 2 of argv
        tell application id "com.apple.Terminal"
            repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                    try
                        if tty of aTab is targetTTY then
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
                            if tty of aSession is targetTTY then
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
        set targetMessage to item 1 of argv
        tell application "System Events"
            keystroke targetMessage
            key code 36
        end tell
        return "ok"
    end run
    """
}
