import AppKit
import Foundation

/// Headless verification of the core (non-UI) services. Run with `--selftest`.
/// Kept in the binary as a lightweight, dependency-free smoke test for the
/// validation / formatting / highlighting logic that can't be exercised through
/// the GUI in an automated environment.
enum SelfTest {
    static func run() -> Int32 {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if condition { print("  ok   \(name)") } else { print("  FAIL \(name)"); failures.append(name) }
        }

        let validators = Validators()
        let formatters = Formatters()

        print("== Validators ==")
        check("json valid", validators.validate(text: "{\"a\": [1, 2, true, null]}", mode: .json).isValid)

        let badJSON = validators.validate(text: "{\n  \"a\": 1,\n  \"b\": ,\n}", mode: .json)
        check("json invalid detected", !badJSON.isValid)
        check("json reports a line", badJSON.line != nil)
        print("       -> json error at line \(String(describing: badJSON.line)):\(String(describing: badJSON.column))")

        check("xml valid", validators.validate(text: "<root><a x=\"1\">hi</a></root>", mode: .xml).isValid)
        let badXML = validators.validate(text: "<root><a></root>", mode: .xml)
        check("xml invalid detected", !badXML.isValid)
        print("       -> xml error: \(badXML.message) @ \(String(describing: badXML.line)):\(String(describing: badXML.column))")

        check("yaml valid", validators.validate(text: "a: 1\nb:\n  c: 2\n", mode: .yaml).isValid)
        let tabYAML = validators.validate(text: "a:\n\tb: 1", mode: .yaml)
        check("yaml tab rejected", !tabYAML.isValid && tabYAML.line == 2)

        check("plaintext always valid", validators.validate(text: "anything <> {} ::", mode: .plainText).isValid)

        print("== Formatters ==")
        do {
            let pretty = try formatters.format("{\"b\":2,\"a\":1}", mode: .json, option: .jsonPretty)
            check("json pretty multi-line", pretty.contains("\n") && pretty.contains("\"a\""))
            let mini = try formatters.format(pretty, mode: .json, option: .jsonMinify)
            check("json minify single-line", !mini.contains("\n") && mini == "{\"a\":1,\"b\":2}")
        } catch { check("json format threw: \(error)", false) }

        do {
            let xml = try formatters.format("<root><a>1</a><b>2</b></root>", mode: .xml, option: .xmlPretty)
            check("xml pretty multi-line", xml.contains("\n") && xml.contains("<a>"))
        } catch { check("xml format threw: \(error)", false) }

        do {
            let reindented = try formatters.format("a: 1   \nb: 2\t\n", mode: .yaml, option: .yamlSafeReindent)
            check("yaml strips trailing spaces", !reindented.contains("1   "))
        } catch {
            // A tab present anywhere is treated as an unsafe rewrite — acceptable.
            check("yaml unsafe-rewrite guard", error is FormatterError)
        }
        do {
            _ = try formatters.format("x", mode: .plainText, option: .auto)
            check("plaintext format should throw", false)
        } catch { check("plaintext format throws unsupported", true) }

        print("== Format detection ==")
        // JSON pretty output should be multi-line and sorted; minified content
        // round-trips through pretty then minify.
        do {
            let pretty = try formatters.format("{\"b\":2,\"a\":1}", mode: .json, option: .jsonPretty)
            check("json pretty sorts keys (a before b)",
                  pretty.range(of: "\"a\"")!.lowerBound < pretty.range(of: "\"b\"")!.lowerBound)
        } catch { check("json pretty threw", false) }

        print("== URL transforms ==")
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let original = "a b/c?d=1&e=2%"
        let encoded = original.addingPercentEncoding(withAllowedCharacters: unreserved)
        check("url encode", encoded == "a%20b%2Fc%3Fd%3D1%26e%3D2%25")
        check("url decode round-trips", encoded?.removingPercentEncoding == original)
        check("url decode %2F -> /", "%2Fpath%2Fto".removingPercentEncoding == "/path/to")

