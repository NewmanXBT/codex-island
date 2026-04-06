//
//  CodexSessionScanner.swift
//  ClaudeIsland
//
//  Discovers recent Codex sessions from local transcript files.
//  This is intentionally minimal: session discovery and preview first,
//  richer live-state wiring comes from OTLP/hooks later.
//

import Foundation

actor CodexSessionScanner {
    static let shared = CodexSessionScanner()

    private static let bootstrapRecencyWindow: TimeInterval = 90 * 60
    private static let activeSessionFreshnessWindow: TimeInterval = 75
    private static let waitingForInputFreshnessWindow: TimeInterval = 10 * 60
    private let fileManager = FileManager.default

    private init() {}

    func scanRecentSessions(limit: Int = 8) -> [SessionState] {
        let sessionsRoot = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")

        guard let enumerator = fileManager.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [(url: URL, modified: Date)] = []

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = values.contentModificationDate else { continue }
            files.append((fileURL, modified))
        }

        let cutoff = Date().addingTimeInterval(-Self.bootstrapRecencyWindow)
        let sortedFiles = files.sorted { $0.modified > $1.modified }

        var sessions: [SessionState] = []
        sessions.reserveCapacity(limit)

        for file in sortedFiles {
            guard file.modified >= cutoff else { continue }
            guard let session = parseSessionFile(url: file.url, modified: file.modified) else { continue }
            sessions.append(session)
            if sessions.count == limit {
                break
            }
        }

        return sessions
    }

    private func parseSessionFile(url: URL, modified: Date) -> SessionState? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }

        var sessionId: String?
        var cwd: String?
        var firstUserMessage: String?
        var firstUserMessageRaw: String?
        var lastUserMessage: String?
        var lastUserMessageDate: Date?
        var lastAssistantMessage: String?
        var lastToolName: String?
        var lastToolInput: String?
        var hasPendingToolCall = false
        var lastSignificantKind: LastSignificantKind = .idle

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = json["type"] as? String else {
                continue
            }

            if type == "session_meta",
               let payload = json["payload"] as? [String: Any] {
                if Self.isSubagentSource(payload["source"]) {
                    return nil
                }
                sessionId = payload["id"] as? String ?? sessionId
                cwd = payload["cwd"] as? String ?? cwd
            }

            let timestamp = (json["timestamp"] as? String).flatMap { iso.date(from: $0) } ?? modified

            if type == "event_msg",
               let payload = json["payload"] as? [String: Any],
               let payloadType = payload["type"] as? String {
                if payloadType == "user_message",
                   let message = payload["message"] as? String,
                   !message.isEmpty {
                    if firstUserMessage == nil {
                        firstUserMessage = Self.truncate(message, maxLength: 50)
                        firstUserMessageRaw = message
                    }
                    lastUserMessage = Self.truncate(message, maxLength: 80)
                    lastUserMessageDate = timestamp
                    lastSignificantKind = .user
                } else if payloadType == "agent_message",
                          let message = payload["message"] as? String,
                          !message.isEmpty {
                    lastAssistantMessage = Self.truncate(message, maxLength: 80)
                    lastSignificantKind = .assistant
                } else if payloadType == "agent_reasoning" {
                    lastSignificantKind = .reasoning
                } else if payloadType == "task_complete" {
                    lastSignificantKind = .assistant
                }
            }

            if type == "response_item",
               let payload = json["payload"] as? [String: Any],
               let payloadType = payload["type"] as? String {
                if payloadType == "function_call" {
                    lastToolName = payload["name"] as? String ?? lastToolName
                    if let arguments = payload["arguments"] as? String, !arguments.isEmpty {
                        lastToolInput = Self.truncate(arguments, maxLength: 80)
                    }
                    hasPendingToolCall = true
                    lastSignificantKind = .tool
                } else if payloadType == "function_call_output" {
                    hasPendingToolCall = false
                    lastSignificantKind = .tool
                } else if payloadType == "message",
                          let role = payload["role"] as? String,
                          role == "assistant",
                          let content = payload["content"] as? [[String: Any]] {
                    let text = content.compactMap { item -> String? in
                        guard item["type"] as? String == "output_text" else { return nil }
                        return item["text"] as? String
                    }.joined(separator: "\n")
                    if !text.isEmpty {
                        lastAssistantMessage = Self.truncate(text, maxLength: 80)
                    }
                    lastSignificantKind = .assistant
                }
            }
        }

        guard let resolvedSessionId = sessionId, let resolvedCwd = cwd else {
            return nil
        }

        let conversationInfo = ConversationInfo(
            summary: CodexTitleBuilder.summary(from: firstUserMessageRaw),
            lastMessage: lastToolInput ?? lastAssistantMessage ?? lastUserMessage,
            lastMessageRole: lastToolInput != nil ? "tool" : (lastAssistantMessage != nil ? "assistant" : (lastUserMessage != nil ? "user" : nil)),
            lastToolName: lastToolName,
            firstUserMessage: firstUserMessage,
            lastUserMessageDate: lastUserMessageDate
        )

        return SessionState(
            sessionId: resolvedSessionId,
            cwd: resolvedCwd,
            projectName: Self.inferProjectName(cwd: resolvedCwd, firstUserMessage: firstUserMessageRaw),
            provider: .codex,
            phase: inferPhase(
                lastSignificantKind: lastSignificantKind,
                hasPendingToolCall: hasPendingToolCall,
                modified: modified
            ),
            conversationInfo: conversationInfo,
            lastActivity: modified,
            createdAt: modified
        )
    }

    private func inferPhase(
        lastSignificantKind: LastSignificantKind,
        hasPendingToolCall: Bool,
        modified: Date
    ) -> SessionPhase {
        if hasPendingToolCall {
            return .processing
        }

        let age = Date().timeIntervalSince(modified)
        let isActivelyFresh = age <= Self.activeSessionFreshnessWindow
        let isRecentlyActive = age <= Self.waitingForInputFreshnessWindow

        switch lastSignificantKind {
        case .assistant:
            return isRecentlyActive ? .waitingForInput : .idle
        case .idle:
            return .idle
        case .user, .tool, .reasoning:
            if isActivelyFresh {
                return .processing
            }
            return isRecentlyActive ? .waitingForInput : .idle
        }
    }

    private static func truncate(_ text: String, maxLength: Int) -> String {
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")

        if cleaned.count > maxLength {
            return String(cleaned.prefix(maxLength - 3)) + "..."
        }
        return cleaned
    }

    private static func isSubagentSource(_ source: Any?) -> Bool {
        guard let source else { return false }

        if let sourceString = source as? String {
            return sourceString != "cli"
        }

        if let sourceDictionary = source as? [String: Any] {
            return sourceDictionary["subagent"] != nil
        }

        return false
    }

    private static func inferProjectName(cwd: String, firstUserMessage: String?) -> String {
        if let firstUserMessage {
            if let repoName = extractGitHubRepoName(from: firstUserMessage) {
                return repoName
            }

            if let pathName = extractPathName(from: firstUserMessage) {
                return pathName
            }
        }

        let cwdName = URL(fileURLWithPath: cwd).lastPathComponent
        if !cwdName.isEmpty {
            return cwdName
        }

        return "Codex"
    }

    private static func extractGitHubRepoName(from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"github\.com/[^/\s]+/([^/\s?#]+)"#, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let repoRange = Range(match.range(at: 1), in: text) else {
            return nil
        }

        return String(text[repoRange]).replacingOccurrences(of: ".git", with: "")
    }

    private static func extractPathName(from text: String) -> String? {
        let punctuation = CharacterSet(charactersIn: "\"'()[]{}<>.,;:")

        for token in text.split(whereSeparator: \.isWhitespace) {
            let rawToken = token.trimmingCharacters(in: punctuation)
            guard rawToken.hasPrefix("/") else { continue }

            let lastPathComponent = URL(fileURLWithPath: rawToken).lastPathComponent
            if !lastPathComponent.isEmpty, lastPathComponent != "Users" {
                return lastPathComponent
            }
        }

        return nil
    }

    private enum LastSignificantKind {
        case idle
        case user
        case assistant
        case tool
        case reasoning
    }
}
