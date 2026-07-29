import Foundation

/// Minimal NGINX configuration tokenizer + pretty printer.
///
/// Follows nginx's own lexer where it matters: `#` only opens a comment at the
/// start of a token, quotes only open a string at the start of a token, and
/// `;`, `{` and `}` always terminate the token they touch. Formatting changes
/// nothing but whitespace — a directive's arguments are re-emitted exactly as
/// they were written, so regexes, variables and quoted values survive intact.
enum NginxFormatter {

    // MARK: - Tokens

    struct Token {
        enum Kind {
            case word          // directive name or argument
            case string        // "..." / '...', quotes included
            case comment       // # … to end of line
            case openBrace
            case closeBrace
            case semicolon
        }

        let kind: Kind
        let text: String
        let line: Int
        let column: Int
        /// Source newlines between the previous token and this one — the only
        /// vertical whitespace the formatter preserves.
        let newlinesBefore: Int
    }

    struct LexError {
        let message: String
        let line: Int
        let column: Int
    }

    struct Lexed {
        let tokens: [Token]
        /// Set when scanning stopped early; `tokens` holds everything read so far.
        let error: LexError?
    }

    static func lex(_ text: String) -> Lexed {
        var tokens: [Token] = []
        let chars = Array(text)
        let n = chars.count
        var i = 0, line = 1, col = 1
        var newlines = 0

        func advance() {
            if chars[i] == "\n" { line += 1; col = 1 } else { col += 1 }
            i += 1
        }
        func append(_ kind: Token.Kind, _ s: String, _ l: Int, _ c: Int, _ before: Int) {
            tokens.append(Token(kind: kind, text: s, line: l, column: c, newlinesBefore: before))
        }

        while i < n {
            let c = chars[i]
            if c.isWhitespace {
                if c == "\n" { newlines += 1 }
                advance()
                continue
            }

            let startLine = line, startCol = col, before = newlines
            newlines = 0

            if c == "#" {
                var s = ""
                while i < n, chars[i] != "\n" { s.append(chars[i]); advance() }
                append(.comment, s.trimmedTrailingWhitespace, startLine, startCol, before)
                continue
            }

            if c == "\"" || c == "'" {
                let quote = c
                var s = String(c)
                advance()
                var closed = false
                while i < n {
                    let ch = chars[i]
                    if ch == "\\", i + 1 < n {          // \" and \' don't close
                        s.append(ch); advance()
                        s.append(chars[i]); advance()
                        continue
                    }
                    s.append(ch); advance()
                    if ch == quote { closed = true; break }
                }
                append(.string, s, startLine, startCol, before)
                if !closed {
                    return Lexed(tokens: tokens,
                                 error: LexError(message: "Unterminated quoted string",
                                                 line: startLine, column: startCol))
                }
                continue
            }

            if c == "{" { append(.openBrace, "{", startLine, startCol, before); advance(); continue }
            if c == "}" { append(.closeBrace, "}", startLine, startCol, before); advance(); continue }
            if c == ";" { append(.semicolon, ";", startLine, startCol, before); advance(); continue }

            var s = ""
            while i < n {
                let ch = chars[i]
                if ch.isWhitespace || ch == "{" || ch == "}" || ch == ";" { break }
                s.append(ch); advance()
            }
            append(.word, s, startLine, startCol, before)
        }

        return Lexed(tokens: tokens, error: nil)
    }

    // MARK: - Pretty printing

    /// Re-lay out a config: one directive per line, blocks indented by one unit
    /// per `{`, arguments separated by a single space. A blank line in the source
    /// is kept (collapsed to one); trailing comments stay on their directive.
    ///
    /// Input that doesn't lex (an unterminated quote) is returned unchanged.
    static func pretty(_ text: String, indentUnit: String = "    ") -> String {
        let lexed = lex(text)
        guard lexed.error == nil, !lexed.tokens.isEmpty else { return text }

        var out: [String] = []
        var depth = 0
        var pending: [String] = []            // arguments of the directive being built
        var deferred: [String] = []           // comments seen mid-directive
        var blankBeforeNext = false

        func indent(_ level: Int) -> String { String(repeating: indentUnit, count: max(0, level)) }

        func emit(_ line: String) {
            if blankBeforeNext, out.last?.isEmpty == false { out.append("") }
            blankBeforeNext = false
            if deferred.isEmpty {
                out.append(line)
            } else {
                out.append(line + "  " + deferred.joined(separator: " "))
                deferred.removeAll()
            }
        }

        /// Remember whether the logical line starting at `token` was preceded by
        /// a blank line, so `emit` can reproduce it.
        func openLogicalLine(_ token: Token) {
            blankBeforeNext = token.newlinesBefore >= 2 && !out.isEmpty
        }

        for token in lexed.tokens {
            switch token.kind {
            case .comment:
                if token.newlinesBefore == 0, pending.isEmpty, deferred.isEmpty,
                   let last = out.last, !last.isEmpty {
                    out[out.count - 1] = last + "  " + token.text   // trailing comment stays put
                } else if pending.isEmpty {
                    openLogicalLine(token)
                    emit(indent(depth) + token.text)
                } else {
                    deferred.append(token.text)
                }

            case .word, .string:
                if pending.isEmpty { openLogicalLine(token) }
                pending.append(token.text)

            case .semicolon:
                guard !pending.isEmpty else { continue }            // stray ';' — drop it
                emit(indent(depth) + pending.joined(separator: " ") + ";")
                pending.removeAll()

            case .openBrace:
                let header = pending.joined(separator: " ")
                pending.removeAll()
                if header.isEmpty { openLogicalLine(token) }
                emit(indent(depth) + (header.isEmpty ? "{" : header + " {"))
                depth += 1

            case .closeBrace:
                if !pending.isEmpty {                               // directive missing its ';'
                    emit(indent(depth) + pending.joined(separator: " "))
                    pending.removeAll()
                }
                depth = max(0, depth - 1)
                blankBeforeNext = false                             // no blank line before '}'
                emit(indent(depth) + "}")
            }
        }

        if !pending.isEmpty { emit(indent(depth) + pending.joined(separator: " ")) }
        if !deferred.isEmpty { emit(indent(depth) + deferred.removeFirst()) }

        while out.last?.isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n")
    }