        print("== Session persistence ==")
        // A saved untitled tab with unsaved text must round-trip through the
        // Codable model with its buffer and identity intact (the "wrote in a new
        // file, then quit" case). A clean on-disk file drops its text (re-read
        // from disk on restore), and the selected tab is remembered by id.
        do {
            let untitledID = UUID()
            let savedID = UUID()
            let tabs = [
                PersistedTab(id: untitledID, filePath: nil, languageOverride: .json,
                             text: "{\"draft\": true}", isDirty: true),
                PersistedTab(id: savedID, filePath: "/tmp/example.json", languageOverride: nil,
                             text: nil, isDirty: false),
            ]
            let state = SessionState(tabs: tabs, selectedID: savedID)
            let data = try JSONEncoder().encode(state)
            let back = try JSONDecoder().decode(SessionState.self, from: data)
            check("session round-trips tab count", back.tabs.count == 2)
            check("session keeps unsaved buffer", back.tabs[0].text == "{\"draft\": true}")
            check("session keeps untitled path nil", back.tabs[0].filePath == nil)
            check("session preserves tab id", back.tabs[0].id == untitledID)
            check("session drops clean-file text", back.tabs[1].text == nil)
            check("session remembers selection", back.selectedID == savedID)
        } catch { check("session persistence threw: \(error)", false) }

        print("== SQL formatter ==")
        let messySQL = "select id,name,email from users u left join orders o on o.user_id=u.id where u.active=1 and o.total>100 order by u.name desc;"
        let prettySQL = SQLFormatter.pretty(messySQL)
        let sqlWithString = "select * from t where note='it''s a -- trap, not a comment' and x=1"
        let prettyStr = SQLFormatter.pretty(sqlWithString)

        check("sql uppercases keywords", prettySQL.contains("SELECT") && prettySQL.contains("LEFT JOIN"))
        check("sql keeps identifiers as written", prettySQL.contains("users") && prettySQL.contains("email"))
        check("sql breaks major clauses onto lines", prettySQL.contains("\nFROM") && prettySQL.contains("\nWHERE"))
        check("sql puts AND on its own line", prettySQL.contains("\n    AND"))
        check("sql keeps ORDER BY together", prettySQL.contains("ORDER BY"))
        check("sql literal preserved verbatim", prettyStr.contains("'it''s a -- trap, not a comment'"))
        check("sql compact is single line", !SQLFormatter.compact(messySQL).contains("\n"))
        check("sql compact preserves literal",
              SQLFormatter.compact(sqlWithString).contains("'it''s a -- trap, not a comment'"))
        check("sql function hugs paren", SQLFormatter.compact("select count( * ) from t").contains("COUNT(*)"))

        let ins = SQLFormatter.pretty("insert into t (a,b,c) values (1,'x',3),(4,'y',6);")
        check("sql INSERT column list spaced + inline", ins.contains("INSERT INTO t (a, b, c)"))
        check("sql VALUES rows one per line", ins.contains("\n    (1, 'x', 3),\n    (4, 'y', 6)"))
        let cre = SQLFormatter.pretty("create table t (id int primary key, name varchar(50) not null);")
        check("sql CREATE breaks columns", cre.contains("CREATE TABLE t (\n    id int PRIMARY KEY,"))
        check("sql CREATE keeps type paren inline", cre.contains("varchar(50)"))
        let cmt = SQLFormatter.pretty("select a /* x */ from t; -- tail")
        check("sql keeps inline block comment", cmt.contains("/* x */"))
        check("sql validator flags unclosed quote",
              !validators.validate(text: "select 'oops from t", mode: .sql).isValid)
        check("sql validator flags unbalanced paren",
              !validators.validate(text: "select (a from t", mode: .sql).isValid)
        check("sql validator ignores -- and quotes",
              validators.validate(text: "select '(' as x -- ) note\nfrom t", mode: .sql).isValid)

