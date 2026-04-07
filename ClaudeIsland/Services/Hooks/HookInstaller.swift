//
//  HookInstaller.swift
//  ClaudeIsland
//
//  Auto-installs Claude Code and Codex hooks on app launch
//

import Foundation

struct HookInstaller {
    private static let fileManager = FileManager.default
    private static let claudeScriptName = "claude-island-state.py"

    /// Install hook scripts and update provider configs on app launch.
    static func installIfNeeded() {
        installClaudeHooksIfNeeded()
        installCodexHooksIfNeeded()
    }

    static func installClaudeHooksIfNeeded() {
        let claudeDir = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let hooksDir = claudeDir.appendingPathComponent("hooks")
        let pythonScript = hooksDir.appendingPathComponent(claudeScriptName)
        let settings = claudeDir.appendingPathComponent("settings.json")

        installBundledScript(at: pythonScript, hooksDir: hooksDir)
        updateClaudeSettings(at: settings, scriptPath: pythonScript.path)
    }

    static func installCodexHooksIfNeeded() {
        let codexDir = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let hooksDir = codexDir.appendingPathComponent("hooks")
        let pythonScript = hooksDir.appendingPathComponent(claudeScriptName)
        let hooksConfig = codexDir.appendingPathComponent("hooks.json")

        installBundledScript(at: pythonScript, hooksDir: hooksDir)
        updateCodexHooks(at: hooksConfig, scriptPath: pythonScript.path)
    }

    /// Check if Claude hooks are currently installed.
    static func isInstalled() -> Bool {
        isClaudeInstalled()
    }

    static func isClaudeInstalled() -> Bool {
        let claudeDir = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let settings = claudeDir.appendingPathComponent("settings.json")
        return hasHookCommand(in: settings, scriptName: claudeScriptName)
    }

    static func isCodexInstalled() -> Bool {
        let codexDir = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let hooksConfig = codexDir.appendingPathComponent("hooks.json")
        return hasHookCommand(in: hooksConfig, scriptName: claudeScriptName)
    }

    /// Uninstall hooks from provider configs and remove scripts.
    static func uninstall() {
        uninstallClaudeHooks()
        uninstallCodexHooks()
    }

    static func uninstallClaudeHooks() {
        let claudeDir = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let hooksDir = claudeDir.appendingPathComponent("hooks")
        let pythonScript = hooksDir.appendingPathComponent(claudeScriptName)
        let settings = claudeDir.appendingPathComponent("settings.json")

        try? fileManager.removeItem(at: pythonScript)
        removeHookCommand(from: settings, scriptName: claudeScriptName)
    }

    static func uninstallCodexHooks() {
        let codexDir = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let hooksDir = codexDir.appendingPathComponent("hooks")
        let pythonScript = hooksDir.appendingPathComponent(claudeScriptName)
        let hooksConfig = codexDir.appendingPathComponent("hooks.json")

        try? fileManager.removeItem(at: pythonScript)
        removeHookCommand(from: hooksConfig, scriptName: claudeScriptName)
    }

    private static func installBundledScript(at scriptURL: URL, hooksDir: URL) {
        try? fileManager.createDirectory(at: hooksDir, withIntermediateDirectories: true)

        guard let bundled = Bundle.main.url(forResource: "claude-island-state", withExtension: "py") else {
            return
        }

        try? fileManager.removeItem(at: scriptURL)
        try? fileManager.copyItem(at: bundled, to: scriptURL)
        try? fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
    }

    private static func updateClaudeSettings(at settingsURL: URL, scriptPath: String) {
        var json = loadJSONObject(at: settingsURL)
        var hooks = json["hooks"] as? [String: Any] ?? [:]

        let command = "\(detectPython()) \(scriptPath)"
        let hookEntry: [[String: Any]] = [["type": "command", "command": command]]
        let hookEntryWithTimeout: [[String: Any]] = [["type": "command", "command": command, "timeout": 86400]]
        let withMatcher: [[String: Any]] = [["matcher": "*", "hooks": hookEntry]]
        let withMatcherAndTimeout: [[String: Any]] = [["matcher": "*", "hooks": hookEntryWithTimeout]]
        let withoutMatcher: [[String: Any]] = [["hooks": hookEntry]]
        let preCompactConfig: [[String: Any]] = [
            ["matcher": "auto", "hooks": hookEntry],
            ["matcher": "manual", "hooks": hookEntry]
        ]

        let hookEvents: [(String, [[String: Any]])] = [
            ("UserPromptSubmit", withoutMatcher),
            ("PreToolUse", withMatcher),
            ("PostToolUse", withMatcher),
            ("PermissionRequest", withMatcherAndTimeout),
            ("Notification", withMatcher),
            ("Stop", withoutMatcher),
            ("SubagentStop", withoutMatcher),
            ("SessionStart", withoutMatcher),
            ("SessionEnd", withoutMatcher),
            ("PreCompact", preCompactConfig),
        ]

        for (event, config) in hookEvents {
            hooks[event] = upserting(command: command, into: hooks[event], fallback: config)
        }

        json["hooks"] = hooks
        writeJSONObject(json, to: settingsURL)
    }

