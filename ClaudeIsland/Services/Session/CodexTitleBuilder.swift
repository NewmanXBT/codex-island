//
//  CodexTitleBuilder.swift
//  ClaudeIsland
//
//  Builds short project briefs from Codex prompts.
//

import Foundation

enum CodexTitleBuilder {
    static func summary(from firstUserMessage: String?) -> String? {
        guard var text = firstUserMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }

        text = text.replacingOccurrences(of: "\r", with: "\n")
        text = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { isMeaningfulLine($0) } ?? text

        text = text.replacingOccurrences(of: "`", with: "")
        text = text.replacingOccurrences(
            of: #"\bhttps?://\S+\b"#,
            with: "",
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
            "for this repo"
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

        if text.count > 52 {
            text = String(text.prefix(49)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
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
            #"(?:build|create|implement|fix|debug|investigate|refactor|improve|update|add|remove|make|design)\s+.+$"#,
            #"(?:messaging|title|session|processing|terminal|notch|island)\b.+$"#
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
}
