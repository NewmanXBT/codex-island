//
//  WindowFocuser.swift
//  ClaudeIsland
//
//  Focuses windows using yabai
//

import Foundation

/// Focuses windows using yabai
actor WindowFocuser {
    static let shared = WindowFocuser()

    private init() {}

    /// Focus a window by ID
    func focusWindow(id: Int) async -> Bool {
        guard let yabaiPath = await WindowFinder.shared.getYabaiPath() else { return false }

        do {
            _ = try await ProcessExecutor.shared.run(yabaiPath, arguments: [
                "-m", "window", "--focus", String(id)
            ])
            return true
        } catch {
            return false
        }
    }

    /// Focus the tmux window for a terminal
    func focusTmuxWindow(terminalPid: Int, windows: [YabaiWindow]) async -> Bool {
        // Try to find actual tmux window
        if let tmuxWindow = WindowFinder.shared.findTmuxWindow(forTerminalPid: terminalPid, windows: windows) {
            return await focusWindow(id: tmuxWindow.id)
        }

        // Fall back to any non-Claude window
        if let window = WindowFinder.shared.findNonClaudeWindow(forTerminalPid: terminalPid, windows: windows) {
            return await focusWindow(id: window.id)
        }

        return false
    }

    /// Focus any visible window owned by a terminal process
    func focusTerminalWindow(terminalPid: Int, windows: [YabaiWindow]) async -> Bool {
        if let focusedWindow = windows.first(where: { $0.pid == terminalPid && $0.hasFocus }) {
            return await focusWindow(id: focusedWindow.id)
        }

        if let visibleWindow = windows.first(where: { $0.pid == terminalPid && $0.isVisible }) {
            return await focusWindow(id: visibleWindow.id)
        }

        if let anyWindow = windows.first(where: { $0.pid == terminalPid }) {
            return await focusWindow(id: anyWindow.id)
        }

        return false
    }
}