    private static func updateCodexHooks(at hooksURL: URL, scriptPath: String) {
        var json = loadJSONObject(at: hooksURL)
        var hooks = json["hooks"] as? [String: Any] ?? [:]
        let command = "\(detectPython()) \(scriptPath)"
        let hookEntry: [[String: Any]] = [["type": "command", "command": command]]
        let withMatcher: [[String: Any]] = [["matcher": "*", "hooks": hookEntry]]
        let withoutMatcher: [[String: Any]] = [["hooks": hookEntry]]

        let hookEvents: [(String, [[String: Any]])] = [
            ("SessionStart", withoutMatcher),
            ("UserPromptSubmit", withoutMatcher),
            ("PreToolUse", withMatcher),
            ("PostToolUse", withMatcher),
            ("Stop", withoutMatcher),
        ]

        for (event, config) in hookEvents {
            hooks[event] = upserting(command: command, into: hooks[event], fallback: config)
        }

        json["hooks"] = hooks
        writeJSONObject(json, to: hooksURL)
    }

    private static func upserting(command: String, into existing: Any?, fallback: [[String: Any]]) -> [[String: Any]] {
        var entries = existing as? [[String: Any]] ?? []
        let hasOurHook = entries.contains { entry in
            guard let entryHooks = entry["hooks"] as? [[String: Any]] else { return false }
            return entryHooks.contains { ($0["command"] as? String) == command }
        }

        if !hasOurHook {
            entries.append(contentsOf: fallback)
        }

        return entries
    }

    private static func hasHookCommand(in configURL: URL, scriptName: String) -> Bool {
        let json = loadJSONObject(at: configURL)
        return containsHookCommand(in: json, scriptName: scriptName)
    }

    private static func removeHookCommand(from configURL: URL, scriptName: String) {
        var json = loadJSONObject(at: configURL)

        for key in Array(json.keys) {
            let value = json[key]
            guard var entries = value as? [[String: Any]] else {
                if key == "hooks", var hookMap = value as? [String: Any] {
                    pruneHookMap(&hookMap, scriptName: scriptName)
                    if hookMap.isEmpty {
                        json.removeValue(forKey: key)
                    } else {
                        json[key] = hookMap
                    }
                }
                continue
            }

            pruneEntries(&entries, scriptName: scriptName)
            if entries.isEmpty {
                json.removeValue(forKey: key)
            } else {
                json[key] = entries
            }
        }

        writeJSONObject(json, to: configURL)
    }

    private static func containsHookCommand(in json: [String: Any], scriptName: String) -> Bool {
        if let hooks = json["hooks"] as? [String: Any] {
            for (_, value) in hooks {
                if let entries = value as? [[String: Any]], entriesContainScript(entries, scriptName: scriptName) {
                    return true
                }
            }
        }

        for (_, value) in json {
            if let entries = value as? [[String: Any]], entriesContainScript(entries, scriptName: scriptName) {
                return true
            }
        }

        return false
    }

    private static func pruneHookMap(_ hooks: inout [String: Any], scriptName: String) {
        for event in Array(hooks.keys) {
            let value = hooks[event]
            guard var entries = value as? [[String: Any]] else { continue }
            pruneEntries(&entries, scriptName: scriptName)
            if entries.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = entries
            }
        }
    }

    private static func pruneEntries(_ entries: inout [[String: Any]], scriptName: String) {
        entries.removeAll { entry in
            guard let entryHooks = entry["hooks"] as? [[String: Any]] else { return false }
            return entryHooks.contains { hook in
                let command = hook["command"] as? String ?? ""
                return command.contains(scriptName)
            }
        }
    }

    private static func entriesContainScript(_ entries: [[String: Any]], scriptName: String) -> Bool {
        entries.contains { entry in
            guard let entryHooks = entry["hooks"] as? [[String: Any]] else { return false }
            return entryHooks.contains { hook in
                let command = hook["command"] as? String ?? ""
                return command.contains(scriptName)
            }
        }
    }

    private static func loadJSONObject(at url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }

        return existing
    }

    private static func writeJSONObject(_ json: [String: Any], to url: URL) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            return
        }

        try? data.write(to: url)
    }

    private static func detectPython() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["python3"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return "python3"
            }
        } catch {}

        return "python"
    }
}
