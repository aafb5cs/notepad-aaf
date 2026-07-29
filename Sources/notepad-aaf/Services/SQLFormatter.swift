import Foundation

/// Minimal SQL tokenizer + pretty printer.
///
/// Deliberately conservative: string literals, quoted identifiers and comments
/// are passed through verbatim, and any construct the layout rules don't
/// recognise is emitted inline. Formatting only ever changes whitespace and the
/// case of reserved words, never what a statement means.
enum SQLFormatter {

    // MARK: - Tokens

    enum Token {
        case word(String)         // identifier or keyword
        case number(String)
        case literal(String)      // 'text' — verbatim
        case quoted(String)       // "ident", `ident`, [ident] — verbatim
        case lineComment(String)  // -- ...
        case blockComment(String) // /* ... */
        case punct(String)

        var text: String {
            switch self {
            case .word(let s), .number(let s), .literal(let s), .quoted(let s),
                 .lineComment(let s), .blockComment(let s), .punct(let s):
                return s
            }
        }

        var isComment: Bool {
            if case .lineComment = self { return true }
            if case .blockComment = self { return true }
            return false
        }
    }

    static func tokenize(_ sql: String) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(sql)
        let n = chars.count
        var i = 0
        func peek(_ o: Int = 1) -> Character? { i + o < n ? chars[i + o] : nil }

        while i < n {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }

