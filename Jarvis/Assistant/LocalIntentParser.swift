import Foundation

enum LocalIntent: Equatable {
    case power(reference: String, on: Bool, all: Bool)
    case brightness(reference: String, percent: Int)
    case fan(reference: String, on: Bool)
    case routine(name: String)
    case macVolume(percent: Int)
    case macMute(Bool)
}

final class LocalIntentParser {
    func parse(_ input: String) -> [LocalIntent] {
        splitCommands(input).compactMap { parseSingle($0) }
    }

    private func parseSingle(_ rawInput: String) -> LocalIntent? {
        let input = normalize(rawInput)
        guard !input.isEmpty else { return nil }

        if let capture = firstMatch(#"^(?:activate|run|start)\s+(.+?)(?:\s+(?:routine|scene))?$"#, in: input, group: 1) {
            return .routine(name: capture)
        }
        if ["goodnight", "good night", "movie mode", "gaming mode", "study mode", "wake up", "away mode"].contains(input) {
            return .routine(name: input.replacingOccurrences(of: " mode", with: ""))
        }
        if input == "mute" || input == "mute the mac" || input == "mute my mac" {
            return .macMute(true)
        }
        if input == "unmute" || input == "unmute the mac" || input == "unmute my mac" {
            return .macMute(false)
        }
        if let percent = integerCapture(#"^(?:set\s+)?(?:the\s+)?(?:mac\s+)?volume\s+(?:to\s+)?(\d{1,3})(?:\s*percent)?$"#, in: input) {
            return (0...100).contains(percent) ? .macVolume(percent: percent) : nil
        }
        if let match = captures(#"^set\s+(.+?)\s+(?:to|at)\s+(\d{1,3})(?:\s*percent|%)?$"#, in: input),
           let percent = Int(match[1]), (0...100).contains(percent) {
            return .brightness(reference: cleanedReference(match[0]), percent: percent)
        }
        if let match = captures(#"^(?:turn|switch)\s+(.+?)\s+(on|off)$"#, in: input) {
            let reference = cleanedReference(match[0])
            let all = reference.contains("all") || reference.contains("everything")
            if reference.contains("fan") {
                return .fan(reference: reference, on: match[1] == "on")
            }
            return .power(reference: reference, on: match[1] == "on", all: all)
        }
        if let match = captures(#"^(?:turn|switch)\s+(on|off)\s+(.+)$"#, in: input) {
            let reference = cleanedReference(match[1])
            let all = reference.contains("all") || reference.contains("everything")
            if reference.contains("fan") {
                return .fan(reference: reference, on: match[0] == "on")
            }
            return .power(reference: reference, on: match[0] == "on", all: all)
        }
        return nil
    }

    private func splitCommands(_ input: String) -> [String] {
        let commaSeparated = input
            .replacingOccurrences(of: ", and ", with: " | ", options: .caseInsensitive)
            .replacingOccurrences(of: ", then ", with: " | ", options: .caseInsensitive)
            .replacingOccurrences(of: #",\s*"#, with: " | ", options: .regularExpression)
            .replacingOccurrences(of: ";", with: " | ")
        let separated = commaSeparated.replacingOccurrences(
            of: #"\s+and\s+(?=(?:turn|switch|set|activate|run|start|mute|unmute)\b)"#,
            with: " | ",
            options: [.regularExpression, .caseInsensitive]
        )
        return separated.components(separatedBy: " | ")
    }

    private func normalize(_ value: String) -> String {
        value.lowercased()
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private func cleanedReference(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"^(?:my|the)\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func integerCapture(_ pattern: String, in input: String) -> Int? {
        firstMatch(pattern, in: input, group: 1).flatMap(Int.init)
    }

    private func firstMatch(_ pattern: String, in input: String, group: Int) -> String? {
        guard let values = captures(pattern, in: input) else { return nil }
        let index = group - 1
        return values.indices.contains(index) ? values[index] : nil
    }

    private func captures(_ pattern: String, in input: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let result = expression.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)) else {
            return nil
        }
        return (1..<result.numberOfRanges).compactMap { index in
            let range = result.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: input) else { return nil }
            return String(input[swiftRange])
        }
    }
}
