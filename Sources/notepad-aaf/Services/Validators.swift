import Foundation

struct Validators {
    func validate(text: String, mode: LanguageMode) -> ValidationStatus {
        switch mode {
        case .json:
            return validateJSON(text)
        case .xml:
            return validateXML(text)
        case .yaml:
            return validateYAML(text)
        case .sql:
            return validateSQL(text)
        case .plainText:
            return .valid
        }
    }

    /// SQL dialects differ too much to parse properly, so this only catches the
    /// structural mistakes that are unambiguous in every dialect: an unclosed
    /// string literal or block comment, and unbalanced parentheses.
    private func validateSQL(_ text: String) -> ValidationStatus {
        let chars = Array(text)
        let n = chars.count
        var i = 0, line = 1, col = 1
        var depth = 0
        var openParens: [(Int, Int)] = []

        func advance(_ k: Int = 1) {
            for _ in 0..<k where i < n {
                if chars[i] == "\n" { line += 1; col = 1 } else { col += 1 }
                i += 1
            }
        }

        while i < n {
            let c = chars[i]
            let next: Character? = i + 1 < n ? chars[i + 1] : nil

            if c == "-", next == "-" {
                while i < n && chars[i] != "\n" { advance() }
                continue
            }
            if c == "/", next == "*" {
                let startLine = line, startCol = col
                advance(2)
                var closed = false
                while i < n {
                    if chars[i] == "*", i + 1 < n, chars[i + 1] == "/" { advance(2); closed = true; break }
                    advance()
                }
                if !closed {
                    return .invalid(message: "Unterminated block comment", line: startLine, column: startCol)
                }
                continue
            }
            if c == "'" {
                let startLine = line, startCol = col
                advance()
                var closed = false
                while i < n {
                    if chars[i] == "'" {
                        if i + 1 < n, chars[i + 1] == "'" { advance(2); continue }
                        advance(); closed = true; break
                    }
                    advance()
                }
                if !closed {
                    return .invalid(message: "Unterminated string literal", line: startLine, column: startCol)
                }
                continue
            }
            if c == "(" { openParens.append((line, col)); depth += 1; advance(); continue }
            if c == ")" {
                depth -= 1
                if depth < 0 {
                    return .invalid(message: "Unmatched closing parenthesis", line: line, column: col)
                }
                openParens.removeLast()
                advance()
                continue
            }
            advance()
        }

        if let (l, c) = openParens.last {
            return .invalid(message: "Unclosed parenthesis", line: l, column: c)
        }
        return .valid
    }

    private func validateJSON(_ text: String) -> ValidationStatus {
        guard let data = text.data(using: .utf8) else {
            return .invalid(message: "Invalid UTF-8 data")
        }
        do {
            _ = try JSONSerialization.jsonObject(with: data)
            return .valid
        } catch {
            let nsError = error as NSError
            if let index = nsError.userInfo["NSJSONSerializationErrorIndex"] as? Int {
                let (line, col) = Self.lineColumn(in: text, utf16Index: index)
                return .invalid(message: nsError.localizedDescription, line: line, column: col)
            }
            return .invalid(message: nsError.localizedDescription)
        }
    }

    private func validateXML(_ text: String) -> ValidationStatus {
        guard let data = text.data(using: .utf8) else {
            return .invalid(message: "Invalid UTF-8 data")
        }
        let delegate = XMLValidationDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        if parser.parse() {
            return .valid
        }
        if let err = delegate.error {
            let line = Int(parser.lineNumber)
            let col = Int(parser.columnNumber)
            return .invalid(message: err.localizedDescription, line: line > 0 ? line : nil, column: col > 0 ? col : nil)
        }
        return .invalid(message: "XML is not well-formed")
    }

    private func validateYAML(_ text: String) -> ValidationStatus {
        let lines = text.components(separatedBy: .newlines)
        var indentStack: [Int] = [0]

        for (idx, raw) in lines.enumerated() {
            if raw.contains("\t") {
                return .invalid(message: "Tabs are not allowed for YAML indentation", line: idx + 1, column: 1)
            }

            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            let indent = raw.prefix { $0 == " " }.count
            if indent % 2 != 0 {
                return .invalid(message: "Indentation must use multiples of 2 spaces", line: idx + 1, column: 1)
            }

            while let last = indentStack.last, indent < last {
                indentStack.removeLast()
            }

            if let last = indentStack.last, indent > last + 2 {
                return .invalid(message: "Indentation jumped more than one level", line: idx + 1, column: 1)
            }

            if indentStack.last != indent {
                indentStack.append(indent)
            }

            if trimmed.contains(":") {
                let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                if parts.count == 2, parts[0].isEmpty {
                    return .invalid(message: "Missing key before ':'", line: idx + 1, column: 1)
                }
            }
        }

        return .valid
    }

    private static func lineColumn(in text: String, utf16Index: Int) -> (Int, Int) {
        let nsText = text as NSString
        let clamped = max(0, min(utf16Index, nsText.length))
        let prefix = nsText.substring(to: clamped)
        let lines = prefix.components(separatedBy: .newlines)
        let line = max(lines.count, 1)
        let col = (lines.last?.count ?? 0) + 1
        return (line, col)
    }
}

private final class XMLValidationDelegate: NSObject, XMLParserDelegate {
    var error: Error?

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        error = parseError
    }

    func parser(_ parser: XMLParser, validationErrorOccurred validationError: Error) {
        error = validationError
    }
}