        print("== LLM config ==")
        // Blank model / base URL fall back to provider defaults; a set value wins.
        let anthDefault = LLMConfig(provider: .anthropic, apiKey: "  k  ", model: "", baseURL: "")
        check("anthropic default model", anthDefault.model == "claude-opus-4-8")
        check("anthropic default base URL", anthDefault.baseURL == "https://api.anthropic.com")
        check("api key is trimmed", anthDefault.apiKey == "k")
        check("configured when key present", anthDefault.isConfigured)

        let openDefault = LLMConfig(provider: .openAICompatible, apiKey: "", model: "", baseURL: "")
        check("openai default model", openDefault.model == "gpt-4o")
        check("openai default base URL", openDefault.baseURL == "https://api.openai.com/v1")
        check("not configured without key", !openDefault.isConfigured)

        let custom = LLMConfig(provider: .openAICompatible, apiKey: "k",
                               model: "llama3", baseURL: "http://localhost:11434/v1/")
        check("custom model overrides default", custom.model == "llama3")
        check("trailing slash stripped from base URL", custom.baseURL == "http://localhost:11434/v1")

        print("== Diff engine ==")
        let identical = DiffEngine.diff(left: "a\nb\nc", right: "a\nb\nc")
        check("identical files report no changes", identical.isIdentical)
        check("identical files: 0 added / 0 removed", identical.addedCount == 0 && identical.removedCount == 0)

        // Right adds a line, changes one, and keeps the rest.
        let d = DiffEngine.diff(left: "one\ntwo\nthree", right: "one\nTWO\nthree\nfour")
        check("diff detects an added line", d.addedCount >= 1)
        check("diff detects a removed line", d.removedCount >= 1)
        check("diff keeps common lines aligned",
              d.rows.contains { $0.kind == .equal && $0.leftText == "one" })
        check("changed line: old side present as removed",
              d.rows.contains { $0.kind == .removed && $0.leftText == "two" })
        check("changed line: new side present as added",
              d.rows.contains { $0.kind == .added && $0.rightText == "TWO" })
        check("appended line shows as added",
              d.rows.contains { $0.kind == .added && $0.rightText == "four" })

        // Trailing newline shouldn't manufacture a phantom line.
        let nl = DiffEngine.diff(left: "x\n", right: "x")
        check("trailing newline ignored", nl.isIdentical)

