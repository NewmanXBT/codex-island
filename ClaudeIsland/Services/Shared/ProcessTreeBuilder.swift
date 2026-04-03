//
//  ProcessTreeBuilder.swift
//  ClaudeIsland
//
//  Builds and queries process trees using ps command
//

import Foundation

/// Information about a process in the tree
struct ProcessInfo: Sendable {
    let pid: Int
    let ppid: Int
    let command: String
    let tty: String?

    nonisolated init(pid: Int, ppid: Int, command: String, tty: String?) {
        self.pid = pid
        self.ppid = ppid
        self.command = command
        self.tty = tty
    }
}

/// Builds and queries the system process tree
struct ProcessTreeBuilder: Sendable {
    nonisolated static let shared = ProcessTreeBuilder()

    private nonisolated init() {}

    /// Build a process tree mapping PID -> ProcessInfo
    nonisolated func buildTree() -> [Int: ProcessInfo] {
        guard let output = ProcessExecutor.shared.runSyncOrNil("/bin/ps", arguments: ["-eo", "pid,ppid,tty,comm"]) else {
            return [:]
        }

        var tree: [Int: ProcessInfo] = [:]

        for line in output.components(separatedBy: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces)
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }

            guard parts.count >= 4,
                  let pid = Int(parts[0]),
                  let ppid = Int(parts[1]) else { continue }

            let tty = parts[2] == "??" ? nil : parts[2]
            let command = parts[3...].joined(separator: " ")

            tree[pid] = ProcessInfo(pid: pid, ppid: ppid, command: command, tty: tty)
        }

        return tree
    }

    /// Check if a process has tmux in its parent chain
    nonisolated func isInTmux(pid: Int, tree: [Int: ProcessInfo]) -> Bool {
        var current = pid
        var depth = 0

        while current > 1 && depth < 20 {
            guard let info = tree[current] else { break }
            if info.command.lowercased().contains("tmux") {
                return true
            }
            current = info.ppid
            depth += 1
        }

        return false
    }

    /// Walk up the process tree to find the terminal app PID
    nonisolated func findTerminalPid(forProcess pid: Int, tree: [Int: ProcessInfo]) -> Int? {
        var current = pid
        var depth = 0

        while current > 1 && depth < 20 {
            guard let info = tree[current] else { break }

            if TerminalAppRegistry.isTerminal(info.command) {
                return current
            }

            current = info.ppid
            depth += 1
        }

        return nil
    }

    /// Check if targetPid is a descendant of ancestorPid
    nonisolated func isDescendant(targetPid: Int, ofAncestor ancestorPid: Int, tree: [Int: ProcessInfo]) -> Bool {
        var current = targetPid
        var depth = 0

        while current > 1 && depth < 50 {
            if current == ancestorPid {
                return true
            }
            guard let info = tree[current] else { break }
            current = info.ppid
            depth += 1
        }

        return false
    }

    /// Find all descendant PIDs of a given process
    nonisolated func findDescendants(of pid: Int, tree: [Int: ProcessInfo]) -> Set<Int> {
        var descendants: Set<Int> = []
        var queue = [pid]

        while !queue.isEmpty {
            let current = queue.removeFirst()
            for (childPid, info) in tree where info.ppid == current {
                if !descendants.contains(childPid) {
                    descendants.insert(childPid)
                    queue.append(childPid)
                }
            }
        }

        return descendants
    }

    /// Get working directory for a process using lsof
    nonisolated func getWorkingDirectory(forPid pid: Int) -> String? {
        guard let output = ProcessExecutor.shared.runSyncOrNil("/usr/sbin/lsof", arguments: ["-p", String(pid), "-Fn"]) else {
            return nil
        }

        var foundCwd = false
        for line in output.components(separatedBy: "\n") {
            if line == "fcwd" {
                foundCwd = true
            } else if foundCwd && line.hasPrefix("n") {
                return String(line.dropFirst())
            }
        }

        return nil
    }

    /// Count live Codex CLI processes by working directory.
    /// This is used as a fallback liveness signal for Codex sessions, which do not
    /// currently emit a reliable explicit session-ended event into Claude Island.
    nonisolated func activeCodexProcessCountsByWorkingDirectory() -> [String: Int] {
        let tree = buildTree()
        let codexPids = tree.values.compactMap { info -> Int? in
            let executable = info.command
                .split(separator: " ")
                .first
                .map(String.init)?
                .split(separator: "/")
                .last
                .map(String.init)?
                .lowercased()

            return executable == "codex" ? info.pid : nil
        }

        var counts: [String: Int] = [:]
        for pid in codexPids {
            guard let cwd = getWorkingDirectory(forPid: pid) else { continue }
            counts[cwd, default: 0] += 1
        }

        return counts
    }

    /// Returns the most likely active Codex session ID per live Codex process by
    /// inspecting the transcript files that process currently has open.
    nonisolated func activeCodexSessionIds() -> Set<String> {
        let tree = buildTree()
        let codexPids = tree.values.compactMap { info -> Int? in
            let executable = info.command
                .split(separator: " ")
                .first
                .map(String.init)?
                .split(separator: "/")
                .last
                .map(String.init)?
                .lowercased()

            return executable == "codex" ? info.pid : nil
        }

        var sessionIds = Set<String>()
        for pid in codexPids {
            if let sessionId = activeCodexSessionId(forPid: pid) {
                sessionIds.insert(sessionId)
            }
        }

        return sessionIds
    }

    private nonisolated func activeCodexSessionId(forPid pid: Int) -> String? {
        guard let output = ProcessExecutor.shared.runSyncOrNil("/usr/sbin/lsof", arguments: ["-p", String(pid)]) else {
            return nil
        }

        let transcriptPaths = output
            .components(separatedBy: "\n")
            .compactMap { line -> String? in
                guard line.contains("/.codex/sessions/"), line.contains(".jsonl") else { return nil }
                let columns = line.split(whereSeparator: \.isWhitespace)
                guard let path = columns.last else { return nil }
                return String(path)
            }

        let newestPath = transcriptPaths.max { lhs, rhs in
            let leftDate = (try? URL(fileURLWithPath: lhs).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rightDate = (try? URL(fileURLWithPath: rhs).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return leftDate < rightDate
        }

        guard let newestPath else { return nil }
        return Self.extractCodexSessionId(fromTranscriptPath: newestPath)
    }

    private nonisolated static func extractCodexSessionId(fromTranscriptPath path: String) -> String? {
        let filename = URL(fileURLWithPath: path).lastPathComponent
        guard let range = filename.range(of: #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#, options: .regularExpression) else {
            return nil
        }
        return String(filename[range])
    }
}
