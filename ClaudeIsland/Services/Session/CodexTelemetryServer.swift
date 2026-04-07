//
//  CodexTelemetryServer.swift
//  ClaudeIsland
//
//  Local OTLP/HTTP receiver for Codex live-state updates.
//

import Foundation
import Network
import os.log

struct CodexTelemetryUpdate: Sendable {
    let sessionId: String
    let cwd: String?
    let phase: SessionPhase?
    let message: String?
    let messageRole: String?
    let toolName: String?
    let timestamp: Date
}

final class CodexTelemetryServer {
    static let shared = CodexTelemetryServer()

    private let queue = DispatchQueue(label: "com.claudeisland.codex.telemetry", qos: .userInitiated)
    private var listener: NWListener?
    private let port: NWEndpoint.Port = 4318
    private let logger = Logger(subsystem: "com.claudeisland", category: "CodexTelemetry")

    private init() {}

    func start() {
        queue.async { [weak self] in
            self?.startListener()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.listener?.cancel()
            self?.listener = nil
        }
    }

    private func startListener() {
        guard listener == nil else { return }

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true

            let newListener = try NWListener(using: parameters, on: port)
            newListener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection: connection)
            }
            newListener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.logger.info("Codex OTLP receiver listening on port \(self?.port.rawValue ?? 4318)")
                case .failed(let error):
                    self?.logger.error("Codex OTLP receiver failed: \(error.localizedDescription, privacy: .public)")
                    self?.listener = nil
                default:
                    break
                }
            }

            listener = newListener
            newListener.start(queue: queue)
        } catch {
            logger.error("Failed to start Codex OTLP receiver: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                self.logger.error("Codex OTLP connection error: \(error.localizedDescription, privacy: .public)")
                connection.cancel()
                return
            }

            var accumulated = buffer
            if let data {
                accumulated.append(data)
            }

            if let request = self.parseRequest(from: accumulated) {
                self.handleRequest(request, on: connection)
                return
            }

            if isComplete {
                self.respond(status: 400, body: Data("{}".utf8), on: connection)
                return
            }

            self.receive(on: connection, buffer: accumulated)
        }
    }

    private func handleRequest(_ request: HTTPRequest, on connection: NWConnection) {
        defer {
            respond(status: 200, body: Data("{}".utf8), on: connection)
        }

        guard request.method == "POST" else { return }

        switch request.path {
        case "/v1/logs":
            processLogPayload(request.body)
        case "/v1/traces":
            processTracePayload(request.body)
        case "/v1/metrics":
            break
        default:
            break
        }
    }

    private func processLogPayload(_ body: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let resourceLogs = json["resourceLogs"] as? [[String: Any]] else {
            return
        }

        for resourceLog in resourceLogs {
            let resourceAttributes = parseAttributeMap(from: resourceLog["resource"])
            guard let scopeLogs = resourceLog["scopeLogs"] as? [[String: Any]] else { continue }

            for scopeLog in scopeLogs {
                guard let logRecords = scopeLog["logRecords"] as? [[String: Any]] else { continue }

                for record in logRecords {
                    let attributes = resourceAttributes.merging(parseAttributeMap(from: record["attributes"])) { _, new in new }
                    let timestamp = parseTimestamp(nanosString: record["timeUnixNano"] as? String)
                    let bodyValue = parseAnyValue(record["body"])
                    let bodyAttributes = bodyAttributes(from: bodyValue)
                    let combined = attributes.merging(bodyAttributes) { current, _ in current }

                    guard let update = makeUpdate(
                        attributes: combined,
                        messageFallback: bodyMessage(from: bodyValue),
                        timestamp: timestamp
                    ) else {
                        continue
                    }

                    Task {
                        await SessionStore.shared.process(.telemetryUpdated(update))
                    }
                }
            }
        }
    }

    private func processTracePayload(_ body: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let resourceSpans = json["resourceSpans"] as? [[String: Any]] else {
            return
        }

        for resourceSpan in resourceSpans {
            let resourceAttributes = parseAttributeMap(from: resourceSpan["resource"])
            guard let scopeSpans = resourceSpan["scopeSpans"] as? [[String: Any]] else { continue }

            for scopeSpan in scopeSpans {
                guard let spans = scopeSpan["spans"] as? [[String: Any]] else { continue }

                for span in spans {
                    let attributes = resourceAttributes.merging(parseAttributeMap(from: span["attributes"])) { _, new in new }
                    let timestamp = parseTimestamp(nanosString: span["endTimeUnixNano"] as? String)
                    let spanName = span["name"] as? String
                    let normalizedAttributes = spanName.map { ["span_name": $0] }.map {
                        attributes.merging($0) { current, _ in current }
                    } ?? attributes

                    guard let update = makeUpdate(
                        attributes: normalizedAttributes,
                        messageFallback: spanName,
                        timestamp: timestamp
                    ) else {
                        continue
                    }

                    Task {
                        await SessionStore.shared.process(.telemetryUpdated(update))
                    }
                }
            }
        }
    }

    private func makeUpdate(attributes: [String: String], messageFallback: String?, timestamp: Date) -> CodexTelemetryUpdate? {
        guard let sessionId = firstValue(
            in: attributes,
            keys: [
                "session.id",
                "conversation.id",
                "thread.id",
                "codex.session_id",
                "session_id",
                "sessionId"
            ]
        ) else {
            return nil
        }

        let cwd = firstValue(
            in: attributes,
            keys: ["project.cwd", "cwd", "project_path", "worktree.cwd", "rpc.service", "server.address"]
        )
        let toolName = firstValue(
            in: attributes,
            keys: [
                "tool.name",
                "rpc.method",
                "mcp.tool.name",
                "codex.tool_name",
                "function.name",
                "tool",
                "span_name"
            ]
        )
        let messageRole = inferRole(from: attributes)
        let message = firstValue(
            in: attributes,
            keys: [
                "message",
                "event.message",
                "body.message",
                "summary",
                "text",
                "otel.name",
                "codex.op",
                "rpc.method",
                "span_name"
            ]
        ) ?? messageFallback

        return CodexTelemetryUpdate(
            sessionId: sessionId,
            cwd: cwd,
            phase: explicitPhase(attributes: attributes),
            message: truncate(message, maxLength: 140),
            messageRole: messageRole,
            toolName: toolName,
            timestamp: timestamp
        )
    }

    private func inferRole(from attributes: [String: String]) -> String? {
        if let role = firstValue(in: attributes, keys: ["role", "message.role", "event.role", "otel.kind"]) {
            return role
        }
        if firstValue(
            in: attributes,
            keys: ["tool.name", "rpc.method", "mcp.tool.name", "tool", "codex.tool_name", "function.name"]
        ) != nil {
            return "tool"
        }
        return nil
    }

    private func explicitPhase(attributes: [String: String]) -> SessionPhase? {
        guard let rawStatus = firstValue(
            in: attributes,
            keys: ["status", "session.status", "event.status", "codex.status", "session.phase"]
        )?.lowercased() else {
            return nil
        }

        switch rawStatus {
        case "waiting_for_input":
            return .waitingForInput
        case "waiting_for_approval":
            return .waitingForInput
        case "running_tool", "processing", "starting":
            return .processing
        case "compacting":
            return .compacting
        case "ended":
            return .ended
        case "idle":
            return .idle
        default:
            return nil
        }
    }

    private func parseAttributeMap(from resourceOrAttributes: Any?) -> [String: String] {
        if let resource = resourceOrAttributes as? [String: Any],
           let attributes = resource["attributes"] {
            return parseAttributeMap(from: attributes)
        }

        guard let attributes = resourceOrAttributes as? [[String: Any]] else {
            return [:]
        }

        var result: [String: String] = [:]
        for attribute in attributes {
            guard let key = attribute["key"] as? String else { continue }
            result[key] = parseAnyValue(attribute["value"])
        }
        return result
    }

    private func bodyAttributes(from bodyValue: String?) -> [String: String] {
        guard let bodyValue,
              bodyValue.first == "{",
              let data = bodyValue.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }

        return flatten(object: object)
    }

    private func bodyMessage(from bodyValue: String?) -> String? {
        guard let bodyValue else { return nil }
        if bodyValue.first == "{",
           let data = bodyValue.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return firstValue(in: flatten(object: object), keys: ["message", "text", "summary", "event.message"])
        }
        return bodyValue
    }

    private func flatten(object: [String: Any], prefix: String = "") -> [String: String] {
        var result: [String: String] = [:]

        for (key, value) in object {
            let nextKey = prefix.isEmpty ? key : "\(prefix).\(key)"
            if let nested = value as? [String: Any] {
                for (nestedKey, nestedValue) in flatten(object: nested, prefix: nextKey) {
                    result[nestedKey] = nestedValue
                }
            } else {
                result[nextKey] = String(describing: value)
            }
        }

        return result
    }

    private func parseAnyValue(_ rawValue: Any?) -> String? {
        if let value = rawValue as? String {
            return value
        }

        guard let dictionary = rawValue as? [String: Any] else {
            return nil
        }

        if let value = dictionary["stringValue"] as? String {
            return value
        }
        if let value = dictionary["intValue"] as? String {
            return value
        }
        if let value = dictionary["doubleValue"] as? Double {
            return String(value)
        }
        if let value = dictionary["boolValue"] as? Bool {
            return value ? "true" : "false"
        }
        if let value = dictionary["arrayValue"] as? [String: Any],
           let values = value["values"] as? [[String: Any]] {
            return values.compactMap { parseAnyValue($0) }.joined(separator: ", ")
        }
        if let value = dictionary["kvlistValue"] as? [String: Any],
           let values = value["values"] as? [[String: Any]] {
            var object: [String: String] = [:]
            for item in values {
                guard let key = item["key"] as? String else { continue }
                object[key] = parseAnyValue(item["value"])
            }
            return serialize(object)
        }

        return nil
    }

    private func parseTimestamp(nanosString: String?) -> Date {
        guard let nanosString, let nanos = UInt64(nanosString) else {
            return Date()
        }
        return Date(timeIntervalSince1970: TimeInterval(nanos) / 1_000_000_000)
    }

    private func firstValue(in attributes: [String: String], keys: [String]) -> String? {
        for key in keys {
            if let value = attributes[key], !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func truncate(_ text: String?, maxLength: Int) -> String? {
        guard let text else { return nil }
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")

        if cleaned.count > maxLength {
            return String(cleaned.prefix(maxLength - 3)) + "..."
        }

        return cleaned.isEmpty ? nil : cleaned
    }

    private func serialize(_ object: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return object.description
        }
        return text
    }

    private func respond(status: Int, body: Data, on connection: NWConnection) {
        let response = """
        HTTP/1.1 \(status) OK\r
        Content-Type: application/json\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r
        """

        var packet = Data(response.utf8)
        packet.append(body)

        connection.send(content: packet, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func parseRequest(from data: Data) -> HTTPRequest? {
        guard let text = String(data: data, encoding: .utf8),
              let headerRange = text.range(of: "\r\n\r\n") else {
            return nil
        }

        let headerText = String(text[..<headerRange.lowerBound])
        let headerLines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = headerLines.first else { return nil }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        let method = String(parts[0])
        let path = String(parts[1])
        let contentLength = headerLines
            .dropFirst()
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)) } ?? 0

        let bodyStart = headerRange.upperBound
        let headerByteCount = text.distance(from: text.startIndex, to: bodyStart)
        let totalBytesNeeded = headerByteCount + contentLength
        guard data.count >= totalBytesNeeded else { return nil }

        let body = data.subdata(in: headerByteCount..<totalBytesNeeded)
        return HTTPRequest(method: method, path: path, body: body)
    }

    private struct HTTPRequest {
        let method: String
        let path: String
        let body: Data
    }
}

