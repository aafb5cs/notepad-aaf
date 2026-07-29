import AppKit
import Foundation

/// Lightweight, pure-Swift syntax highlighting applied directly to an
/// `NSTextStorage`. Highlighting can be restricted to a character range so that
/// multi-MB files only need their *visible* region re-colored on each edit or
/// scroll, keeping the UI responsive.
struct SyntaxHighlighter {
    let font: NSFont

    init(font: NSFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)) {
        self.font = font
    }

    /// Highlight `range` (or the whole storage when `range` is nil). The range is
    /// expanded to whole lines internally so line-anchored patterns behave.
    func highlight(textStorage: NSTextStorage, language: LanguageMode, range: NSRange? = nil) {
        let nsString = textStorage.string as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        let target: NSRange
        if let range, range.location != NSNotFound, fullRange.length > 0 {
            let clamped = NSIntersectionRange(range, fullRange)
            target = clamped.length > 0 ? nsString.lineRange(for: clamped) : fullRange
        } else {
            target = fullRange
        }
        guard target.length > 0 else {
            // Nothing to color, but still reset base attributes so typing attrs stay consistent.
            return
        }

        let baseAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.labelColor,
            .font: font
        ]

        textStorage.beginEditing()
        textStorage.setAttributes(baseAttrs, range: target)

        switch language {
        case .json:
            apply("\"(?:\\\\.|[^\\\\\"])*\"", .systemRed, textStorage, target)
            apply("\\b(true|false|null)\\b", .systemPurple, textStorage, target)
            apply("-?(?:0|[1-9]\\d*)(?:\\.\\d+)?(?:[eE][+-]?\\d+)?", .systemOrange, textStorage, target)
            apply("(?m)\"(?:\\\\.|[^\\\\\"])*\"(?=\\s*:)", .systemBlue, textStorage, target)
        case .yaml:
            apply("(?m)#.*$", .secondaryLabelColor, textStorage, target)
            apply("(?m)^\\s*-?\\s*[A-Za-z0-9_\"'.\\-]+(?=\\s*:(\\s|$))", .systemBlue, textStorage, target)
            apply("\\b(true|false|null|yes|no|on|off)\\b", .systemPurple, textStorage, target)
            apply("(?<![\\w.])-?(?:0|[1-9]\\d*)(?:\\.\\d+)?(?![\\w.])", .systemOrange, textStorage, target)
        case .xml:
            apply("<!--[\\s\\S]*?-->", .secondaryLabelColor, textStorage, target)
            apply("</?[A-Za-z_][\\w:.\\-]*", .systemBlue, textStorage, target)
            apply("[/?]?>", .systemBlue, textStorage, target)
            apply("\\b[A-Za-z_][\\w:.\\-]*(?=\\s*=)", .systemTeal, textStorage, target)
            apply("\"[^\"]*\"|'[^']*'", .systemRed, textStorage, target)
        case .sql:
            apply("(?i)\\b(\(Self.sqlKeywordPattern))\\b", .systemBlue, textStorage, target)
            apply("(?i)\\b(\(Self.sqlFunctionPattern))\\b(?=\\s*\\()", .systemTeal, textStorage, target)
            apply("(?<![\\w.])-?\\d+(?:\\.\\d+)?(?![\\w.])", .systemOrange, textStorage, target)
            apply("'(?:''|[^'])*'", .systemRed, textStorage, target)
            apply("(?m)--.*$", .secondaryLabelColor, textStorage, target)
            apply("/\\*[\\s\\S]*?\\*/", .secondaryLabelColor, textStorage, target)
        case .nginx:
            // Directive position is "first word of a logical line", which after
            // formatting means first word on the line.
            apply("(?m)^[ \\t]*[A-Za-z_][\\w.]*", .systemBlue, textStorage, target)
            apply("\\$\\{?[A-Za-z0-9_]+\\}?", .systemPurple, textStorage, target)
            apply("(?i)\\b(on|off)\\b", .systemPurple, textStorage, target)
            // Sizes and times keep their unit suffix (16k, 10m, 30s, 1d).
            apply("(?<![\\w.$])\\d+[kKmMgGsSmMhHdDwWyY]?(?![\\w.])", .systemOrange, textStorage, target)
            apply("\"(?:\\\\.|[^\\\\\"])*\"|'(?:\\\\.|[^\\\\'])*'", .systemRed, textStorage, target)
            // Last, so a '#' inside a directive line wins over everything above.
            apply("(?m)#.*$", .secondaryLabelColor, textStorage, target)
        case .plainText:
            break
        }

        textStorage.endEditing()
    }

    private func apply(_ pattern: String, _ color: NSColor, _ textStorage: NSTextStorage, _ range: NSRange) {
        guard let regex = Self.cachedRegex(pattern) else { return }
        regex.enumerateMatches(in: textStorage.string, options: [], range: range) { match, _, _ in
            guard let matchRange = match?.range, matchRange.length > 0 else { return }
            textStorage.addAttribute(.foregroundColor, value: color, range: matchRange)
        }
    }

    /// Keyword/function alternations built once from the formatter's vocabulary,
    /// so highlighting and formatting always agree on what a keyword is.
    private static let sqlKeywordPattern = SQLFormatter.keywords.sorted().joined(separator: "|")
    private static let sqlFunctionPattern = SQLFormatter.functions.sorted().joined(separator: "|")

    private static var regexCache: [String: NSRegularExpression] = [:]
    private static let cacheLock = NSLock()

    private static func cachedRegex(_ pattern: String) -> NSRegularExpression? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = regexCache[pattern] { return cached }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        regexCache[pattern] = regex
        return regex
    }
}