        print("== Highlighter ==")
        let highlighter = SyntaxHighlighter()
        let storage = NSTextStorage(string: "{\"key\": \"value\", \"n\": 42, \"ok\": true}")
        highlighter.highlight(textStorage: storage, language: .json)
        var colored = false
        storage.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let color = value as? NSColor, color != NSColor.labelColor { colored = true }
        }
        check("json highlighting applied some color", colored)

        // Range-limited highlight must not crash and must stay within bounds.
        highlighter.highlight(textStorage: storage, language: .json, range: NSRange(location: 2, length: 5))
        check("ranged highlight survived", true)

        print("== Auto-save ==")
        // Only dirty documents that already have a file are written on a timer;
        // an untitled tab would need a save panel, which a timer must not open.
        let dirtyFile = EditorDocument(fileURL: URL(fileURLWithPath: "/tmp/a.json"), text: "x", isDirty: true)
        let cleanFile = EditorDocument(fileURL: URL(fileURLWithPath: "/tmp/b.json"), text: "x", isDirty: false)
        let dirtyUntitled = EditorDocument(fileURL: nil, text: "x", isDirty: true)
        check("auto-save takes dirty on-disk files", EditorWorkspace.shouldAutoSave(dirtyFile))
        check("auto-save skips clean files", !EditorWorkspace.shouldAutoSave(cleanFile))
        check("auto-save skips untitled tabs", !EditorWorkspace.shouldAutoSave(dirtyUntitled))

        print("== Vim engine ==")
        // Driven against an in-memory buffer, so every command below is checked
        // without a window. `feed` mirrors what the real view does: keys the
        // engine declines (insert mode) get inserted at the caret.
        func vim(_ initial: String, caret: Int = 0) -> (VimEngine, VimTestBuffer) {
            let buffer = VimTestBuffer(initial, caret: caret)
            let engine = VimEngine(target: buffer)
            engine.reset()
            return (engine, buffer)
        }
        func feed(_ engine: VimEngine, _ buffer: VimTestBuffer, _ keys: String) {
            for c in keys where !engine.handle(key: VimKey(c)) {
                buffer.insertAtCaret(String(c))
            }
        }
        /// Run `keys` on `initial` and compare the resulting buffer.
        func vimCheck(_ name: String, _ initial: String, _ keys: String, _ expected: String, caret: Int = 0) {
            let (engine, buffer) = vim(initial, caret: caret)
            feed(engine, buffer, keys)
            let got = buffer.storage as String
            check(name, got == expected)
            if got != expected {
                print("       -> expected \(expected.debugDescription), got \(got.debugDescription)")
            }
        }
        let esc = "\u{1b}"

        // Motions and the "caret sits on a character" rule.
        let (motionEngine, motionBuffer) = vim("hello world\nsecond line")
        feed(motionEngine, motionBuffer, "ll")
        check("vim l moves right", motionEngine.caret == 2)
        feed(motionEngine, motionBuffer, "$")
        check("vim $ stops on last char", motionEngine.caret == 10)
        feed(motionEngine, motionBuffer, "j")
        check("vim j keeps desired column", motionEngine.caret == 12 + 10)
        feed(motionEngine, motionBuffer, "0")
        check("vim 0 goes to line start", motionEngine.caret == 12)
        feed(motionEngine, motionBuffer, "gg")
        check("vim gg goes to first line", motionEngine.caret == 0)
        feed(motionEngine, motionBuffer, "w")
        check("vim w moves to next word", motionEngine.caret == 6)
        feed(motionEngine, motionBuffer, "G")
        check("vim G goes to last line", motionEngine.caret == 12)

        vimCheck("vim x deletes under caret", "abc", "x", "bc")
        vimCheck("vim 3x deletes with count", "abcdef", "3x", "def")
        vimCheck("vim dw deletes a word", "hello world", "dw", "world")
        vimCheck("vim dw stops at line end", "hello\nworld", "dw", "\nworld")
        vimCheck("vim dd deletes a line", "one\ntwo\nthree", "jdd", "one\nthree")
        vimCheck("vim 2dd deletes two lines", "one\ntwo\nthree", "2dd", "three")
        vimCheck("vim D deletes to line end", "hello world", "wD", "hello ")
        vimCheck("vim de is inclusive", "hello world", "de", " world")
        vimCheck("vim db deletes backwards", "hello world", "$db", "hello d")
        vimCheck("vim yy + p duplicates a line", "one\ntwo", "yyp", "one\none\ntwo")
        vimCheck("vim ddp swaps lines", "one\ntwo", "ddp", "two\none")
        vimCheck("vim charwise yank + paste", "abc", "ylp", "aabc")
        vimCheck("vim P pastes before", "one\ntwo", "yyjP", "one\none\ntwo")

        // Insert-mode entries.
        vimCheck("vim i inserts before caret", "bc", "iaX" + esc, "aXbc")
        vimCheck("vim a inserts after caret", "ac", "ab" + esc, "abc")
        vimCheck("vim A appends at line end", "ab", "Ac" + esc, "abc")
        vimCheck("vim I inserts at first non-blank", "  ab", "IX" + esc, "  Xab")
        vimCheck("vim o opens a line below", "a\nb", "oX" + esc, "a\nX\nb")
        vimCheck("vim O opens a line above", "a\nb", "OX" + esc, "X\na\nb")
        vimCheck("vim o keeps indentation", "    a", "oX" + esc, "    a\n    X")
        vimCheck("vim cw changes a word", "hello world", "cwbye" + esc, "bye world")
        vimCheck("vim cc keeps indent, clears line", "  one\ntwo", "ccx" + esc, "  x\ntwo")
        vimCheck("vim s substitutes a char", "abc", "sX" + esc, "Xbc")

        // Character search, brackets, joins, case.
        vimCheck("vim df, deletes through a char", "a,b,c", "df,", "b,c")
        vimCheck("vim dt, stops before a char", "a,b,c", "dt,", ",b,c")
        vimCheck("vim d% deletes a bracket pair", "f(a, b) end", "wd%", "f end")
        vimCheck("vim J joins lines with a space", "one\ntwo", "J", "one two")
        vimCheck("vim J drops leading indent", "one\n    two", "J", "one two")
        vimCheck("vim r replaces a character", "abc", "rZ", "Zbc")
        vimCheck("vim ~ toggles case", "abc", "~~", "ABc")
        vimCheck("vim gUiw uppercases a word", "hello world", "gUiw", "HELLO world")
        vimCheck("vim >> indents a line", "a\nb", ">>", "    a\nb")
        vimCheck("vim << outdents a line", "      a", "<<", "  a")

        // Text objects.
        vimCheck("vim diw deletes inner word", "one two three", "wdiw", "one  three")
        vimCheck("vim daw takes the space too", "one two three", "wdaw", "one three")
        vimCheck("vim ci\" changes inside quotes", "say \"old\" now", "f\"ci\"new" + esc, "say \"new\" now")
        vimCheck("vim di( deletes inside parens", "f(a + b)", "3ldi(", "f()")
        vimCheck("vim da{ takes the braces", "x{a}y", "fada{", "xy")

        // Visual mode.
        vimCheck("vim v + motion + d", "hello world", "vlld", "lo world")
        vimCheck("vim V d is linewise", "one\ntwo\nthree", "jVd", "one\nthree")
        vimCheck("vim visual y then p", "abcd", "vly$p", "abcdab")
        vimCheck("vim visual U uppercases", "abcd", "vlU", "ABcd")
        vimCheck("vim visual > indents", "a\nb", "Vj>", "    a\n    b")
        let (visualEngine, visualBuffer) = vim("hello")
        feed(visualEngine, visualBuffer, "v")
        check("vim v enters visual mode", visualEngine.mode == .visual)
        feed(visualEngine, visualBuffer, "ll")
        check("vim visual selection is inclusive", visualBuffer.selection == NSRange(location: 0, length: 3))
        feed(visualEngine, visualBuffer, esc)
        check("vim Esc leaves visual mode", visualEngine.mode == .normal)

        // Search.
        let (searchEngine, searchBuffer) = vim("alpha\nbeta\nalpha again")
        feed(searchEngine, searchBuffer, "/alpha\r")
        check("vim / finds the next match", searchEngine.caret == 11)
        feed(searchEngine, searchBuffer, "n")
        check("vim n wraps around", searchEngine.caret == 0)
        let (starEngine, starBuffer) = vim("foo bar\nfoo baz")
        feed(starEngine, starBuffer, "*")
        check("vim * searches the word under the caret", starEngine.caret == 8)

        // Ex commands.
        vimCheck("vim :s replaces on the current line", "aaa\naaa", ":s/a/b/\r", "baa\naaa")
        vimCheck("vim :s with g flag", "aaa\naaa", ":s/a/b/g\r", "bbb\naaa")
        vimCheck("vim :%s replaces everywhere", "aaa\naaa", ":%s/a/b/g\r", "bbb\nbbb")
        let (exEngine, exBuffer) = vim("one\ntwo\nthree")
        feed(exEngine, exBuffer, ":3\r")
        check("vim :{number} jumps to a line", exEngine.caret == 8)
        var fileCommands: [VimFileCommand] = []
        exEngine.onFileCommand = { fileCommands.append($0) }
        feed(exEngine, exBuffer, ":w\r")
        feed(exEngine, exBuffer, ":q!\r")
        check("vim :w and :q! reach the workspace", fileCommands == [.write, .forceQuit])

        // Dot-repeat and undo.
        vimCheck("vim . repeats a delete", "abcdef", "x..", "def")
        vimCheck("vim . repeats an insert", "xy", "ia" + esc + "l.", "aaxy")
        let (undoEngine, undoBuffer) = vim("hello")
        feed(undoEngine, undoBuffer, "xx")
        check("vim two deletes applied", (undoBuffer.storage as String) == "llo")
        feed(undoEngine, undoBuffer, "u")
        check("vim u undoes one change", (undoBuffer.storage as String) == "ello")
        feed(undoEngine, undoBuffer, "\u{12}")   // Ctrl-R handled as a plain key here
        check("vim mode is normal after undo", undoEngine.mode == .normal)

        // Mode bookkeeping the status bar depends on.
        let (modeEngine, modeBuffer) = vim("abc")
        feed(modeEngine, modeBuffer, "i")
        check("vim i enters insert mode", modeEngine.mode == .insert)
        check("vim insert mode passes keys through", !modeEngine.handle(key: VimKey("q")))
        feed(modeEngine, modeBuffer, esc)
        check("vim Esc returns to normal mode", modeEngine.mode == .normal)
        check("vim status reports the mode", modeEngine.status.mode == .normal && modeEngine.status.enabled)
        feed(modeEngine, modeBuffer, ":")
        check("vim : opens the command line", modeEngine.status.commandLine == ":")
        feed(modeEngine, modeBuffer, esc)
        check("vim Esc closes the command line", modeEngine.status.commandLine == nil)

        print("")
        if failures.isEmpty {
            print("SELFTEST PASSED (all checks)")
            return 0
        } else {
            print("SELFTEST FAILED: \(failures.count) — \(failures.joined(separator: ", "))")
            return 1
        }
    }
}

