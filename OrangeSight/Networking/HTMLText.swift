import Foundation
import SwiftUI

/// Small, fast helpers for the limited HTML that Hacker News emits.
nonisolated enum HTML {
    static func decodeEntities(_ s: some StringProtocol) -> String {
        guard s.contains("&") else { return String(s) }
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            guard c == "&", let semi = s[i...].prefix(10).firstIndex(of: ";") else {
                out.append(c)
                i = s.index(after: i)
                continue
            }
            let entity = s[s.index(after: i)..<semi]
            if let decoded = decode(entity: entity) {
                out.append(decoded)
                i = s.index(after: semi)
            } else {
                out.append(c)
                i = s.index(after: i)
            }
        }
        return out
    }

    private static func decode(entity: some StringProtocol) -> String? {
        switch entity {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return " "
        case "ndash": return "–"
        case "mdash": return "—"
        case "hellip": return "…"
        default: break
        }
        guard entity.hasPrefix("#") else { return nil }
        let body = entity.dropFirst()
        let value: UInt32? = body.hasPrefix("x") || body.hasPrefix("X")
            ? UInt32(body.dropFirst(), radix: 16)
            : UInt32(body)
        return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
    }

    /// Strips tags and decodes entities. `<p>` becomes a blank line.
    static func plainText(_ html: some StringProtocol) -> String {
        var out = ""
        var inTag = false
        var tag = ""
        for c in html {
            if inTag {
                if c == ">" {
                    inTag = false
                    let name = tag.lowercased()
                    if name == "p" || name.hasPrefix("p ") { out += "\n\n" }
                    if name == "br" || name == "br/" { out += "\n" }
                } else {
                    tag.append(c)
                }
            } else if c == "<" {
                inTag = true
                tag = ""
            } else {
                out.append(c)
            }
        }
        return decodeEntities(out).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Converts HN comment/self-post HTML into styled text: paragraphs, italics, links,
    /// code blocks, and `>`-prefixed quotes.
    static func attributed(_ html: some StringProtocol) -> AttributedString {
        var paragraphs: [AttributedString] = []
        var current = AttributedString()
        var italic = false
        var bold = false
        var inPre = false
        var link: URL?
        var buffer = ""

        func flushText() {
            guard !buffer.isEmpty else { return }
            var text = decodeEntities(buffer)
            buffer = ""
            if !inPre {
                text = text.replacingOccurrences(of: "\n", with: " ")
            }
            var run = AttributedString(text)
            var intent: InlinePresentationIntent = []
            if italic { intent.insert(.emphasized) }
            if bold { intent.insert(.stronglyEmphasized) }
            if !intent.isEmpty { run.inlinePresentationIntent = intent }
            if inPre {
                // Smaller than body text so typical code lines fit without wrapping.
                run.font = .system(.caption, design: .monospaced)
            }
            if let link { run.link = link }
            current += run
        }

        func endParagraph() {
            flushText()
            if !current.characters.allSatisfy(\.isWhitespace) {
                paragraphs.append(current)
            }
            current = AttributedString()
        }

        var i = html.startIndex
        while i < html.endIndex {
            let c = html[i]
            guard c == "<", let close = html[i...].firstIndex(of: ">") else {
                buffer.append(c)
                i = html.index(after: i)
                continue
            }
            let rawTag = html[html.index(after: i)..<close]
            let isClosing = rawTag.hasPrefix("/")
            let name = rawTag.drop(while: { $0 == "/" }).prefix(while: \.isLetter).lowercased()

            switch (name, isClosing) {
            case ("p", false):
                endParagraph()
            case ("br", _):
                buffer.append("\n")
            case ("pre", false):
                endParagraph()
                inPre = true
            case ("pre", true):
                flushText()
                // Trim the trailing newline HN leaves inside code blocks.
                while current.characters.last?.isNewline == true {
                    current.characters.removeLast()
                }
                endParagraph()
                inPre = false
            case ("i", _), ("em", _):
                flushText()
                italic = !isClosing
            case ("b", _), ("strong", _):
                flushText()
                bold = !isClosing
            case ("a", false):
                flushText()
                if let href = attribute("href", in: rawTag) {
                    let decoded = decodeEntities(href)
                    link = URL(string: decoded, relativeTo: HNClient.base)?.absoluteURL
                }
            case ("a", true):
                flushText()
                link = nil
            default:
                break
            }
            i = html.index(after: close)
        }
        endParagraph()

        var result = AttributedString()
        for (index, var paragraph) in paragraphs.enumerated() {
            let isQuote = String(paragraph.characters.prefix(2)).trimmingCharacters(in: .whitespaces).hasPrefix(">")
            if isQuote {
                paragraph.foregroundColor = .secondary
            }
            if index > 0 { result += AttributedString("\n\n") }
            result += paragraph
        }
        return result
    }

    static func attribute(_ name: String, in tag: some StringProtocol) -> String? {
        for quote in ["\"", "'"] {
            if let value = tag.slice(from: "\(name)=\(quote)", to: quote) {
                return String(value)
            }
        }
        return nil
    }
}

nonisolated extension StringProtocol {
    /// The text between the first `start` and the following `end`.
    func slice(from start: String, to end: String) -> SubSequence? {
        guard let s = range(of: start) else { return nil }
        guard let e = self[s.upperBound...].range(of: end) else { return nil }
        return self[s.upperBound..<e.lowerBound]
    }

    func after(_ marker: String) -> SubSequence? {
        guard let r = range(of: marker) else { return nil }
        return self[r.upperBound...]
    }

    func before(_ marker: String) -> SubSequence {
        guard let r = range(of: marker) else { return self[...] }
        return self[..<r.lowerBound]
    }
}