struct CodexTelemetryInstaller {
    private static let fileManager = FileManager.default
    private static let configURL = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")
    private static let backupURL = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.claude-island.backup.toml")

    static func installIfNeeded() {
        guard let content = try? String(contentsOf: configURL, encoding: .utf8) else { return }

        if !fileManager.fileExists(atPath: backupURL.path) {
            try? content.write(to: backupURL, atomically: true, encoding: .utf8)
        }

        var updated = content
        updated = upsert(section: "features", key: "codex_hooks", value: "true", in: updated)
        updated = upsert(section: "otel", key: "metrics_exporter", value: "\"none\"", in: updated)
        updated = upsert(section: "otel", key: "log_user_prompt", value: "false", in: updated)
        updated = removeKey(section: "otel", key: "exporter", in: updated)
        updated = removeKey(section: "otel", key: "trace_exporter", in: updated)
        updated = upsert(section: "otel.exporter.otlp-http", key: "endpoint", value: "\"http://127.0.0.1:4318/v1/logs\"", in: updated)
        updated = upsert(section: "otel.exporter.otlp-http", key: "protocol", value: "\"json\"", in: updated)
        updated = upsert(section: "otel.trace_exporter.otlp-http", key: "endpoint", value: "\"http://127.0.0.1:4318/v1/traces\"", in: updated)
        updated = upsert(section: "otel.trace_exporter.otlp-http", key: "protocol", value: "\"json\"", in: updated)

        if updated != content {
            try? updated.write(to: configURL, atomically: true, encoding: .utf8)
        }
    }

