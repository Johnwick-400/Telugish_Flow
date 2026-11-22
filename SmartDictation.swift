import Foundation

enum SmartDictation {
    private static let hours = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
                                "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12]
    private static let tens = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
                               "seventy": 70, "eighty": 80, "ninety": 90]
    private static let minutes = ["fifteen": "15", "thirty": "30", "forty five": "45"]

    static func clean(_ raw: String) -> String {
        var text = replace(#"(?i)^\s*(?:(?:aa+|uh+|um+|hmm+)\b[\s,;…]+)+"#, in: raw, with: "")
        let clock = #"(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|[1-9]|1[0-2])(?:\s+(?:fifteen|thirty|forty[ -]five)|:[0-5]\d)?"#
        let repeatedAction = #"(?i)\b("# + clock + #")\s*[-‐‑–]?\s*ki\s+pettu[\s,.…—–-]+(?:kaadu|kadu)[\s,.…—–-]+("# + clock + #")\s*[-‐‑–]?\s*ki\s+pettu\b"#
        text = replace(repeatedAction, in: text, with: "$2 ki pettu")
        let correction = #"(?i)\b("# + clock + #")\s*[-‐‑–]?\s*ki[\s,.…—–-]+(?:(?:kaadu|kadu)[\s,.…—–-]+)+("# + clock + #")\s*[-‐‑–]?\s*ki\b"#
        text = replace(correction, in: text, with: "$2 ki")
        text = replace(#"(?i)\b([\p{L}]+(?:[ \t]+[\p{L}]+){1,4})[ \t,]+\1\b"#, in: text) { groups in
            // Keep repeated phrases with quantities or explicit correction cues.
            let protected = #"(?i)\b(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|lakh|crore|million|kaadu|kadu)\b"#
            return groups[1].range(of: protected, options: .regularExpression) == nil ? groups[1] : groups[0]
        }
        text = replace(#"(?i)\b("# + hours.keys.sorted().joined(separator: "|") + #")\s+(fifteen|thirty|forty[ -]five)\s*[-‐‑–]?\s*ki\b"#, in: text) { groups in
            let hour = hours[groups[1].lowercased()]!
            let minute = minutes[groups[2].lowercased().replacingOccurrences(of: "-", with: " ")]!
            return "\(hour):\(minute) ki"
        }
        text = replace(#"(?i)\b("# + hours.keys.sorted().joined(separator: "|") + #")\s+(minutes?|hours?)\b"#, in: text) { groups in
            "\(hours[groups[1].lowercased()]!) \(groups[2])"
        }
        text = replace(#"(?i)\b(pull\s+request)(?:\s+number)?\s+(twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)[ -](one|two|three|four|five|six|seven|eight|nine)\b(?![ -](?:hundred|thousand|lakh|crore|million|billion)\b)"#, in: text) { groups in
            "\(groups[1]) #\(tens[groups[2].lowercased()]! + hours[groups[3].lowercased()]!)"
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return raw }
        let first = text.prefix(1).uppercased() + text.dropFirst()
        return first.last?.isLetter == true || first.last?.isNumber == true ? first + "." : first
    }

    private static func replace(_ pattern: String, in text: String, with replacement: String) -> String {
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                              withTemplate: replacement)
    }

    private static func replace(_ pattern: String, in text: String,
                                transform: ([String]) -> String) -> String {
        let regex = try! NSRegularExpression(pattern: pattern)
        let source = text as NSString
        let result = NSMutableString(string: text)
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            let groups = (0..<match.numberOfRanges).map { source.substring(with: match.range(at: $0)) }
            result.replaceCharacters(in: match.range, with: transform(groups))
        }
        return result as String
    }
}