    // MARK: - Structure check

    /// Structural problems nginx itself would reject: unbalanced braces, a
    /// directive with no terminating `;`, or a `{`/`;` with nothing in front of
    /// it. Directive *names* aren't checked — modules define their own.
    static func structuralError(in text: String) -> LexError? {
        let lexed = lex(text)
        if let error = lexed.error { return error }

        var blocks: [Token] = []          // open '{' tokens
        var start: Token? = nil           // first token of the directive being read

        for token in lexed.tokens {
            switch token.kind {
            case .comment:
                continue

            case .word, .string:
                if start == nil { start = token }

            case .semicolon:
                guard start != nil else {
                    return LexError(message: "Unexpected ';' — no directive to end",
                                    line: token.line, column: token.column)
                }
                start = nil

            case .openBrace:
                guard start != nil else {
                    return LexError(message: "Block has no directive name before '{'",
                                    line: token.line, column: token.column)
                }
                start = nil
                blocks.append(token)

            case .closeBrace:
                if let open = start {
                    return LexError(message: "Directive is missing a ';'",
                                    line: open.line, column: open.column)
                }
                guard !blocks.isEmpty else {
                    return LexError(message: "Unexpected '}' — no open block",
                                    line: token.line, column: token.column)
                }
                blocks.removeLast()
            }
        }

        if let open = start {
            return LexError(message: "Directive is missing a ';'", line: open.line, column: open.column)
        }
        if let open = blocks.last {
            return LexError(message: "Unclosed '{' — block is never closed",
                            line: open.line, column: open.column)
        }
        return nil
    }

    // MARK: - Vocabulary

    /// Directives that open a block. Used to recognise a config by sight when a
    /// plain-text buffer is formatted, and shared with the highlighter.
    static let blockDirectives: Set<String> = [
        "http", "server", "location", "events", "upstream", "mail", "stream",
        "map", "types", "if", "limit_except", "geo", "split_clients", "charset_map",
    ]

    /// Common directives, for highlighting. Not exhaustive — any word in
    /// directive position is highlighted, this set only exists so the
    /// well-known ones read consistently.
    static let commonDirectives: Set<String> = [
        "listen", "server_name", "root", "index", "include", "proxy_pass",
        "proxy_set_header", "return", "rewrite", "try_files", "access_log",
        "error_log", "worker_processes", "worker_connections", "keepalive_timeout",
        "sendfile", "gzip", "ssl_certificate", "ssl_certificate_key", "add_header",
        "client_max_body_size", "fastcgi_pass", "fastcgi_param", "alias", "expires",
        "user", "pid", "default_type", "log_format", "set", "deny", "allow",
    ]

    /// True when `text` reads like an nginx config: a block directive opening a
    /// brace, plus at least one `;`-terminated directive. Deliberately strict —
    /// this decides whether an unlabelled buffer gets reformatted as nginx.
    static func looksLikeConfig(_ text: String) -> Bool {
        let lexed = lex(text)
        guard lexed.error == nil else { return false }

        var sawBlock = false
        var sawDirective = false
        var previous: Token? = nil

        for token in lexed.tokens {
            switch token.kind {
            case .openBrace:
                if let p = previous, p.kind == .word, blockDirectives.contains(p.text.lowercased()) {
                    sawBlock = true
                }
                // `location /foo {`, `if ($x) {` — the name is further back.
                if !sawBlock, let p = previous, p.kind != .openBrace {
                    sawBlock = headOfLine(before: token, in: lexed.tokens)
                }
            case .semicolon:
                sawDirective = true
            default:
                break
            }
            if token.kind != .comment { previous = token }
            if sawBlock && sawDirective { return true }
        }
        return false
    }

    /// Whether the first word of the logical line ending at `brace` is a known
    /// block directive (`location … {`, `if (…) {`).
    private static func headOfLine(before brace: Token, in tokens: [Token]) -> Bool {
        guard let index = tokens.firstIndex(where: { $0.line == brace.line && $0.column == brace.column }) else {
            return false
        }
        var head: Token? = nil
        var i = index - 1
        while i >= 0 {
            let token = tokens[i]
            if token.kind == .semicolon || token.kind == .openBrace || token.kind == .closeBrace { break }
            if token.kind == .word { head = token }
            i -= 1
        }
        guard let head else { return false }
        return blockDirectives.contains(head.text.lowercased())
    }
}

private extension String {
    var trimmedTrailingWhitespace: String {
        replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
    }
}
