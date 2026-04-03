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

        let candidateLines = rawText
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { isMeaningfulLine($0) }

        var text = bestCandidate(from: candidateLines) ?? candidateLines.first ?? rawText
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
            "can you review"
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

        if lower.contains("fix ") || lower.hasPrefix("fix") { score += 5 }
        if lower.contains("improve ") || lower.hasPrefix("improve") { score += 4 }
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
