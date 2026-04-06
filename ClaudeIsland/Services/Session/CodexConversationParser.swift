//
//  CodexConversationParser.swift
//  ClaudeIsland
//
//  Parses Codex transcript files from ~/.codex/sessions.
//

import Foundation

actor CodexConversationParser {
    static let shared = CodexConversationParser()

    private static let activeSessionFreshnessWindow: TimeInterval = 75
    private static let waitingForInputFreshnessWindow: TimeInterval = 10 * 60
    private static let duplicateMessageWindow: TimeInterval = 2

    struct ParsedConversation {
        let messages: [ChatMessage]
        let completedToolIds: Set<String>
        let toolResults: [String: ConversationParser.ToolResult]
        let conversationInfo: ConversationInfo
        let phase: SessionPhase
    }

    private let fileManager = FileManager.default
    private var sessionFileCache: [String: URL] = [:]

    private init() {}

    func loadConversation(sessionId: String) -> ParsedConversation {
        guard let url = resolveSessionFile(sessionId: sessionId),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return ParsedConversation(
                messages: [],
                completedToolIds: [],
                toolResults: [:],
                conversationInfo: ConversationInfo(
                    summary: nil,
                    lastMessage: nil,
                    lastMessageRole: nil,
                    lastToolName: nil,
                    firstUserMessage: nil,
                    lastUserMessageDate: nil
                ),
                phase: .idle
            )
        }

        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
        return parseContent(content, sessionId: sessionId, modified: modified)
    }

    private func resolveSessionFile(sessionId: String) -> URL? {
        if let cached = sessionFileCache[sessionId], fileManager.fileExists(atPath: cached.path) {
            return cached
        }

        let sessionsRoot = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")

        guard let enumerator = fileManager.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            if fileURL.lastPathComponent.contains(sessionId) {
                sessionFileCache[sessionId] = fileURL
                return fileURL
            }
        }

        return nil
    }

    private func parseContent(_ content: String, sessionId: String, modified: Date) -> ParsedConversation {
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var messages: [ChatMessage] = []
        var completedToolIds = Set<String>()
        var toolResults: [String: ConversationParser.ToolResult] = [:]
        var pendingToolIds = Set<String>()

        var firstUserMessage: String?
        var firstUserMessageRaw: String?
        var lastUserMessage: String?
        var lastUserMessageDate: Date?
        var lastAssistantMessage: String?
        var lastToolName: String?
        var lastToolInput: String?
        var lastSignificantKind: LastSignificantKind = .idle

        for (index, line) in lines.enumerated() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else {
                continue
            }

            let timestamp = (json["timestamp"] as? String).flatMap { formatter.date(from: $0) } ?? Date()

            switch type {
            case "event_msg":
                guard let payload = json["payload"] as? [String: Any],
                      let payloadType = payload["type"] as? String else {
                    continue
                }

                switch payloadType {
                case "user_message":
                    guard let message = payload["message"] as? String, !message.isEmpty else { continue }
                    if firstUserMessage == nil {
                        firstUserMessageRaw = message
                        firstUserMessage = Self.truncate(message, maxLength: 50)
                    }
                    lastUserMessage = Self.truncate(message, maxLength: 80)
                    lastUserMessageDate = timestamp
                    lastSignificantKind = .user
                    messages.append(
                        ChatMessage(
                            id: "\(sessionId)-user-\(index)",
                            role: .user,
                            timestamp: timestamp,
                            content: [.text(message)]
                        )
                    )

                case "agent_message":
                    guard let message = payload["message"] as? String,
                          !message.isEmpty,
                          let phase = payload["phase"] as? String,
                          phase == "commentary" else {
                        continue
                    }
                    lastAssistantMessage = Self.truncate(message, maxLength: 80)
                    lastSignificantKind = .assistant
                    messages.append(
                        ChatMessage(
                            id: "\(sessionId)-commentary-\(index)",
                            role: .assistant,
                            timestamp: timestamp,
                            content: [.text(message)]
                        )
                    )

                case "agent_reasoning":
                    guard let text = payload["text"] as? String, !text.isEmpty else { continue }
                    lastSignificantKind = .reasoning
                    messages.append(
                        ChatMessage(
                            id: "\(sessionId)-thinking-\(index)",
                            role: .assistant,
                            timestamp: timestamp,
                            content: [.thinking(text)]
                        )
                    )

                case "task_complete":
                    lastSignificantKind = .assistant

                default:
                    continue
                }

            case "response_item":
                guard let payload = json["payload"] as? [String: Any],
                      let payloadType = payload["type"] as? String else {
                    continue
                }

                switch payloadType {
                case "function_call":
                    let callId = payload["call_id"] as? String ?? "\(sessionId)-tool-\(index)"
                    let name = payload["name"] as? String ?? "tool"
                    let input = parseInput(arguments: payload["arguments"])
                    lastToolName = name
                    lastToolInput = input.isEmpty ? nil : Self.truncate(Self.serialize(input), maxLength: 80)
                    pendingToolIds.insert(callId)
                    lastSignificantKind = .tool
                    messages.append(
                        ChatMessage(
                            id: "\(sessionId)-tool-call-\(callId)",
                            role: .assistant,
                            timestamp: timestamp,
                            content: [.toolUse(ToolUseBlock(id: callId, name: name, input: input))]
                        )
                    )

                case "function_call_output":
                    guard let callId = payload["call_id"] as? String else { continue }
                    let output = payload["output"] as? String
                    let isError = isErrorOutput(output)
                    pendingToolIds.remove(callId)
                    completedToolIds.insert(callId)
                    toolResults[callId] = ConversationParser.ToolResult(
                        content: output,
                        stdout: isError ? nil : output,
                        stderr: isError ? output : nil,
                        isError: isError
                    )
                    lastSignificantKind = .tool

                case "message":
                    guard let role = payload["role"] as? String,
                          role == "assistant",
                          let responseText = parseAssistantText(from: payload["content"]) else {
                        continue
                    }
                    lastAssistantMessage = Self.truncate(responseText, maxLength: 80)
                    lastSignificantKind = .assistant
                    messages.append(
                        ChatMessage(
                            id: "\(sessionId)-assistant-\(index)",
                            role: .assistant,
                            timestamp: timestamp,
                            content: [.text(responseText)]
                        )
                    )

                case "reasoning":
                    guard let summary = payload["summary"] as? [[String: Any]] else { continue }
                    let text = summary.compactMap { $0["text"] as? String }.joined(separator: "\n")
                    guard !text.isEmpty else { continue }
                    lastSignificantKind = .reasoning
                    messages.append(
                        ChatMessage(
                            id: "\(sessionId)-reasoning-\(index)",
                            role: .assistant,
                            timestamp: timestamp,
                            content: [.thinking(text)]
                        )
                    )

                default:
                    continue
                }

            default:
                continue
            }
        }

        let lastMessage: String?
        let lastMessageRole: String?
        if let toolInput = lastToolInput, lastSignificantKind == .tool {
            lastMessage = toolInput
            lastMessageRole = "tool"
        } else if let assistant = lastAssistantMessage, lastSignificantKind == .assistant {
            lastMessage = assistant
            lastMessageRole = "assistant"
        } else {
            lastMessage = lastAssistantMessage ?? lastUserMessage ?? lastToolInput
            lastMessageRole = lastAssistantMessage != nil ? "assistant" : (lastUserMessage != nil ? "user" : (lastToolInput != nil ? "tool" : nil))
        }

        let normalizedMessages = deduplicatedMessages(messages.sorted { $0.timestamp < $1.timestamp })

        return ParsedConversation(
            messages: normalizedMessages,
            completedToolIds: completedToolIds,
            toolResults: toolResults,
            conversationInfo: ConversationInfo(
                summary: CodexTitleBuilder.summary(from: firstUserMessageRaw),
                lastMessage: lastMessage,
                lastMessageRole: lastMessageRole,
                lastToolName: lastToolName,
                firstUserMessage: firstUserMessage,
                lastUserMessageDate: lastUserMessageDate
            ),
            phase: inferPhase(
                lastSignificantKind: lastSignificantKind,
                hasPendingToolCalls: !pendingToolIds.isEmpty,
                modified: modified
            )
        )
    }

    private func deduplicatedMessages(_ messages: [ChatMessage]) -> [ChatMessage] {
        var deduplicated: [ChatMessage] = []

        for message in messages {
            guard let previous = deduplicated.last else {
                deduplicated.append(message)
                continue
            }

            if shouldDropAsDuplicate(message, previous: previous) {
                continue
            }

            deduplicated.append(message)
        }

        return deduplicated
    }

    private func shouldDropAsDuplicate(_ candidate: ChatMessage, previous: ChatMessage) -> Bool {
        guard candidate.role == .assistant,
              previous.role == .assistant else {
            return false
        }

        let timestampDistance = candidate.timestamp.timeIntervalSince(previous.timestamp)
        guard timestampDistance >= 0,
              timestampDistance <= Self.duplicateMessageWindow else {
            return false
        }

        let candidateText = normalizedDuplicateComparisonText(candidate)
        let previousText = normalizedDuplicateComparisonText(previous)
        guard !candidateText.isEmpty,
              candidateText == previousText else {
            return false
        }

        return true
    }

    private func normalizedDuplicateComparisonText(_ message: ChatMessage) -> String {
        let normalizedBlocks = message.content.compactMap { block -> String? in
            switch block {
            case .text(let text), .thinking(let text):
                return text
            case .toolUse, .interrupted:
                return nil
            }
        }

        return normalizedBlocks
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private func parseAssistantText(from rawContent: Any?) -> String? {
        guard let content = rawContent as? [[String: Any]] else { return nil }
        let text = content.compactMap { item -> String? in
            guard item["type"] as? String == "output_text" else { return nil }
            return item["text"] as? String
        }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    private func parseInput(arguments: Any?) -> [String: String] {
        guard let argumentsString = arguments as? String,
              let data = argumentsString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return [:]
        }

        if let dictionary = object as? [String: Any] {
            return dictionary.reduce(into: [:]) { partialResult, entry in
                partialResult[entry.key] = stringify(entry.value)
            }
        }

        return ["input": stringify(object)]
    }

    private func stringify(_ value: Any) -> String {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        case let array as [Any]:
            return Self.serialize(array)
        case let dictionary as [String: Any]:
            return Self.serialize(dictionary)
        default:
            return String(describing: value)
        }
    }

    private func inferPhase(
        lastSignificantKind: LastSignificantKind,
        hasPendingToolCalls: Bool,
        modified: Date
    ) -> SessionPhase {
        if hasPendingToolCalls {
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

    private func isErrorOutput(_ output: String?) -> Bool {
        guard let output else { return false }
        if output.contains("Process exited with code 0") {
            return false
        }
        return output.contains("Process exited with code")
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

    private static func serialize(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return text
    }

    private enum LastSignificantKind {
        case idle
        case user
        case assistant
        case tool
        case reasoning
    }
}