    static func uninstall() {
        guard fileManager.fileExists(atPath: backupURL.path),
              let backup = try? String(contentsOf: backupURL, encoding: .utf8) else {
            return
        }

        try? backup.write(to: configURL, atomically: true, encoding: .utf8)
        try? fileManager.removeItem(at: backupURL)
    }

    static func isInstalled() -> Bool {
        guard let content = try? String(contentsOf: configURL, encoding: .utf8) else {
            return false
        }

        return content.contains("[otel.exporter.otlp-http]") &&
            content.contains("[otel.trace_exporter.otlp-http]") &&
            content.contains("codex_hooks = true") &&
            content.contains("protocol = \"json\"") &&
            content.contains("http://127.0.0.1:4318/v1/logs")
    }

    private static func upsert(section: String, key: String, value: String, in content: String) -> String {
        var lines = content.components(separatedBy: "\n")
        let sectionHeader = "[\(section)]"

        var sectionStart = lines.firstIndex(of: sectionHeader)
        if sectionStart == nil {
            if lines.last?.isEmpty == false {
                lines.append("")
            }
            sectionStart = lines.count
            lines.append(sectionHeader)
        }

        guard let start = sectionStart else {
            return content
        }

        let nextSection = lines[(start + 1)...].firstIndex { $0.hasPrefix("[") && $0.hasSuffix("]") } ?? lines.count
        if let existing = lines[(start + 1)..<nextSection].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(key) =") }) {
            lines[existing] = "\(key) = \(value)"
        } else {
            lines.insert("\(key) = \(value)", at: nextSection)
        }

        return lines.joined(separator: "\n")
    }

    private static func removeKey(section: String, key: String, in content: String) -> String {
        var lines = content.components(separatedBy: "\n")
        let sectionHeader = "[\(section)]"

        guard let sectionStart = lines.firstIndex(of: sectionHeader) else {
            return content
        }

        let nextSection = lines[(sectionStart + 1)...].firstIndex { $0.hasPrefix("[") && $0.hasSuffix("]") } ?? lines.count

        if let existing = lines[(sectionStart + 1)..<nextSection].firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(key) =")
        }) {
            lines.remove(at: existing)
        }

        return lines.joined(separator: "\n")
    }
}