            if c == "-", peek() == "-" {                       // -- line comment
                var s = ""
                while i < n && chars[i] != "\n" { s.append(chars[i]); i += 1 }
                tokens.append(.lineComment(s.trimmingCharacters(in: .whitespaces)))
                continue
            }
            if c == "/", peek() == "*" {                       // /* block comment */
                var s = "/*"; i += 2
                while i < n {
                    if chars[i] == "*", peek() == "/" { s += "*/"; i += 2; break }
                    s.append(chars[i]); i += 1
                }
                tokens.append(.blockComment(s))
                continue
            }
            if c == "'" {                                      // 'literal' ('' escapes)
                var s = "'"; i += 1
                while i < n {
                    if chars[i] == "'" {
                        if peek() == "'" { s += "''"; i += 2; continue }
                        s.append("'"); i += 1; break
                    }
                    s.append(chars[i]); i += 1
                }
                tokens.append(.literal(s))
                continue
            }
            if c == "\"" || c == "`" {                         // quoted identifier
                let close = c
                var s = String(c); i += 1
                while i < n {
                    s.append(chars[i])
                    let done = chars[i] == close
                    i += 1
                    if done { break }
                }
                tokens.append(.quoted(s))
                continue
            }
            if c == "[" {                                      // [bracket identifier]
                var s = "["; i += 1
                while i < n {
                    s.append(chars[i])
                    let done = chars[i] == "]"
                    i += 1
                    if done { break }
                }
                tokens.append(.quoted(s))
                continue
            }
            if c.isNumber {                                    // number
                var s = ""
                while i < n, chars[i].isNumber || chars[i] == "." { s.append(chars[i]); i += 1 }
                tokens.append(.number(s))
                continue
            }
            if c.isLetter || c == "_" || c == "@" || c == "#" || c == "$" {
                var s = ""
                while i < n, chars[i].isLetter || chars[i].isNumber
                        || chars[i] == "_" || chars[i] == "$" || chars[i] == "@" || chars[i] == "#" {
                    s.append(chars[i]); i += 1
                }
                tokens.append(.word(s))
                continue
            }
            let two = i + 1 < n ? String([chars[i], chars[i + 1]]) : ""
            if ["<=", ">=", "<>", "!=", "||", "::", ":="].contains(two) {
                tokens.append(.punct(two)); i += 2; continue
            }
            tokens.append(.punct(String(c))); i += 1
        }
        return tokens
    }

    // MARK: - Vocabulary

    static let keywords: Set<String> = [
        "SELECT", "DISTINCT", "ALL", "FROM", "WHERE", "GROUP", "BY", "HAVING", "ORDER",
        "ASC", "DESC", "LIMIT", "OFFSET", "FETCH", "NEXT", "ROWS", "ONLY",
        "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "OUTER", "CROSS", "NATURAL", "ON", "USING",
        "UNION", "EXCEPT", "INTERSECT", "WITH", "RECURSIVE", "AS",
        "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "RETURNING",
        "CREATE", "ALTER", "DROP", "TABLE", "VIEW", "INDEX", "TRUNCATE", "ADD", "COLUMN",
        "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "UNIQUE", "CHECK", "DEFAULT",
        "NOT", "NULL", "AND", "OR", "IN", "EXISTS", "BETWEEN", "LIKE", "ILIKE", "IS",
        "CASE", "WHEN", "THEN", "ELSE", "END", "CAST", "OVER", "PARTITION",
        "TRUE", "FALSE", "IF", "CONSTRAINT", "GRANT", "BEGIN", "COMMIT", "ROLLBACK",
    ]

    /// Uppercased like keywords, but treated as function names for spacing
    /// (`COUNT(x)`, not `COUNT (x)`).
    static let functions: Set<String> = [
        "COUNT", "SUM", "AVG", "MIN", "MAX", "COALESCE", "NULLIF", "ROUND", "ABS",
        "UPPER", "LOWER", "SUBSTRING", "TRIM", "LENGTH", "CONCAT", "NOW", "DATE",
        "ROW_NUMBER", "RANK", "DENSE_RANK", "GREATEST", "LEAST",
    ]

    /// Clauses that begin a new line at the current statement indent.
    private static let clauseStarters: Set<String> = [
        "SELECT", "FROM", "WHERE", "HAVING", "VALUES", "SET", "RETURNING",
        "LIMIT", "OFFSET", "UNION", "EXCEPT", "INTERSECT", "WITH",
        "INSERT", "UPDATE", "DELETE", "CREATE", "ALTER", "DROP", "TRUNCATE",
        "GROUP", "ORDER", "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "CROSS", "NATURAL",
    ]

    /// Clauses laid out one level deeper than the clause they belong to.
    private static let indentedStarters: Set<String> = ["ON", "AND", "OR"]

    /// Clauses whose comma-separated items each get their own line.
    private static let listClauses: Set<String> = ["SELECT", "SET", "VALUES"]

    // MARK: - Pretty printing

    static func pretty(_ sql: String, indentUnit: String = "    ") -> String {
        let tokens = tokenize(sql)
        guard !tokens.isEmpty else { return sql }

        /// How the next `(` should be laid out.
        enum ParenKind {
            case inline      // f(x), (a + b) — hug, stay on the line
            case spaced      // INSERT INTO t (a, b) — space before, stay inline
            case block       // CREATE TABLE t ( … ) — break, one item per line
            case subquery    // ( SELECT … ) — break, indent as a statement
        }

        var out: [String] = []
        var line = ""
        var base = 0                        // statement indent level
        var listIndent: Int? = nil          // set while inside a list clause
        var parenDepth = 0                  // depth of inline parens in this clause
        var parenStack: [(kind: ParenKind, savedList: Int?)] = []
        var pendingParen: ParenKind? = nil  // set by CREATE TABLE / INSERT INTO

        func flush() {
            let trimmed = line.replacingOccurrences(of: " +$", with: "", options: .regularExpression)
            if !trimmed.trimmingCharacters(in: .whitespaces).isEmpty { out.append(trimmed) }
            line = ""
        }
        func startLine(_ level: Int) {
            flush()
            line = String(repeating: indentUnit, count: max(0, level))
        }
        func isLineEmpty() -> Bool { line.trimmingCharacters(in: .whitespaces).isEmpty }
        func emit(_ s: String, space: Bool) {
            if isLineEmpty() { line += s } else { line += (space ? " " : "") + s }
        }

        /// Should a space precede `tok` given the previous token?
        func spaceBefore(_ tok: Token, _ prev: Token?) -> Bool {
            guard let prev else { return false }
            let t = tok.text
            if [",", ";", ")", ".", "::"].contains(t) { return false }
            if prev.text == "(" || prev.text == "." || prev.text == "::" { return false }
            if t == "(" {
                if case .word(let w) = prev {
                    let up = w.uppercased()
                    // Function call or a bare identifier → hug the paren.
                    return !(functions.contains(up) || !keywords.contains(up))
                }
                return prev.text != ")"
            }
            return true
        }

        /// Index of the next non-comment token after `i`.
        func nextMeaningful(_ i: Int) -> Int? {
            var j = i + 1
            while j < tokens.count, tokens[j].isComment { j += 1 }
            return j < tokens.count ? j : nil
        }

        /// Collect a multi-word clause header (GROUP BY, LEFT OUTER JOIN, …).
        func clausePhrase(at i: Int) -> (phrase: String, consumed: Int) {
            var words: [String] = []
            var j = i
            func wordAt(_ k: Int) -> String? {
                guard k < tokens.count, case .word(let w) = tokens[k] else { return nil }
                return w.uppercased()
            }
            let first = wordAt(i)!
            words.append(first)
            j += 1

            switch first {
            case "GROUP", "ORDER":
                if wordAt(j) == "BY" { words.append("BY"); j += 1 }
            case "INNER", "CROSS", "NATURAL":
                if wordAt(j) == "JOIN" { words.append("JOIN"); j += 1 }
            case "LEFT", "RIGHT", "FULL":
                if wordAt(j) == "OUTER" { words.append("OUTER"); j += 1 }
                if wordAt(j) == "JOIN" { words.append("JOIN"); j += 1 }
            case "INSERT":
                if wordAt(j) == "INTO" { words.append("INTO"); j += 1 }
            case "DELETE":
                if wordAt(j) == "FROM" { words.append("FROM"); j += 1 }
            case "UNION":
                if wordAt(j) == "ALL" { words.append("ALL"); j += 1 }
            case "SELECT":
                if wordAt(j) == "DISTINCT" { words.append("DISTINCT"); j += 1 }
            case "CREATE", "ALTER", "DROP":
                if wordAt(j) == "TABLE" || wordAt(j) == "VIEW" || wordAt(j) == "INDEX" {
                    words.append(wordAt(j)!); j += 1
                }
            default:
                break
            }
            return (words.joined(separator: " "), j - i)
        }

        /// True when the clause beginning at `i` has a top-level comma before the
        /// next clause — i.e. its list is worth breaking onto separate lines.
        func listHasMultipleItems(from i: Int) -> Bool {
            var depth = 0
            var j = i
            while j < tokens.count {
                let t = tokens[j]
                if t.text == "(" { depth += 1 }
                else if t.text == ")" { depth -= 1; if depth < 0 { return false } }
                else if t.text == ";" { return false }
                else if t.text == "," && depth == 0 { return true }
                else if case .word(let w) = t, depth == 0, j > i {
                    let up = w.uppercased()
                    if clauseStarters.contains(up) || indentedStarters.contains(up) { return false }
                }
                j += 1
            }
            return false
        }

        var prev: Token? = nil
        var i = 0
        while i < tokens.count {
            let tok = tokens[i]

            switch tok {
            case .lineComment, .blockComment:
                // Keep a trailing comment on the current line; otherwise give it its own.
                if isLineEmpty() {
                    startLine(listIndent ?? base)
                    line += tok.text
                    flush()
                } else {
                    emit(tok.text, space: true)
                }
                prev = tok
                i += 1
                continue

            case .word(let raw):
                let up = raw.uppercased()
                let isKeyword = keywords.contains(up)
                let isFunction = functions.contains(up)
                let rendered = (isKeyword || isFunction) ? up : raw

                // A clause header only starts a line at the top level of its statement.
                if isKeyword, parenDepth == 0, clauseStarters.contains(up) {
                    let (phrase, consumed) = clausePhrase(at: i)
                    startLine(base)
                    line += phrase
                    listIndent = nil

                    if listClauses.contains(up) {
                        let after = i + consumed
                        if listHasMultipleItems(from: after) {
                            listIndent = base + 1
                            startLine(base + 1)
                        }
                    }
                    // The parenthesised column list after CREATE TABLE / INSERT INTO
                    // isn't a function call: it wants a space, and for CREATE it
                    // breaks onto its own lines.
                    if phrase.hasPrefix("CREATE TABLE") { pendingParen = .block }
                    else if phrase == "INSERT INTO" { pendingParen = .spaced }

                    prev = tokens[i + consumed - 1]
                    i += consumed
                    continue
                }

                if isKeyword, parenDepth == 0, indentedStarters.contains(up) {
                    startLine(base + 1)
                    line += up
                    prev = tok
                    i += 1
                    continue
                }

                emit(rendered, space: spaceBefore(tok, prev))
                prev = tok
                i += 1
                continue

            case .punct(let p):
                switch p {
                case "(":
                    let opensSubquery: Bool = {
                        guard let j = nextMeaningful(i), case .word(let w) = tokens[j] else { return false }
                        let up = w.uppercased()
                        return up == "SELECT" || up == "WITH"
                    }()
                    let kind: ParenKind = opensSubquery ? .subquery : (pendingParen ?? .inline)
                    pendingParen = nil

                    switch kind {
                    case .inline:
                        emit("(", space: spaceBefore(tok, prev))
                        parenDepth += 1
                    case .spaced:
                        emit("(", space: true)
                        parenDepth += 1
                    case .block, .subquery:
                        emit("(", space: kind == .subquery ? spaceBefore(tok, prev) : true)
                        base += 1
                        startLine(base)
                    }
                    parenStack.append((kind, listIndent))
                    if kind == .block { listIndent = base }
                    prev = tok
                    i += 1
                    continue

                case ")":
                    let entry = parenStack.popLast()
                    switch entry?.kind {
                    case .block, .subquery:
                        base = max(0, base - 1)
                        listIndent = entry?.savedList ?? nil
                        startLine(base)
                        line += ")"
                    default:
                        parenDepth = max(0, parenDepth - 1)
                        emit(")", space: false)
                    }
                    prev = tok
                    i += 1
                    continue

                case ",":
                    emit(",", space: false)
                    let inBlock = parenStack.last?.kind == .block
                    if let li = listIndent, parenDepth == 0 || inBlock {
                        startLine(li)
                    }
                    prev = tok
                    i += 1
                    continue

                case ";":
                    emit(";", space: false)
                    flush()
                    out.append("")          // blank line between statements
                    base = 0
                    parenDepth = 0
                    listIndent = nil
                    parenStack.removeAll()
                    pendingParen = nil
                    prev = nil
                    i += 1
                    continue

                default:
                    emit(p, space: spaceBefore(tok, prev))
                    prev = tok
                    i += 1
                    continue
                }

            case .number, .literal, .quoted:
                emit(tok.text, space: spaceBefore(tok, prev))
                prev = tok
                i += 1
                continue
            }
        }
        flush()

        // Drop a trailing blank line left by a final semicolon.
        while out.last?.isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n")
    }

    /// Collapse a statement onto a single line (keywords uppercased).
    static func compact(_ sql: String) -> String {
        let tokens = tokenize(sql)
        var parts: [String] = []
        var prev: Token? = nil
        for tok in tokens {
            // A line comment would swallow the rest of a single-line statement.
            if case .lineComment = tok { continue }
            var rendered = tok.text
            if case .word(let w) = tok {
                let up = w.uppercased()
                if keywords.contains(up) || functions.contains(up) { rendered = up }
            }
            let noSpace = [",", ";", ")", ".", "::"].contains(rendered)
                || prev?.text == "(" || prev?.text == "." || prev?.text == "::"
            if parts.isEmpty || noSpace {
                parts.append(rendered)
            } else if rendered == "(" , case .word(let w)? = prev,
                      functions.contains(w.uppercased()) || !keywords.contains(w.uppercased()) {
                parts.append(rendered)
            } else {
                parts.append(" " + rendered)
            }
            prev = tok
        }
        return parts.joined()
    }
}