/// In-memory stand-in for the editor's text view, so `VimEngine` can be driven
/// without AppKit. Undo is a plain snapshot stack, which is enough to check
/// that `u` reverts exactly one command.
final class VimTestBuffer: VimTextTarget {
    let storage: NSMutableString
    var selection: NSRange
    var beeps = 0
    private var undoStack: [(text: String, selection: NSRange)] = []
    private var redoStack: [(text: String, selection: NSRange)] = []

    init(_ text: String, caret: Int = 0) {
        storage = NSMutableString(string: text)
        selection = NSRange(location: caret, length: 0)
    }

    var vimString: NSString { storage }

    var vimSelection: NSRange {
        get { selection }
        set { selection = newValue }
    }

    func vimReplace(_ range: NSRange, with text: String) {
        undoStack.append((storage as String, selection))
        redoStack.removeAll()
        storage.replaceCharacters(in: range, with: text)
    }

    /// What `NSTextView` would do with a key the engine declined.
    func insertAtCaret(_ text: String) {
        undoStack.append((storage as String, selection))
        storage.replaceCharacters(in: NSRange(location: selection.location, length: 0), with: text)
        selection = NSRange(location: selection.location + (text as NSString).length, length: 0)
    }

    func vimScrollCaretVisible() {}
    func vimAlignCaret(_ align: VimScrollAlign) {}
    func vimFlash(_ range: NSRange) {}

    func vimUndo() {
        guard let previous = undoStack.popLast() else { beeps += 1; return }
        redoStack.append((storage as String, selection))
        storage.setString(previous.text)
        selection = previous.selection
    }

    func vimRedo() {
        guard let next = redoStack.popLast() else { beeps += 1; return }
        undoStack.append((storage as String, selection))
        storage.setString(next.text)
        selection = next.selection
    }

    func vimBeep() { beeps += 1 }

    var vimLinesPerPage: Int { 20 }
}
