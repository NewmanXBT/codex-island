//
//  CodexTitleBuilder.swift
//  ClaudeIsland
//
//  Builds short project briefs from Codex prompts.
//

import Foundation

enum CodexTitleBuilder {
    static func summary(from firstUserMessage: String?) -> String? {
        guard let rawText = firstUserMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawText.isEmpty else {
            return nil
        }

        let normalizedRawText = normalizedPrompt(from: rawText)

        let candidateLines = normalizedRawText
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { isMeaningfulLine($0) }

        var text = bestCandidate(from: candidateLines) ?? candidateLines.first ?? normalizedRawText
        guard !text.isEmpty else {
            return nil
        }

        text = text.replacingOccurrences(of: "`", with: "")
        text = text.replacingOccurrences(
            of: #"\bhttps?://\S+\b"#,
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"(?:^|\s)/(?:Users|tmp|var|private|Volumes|opt|Applications|Library|System)\S*"#,
            with: " ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"(?:^|\s)\./\S*"#,
            with: " ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let candidate = extractObjective(from: text) {
            text = candidate
        }

        let leadingNoise = [
            "you are working in",
            "the following is the codex agent history",
            "treat the transcript",
            "assess the exact planned action below",
            "planned action json",
            "please",
            "can you",
            "could you",
            "help me",
            "i need you to",
            "i need to",
            "i want to",
            "we need to",
            "let's",
            "take this repo and",
            "in this repo",
            "for this repo",
            "check my",
            "look at",
            "review",
            "please review",
            "can you review",
            "own the",
            "you may edit files directly in your branch workspace",
            "do not touch",
            "do not edit files",
            "you are not alone in the codebase"
        ]

        let lower = text.lowercased()
        for prefix in leadingNoise {
            if lower.hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count))
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
                break
            }
        }

        let separators = [". ", "。", ":", " - ", " | ", " then ", " and then "]
        for separator in separators {
            if let range = text.range(of: separator, options: .caseInsensitive) {
                let prefix = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if prefix.count >= 10 {
                    text = prefix
                    break
                }
            }
        }

        text = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        text = text.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )

        guard !text.isEmpty,
              text.count >= 8,
              !text.hasPrefix("/"),
              !text.hasPrefix("{"),
              !text.hasPrefix("#") else {
            return nil
        }

        if text.count > 40 {
            text = String(text.prefix(37)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
        }

        return text
    }

    private static func normalizedPrompt(from rawText: String) -> String {
        if let embeddedUserPrompt = extractEmbeddedUserPrompt(from: rawText) {
            return embeddedUserPrompt
        }

        var text = rawText
        let patterns = [
            #"(?is)^you are working in\s+\S+\.\s*"#,
            #"(?is)\byou are not alone in the codebase\b.*$"#,
            #"(?is)\bfinal response must\b.*$"#,
            #"(?is)\breturn a concise inventory\b.*$"#,
            #"(?is)\bdo not edit files\b.*$"#,
            #"(?is)\bdo not touch\b.*$"#
        ]

        for pattern in patterns {
            text = text.replacingOccurrences(
                of: pattern,
                with: " ",
                options: .regularExpression
            )
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractEmbeddedUserPrompt(from rawText: String) -> String? {
        guard rawText.localizedCaseInsensitiveContains(">>> TRANSCRIPT START") else {
            return nil
        }

        let patterns = [
            #"(?m)^\[\d+\]\s+user:\s+(.+)$"#,
            #"(?m)^user:\s+(.+)$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }

            let range = NSRange(rawText.startIndex..<rawText.endIndex, in: rawText)
            let matches = regex.matches(in: rawText, options: [], range: range)

            for match in matches {
                guard match.numberOfRanges > 1,
                      let matchRange = Range(match.range(at: 1), in: rawText) else {
                    continue
                }

                let candidate = String(rawText[matchRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if isUsefulEmbeddedPrompt(candidate) {
                    return candidate
                }
            }
        }

        return nil
    }

    private static func isUsefulEmbeddedPrompt(_ candidate: String) -> Bool {
        guard candidate.count >= 8 else { return false }

        let lower = candidate.lowercased()
        let rejectedPrefixes = [
            "the following is the codex agent history",
            "assess the exact planned action below",
            "planned action json",
            "do you want me to",
            "you are working in"
        ]

        return !rejectedPrefixes.contains { lower.hasPrefix($0) }
    }

    private static func isMeaningfulLine(_ line: String) -> Bool {
        guard !line.isEmpty else { return false }
        if line.hasPrefix("```") || line.hasPrefix("#") || line.hasPrefix(">") {
            return false
        }
        return line.contains(where: \.isLetter)
    }

    private static func extractObjective(from text: String) -> String? {
        let patterns = [
            #"(?:build|create|implement|fix|debug|investigate|refactor|improve|update|add|remove|make|design|rename)\s+.+$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }

            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, options: [], range: range),
                  let matchRange = Range(match.range, in: text) else {
                continue
            }

            let candidate = String(text[matchRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.count >= 8 {
                return candidate
            }
        }

        return nil
    }

    private static func bestCandidate(from lines: [String]) -> String? {
        lines
            .map { cleanedCandidate($0) }
            .filter { !$0.isEmpty }
            .max { score(for: $0) < score(for: $1) }
    }

    private static func cleanedCandidate(_ line: String) -> String {
        line
            .replacingOccurrences(of: #"`[^`]+`"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\[[^\]]+\]\([^)]+\)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func score(for line: String) -> Int {
        let lower = line.lowercased()
        var score = 0

        if lower.contains(">>> transcript start") { score -= 12 }
        if lower.contains("approval request start") { score -= 10 }
        if lower.contains("planned action json") { score -= 10 }
        if lower.contains("you are working in") { score -= 8 }
        if lower.contains("do not edit files") { score -= 7 }
        if lower.contains("final response must") { score -= 7 }
        if lower.contains("fix ") || lower.hasPrefix("fix") { score += 5 }
        if lower.contains("improve ") || lower.hasPrefix("improve") { score += 4 }
        if lower.contains("create ") || lower.hasPrefix("create") { score += 4 }
        if lower.contains("propose ") || lower.hasPrefix("propose") { score += 3 }
        if lower.contains("inventory") { score += 2 }
        if lower.contains("rename ") || lower.hasPrefix("rename") { score += 4 }
        if lower.contains("message") || lower.contains("messaging") { score += 4 }
        if lower.contains("title") || lower.contains("summary") { score += 4 }
        if lower.contains("session") { score += 2 }
        if lower.contains("codex") || lower.contains("claude island") { score += 2 }
        if lower.hasPrefix("you are ") || lower.hasPrefix("we need ") { score -= 4 }
        if lower.contains("/users/") { score -= 6 }
        if line.count > 55 { score -= 3 }
        if line.count >= 12 && line.count <= 42 { score += 3 }

        return score
    }
}
