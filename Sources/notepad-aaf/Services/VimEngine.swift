import Foundation

/// A modal (Vim) keyboard layer for the editor.
///
/// The engine is a pure state machine over a `VimTextTarget`: it never touches
/// AppKit, so the entire command set is exercised headlessly in `SelfTest`
/// against an in-memory buffer. The view layer's only jobs are to translate
/// `NSEvent`s into `VimKey`s, to feed them here, and to let keys through to
/// `NSTextView` untouched while we're in insert mode.
///
/// Supported: counts, operators (`d c y > < gu gU`) with motions and text
/// objects, character/line visual modes, registers (unnamed), search (`/ ? n N
/// * #`), `:` commands (`w q wq x q! {line} s//`), dot-repeat, and the usual
/// single-key commands (`x p J r ~ o O A I u` …).
///
/// Deliberately not implemented: visual-block, named registers, marks, macros,
/// replace mode (`R`), and Vim-flavoured regex (search/`:s` take ICU patterns).
final class VimEngine {

    // MARK: - Types

    enum Operator: Equatable {
        case delete, change, yank, indent, outdent, lowercase, uppercase
        /// `dd` / `yy` / `>>` — the doubled key that makes an operator linewise.
        var doubledKey: Character {
            switch self {
            case .delete: return "d"
            case .change: return "c"
            case .yank: return "y"
            case .indent: return ">"
            case .outdent: return "<"
            case .lowercase, .uppercase: return "u"
            }
        }
    }

    enum MotionKind { case exclusive, inclusive, linewise }

    struct Register: Equatable {
        var text: String = ""
        var linewise: Bool = false
    }

    /// A multi-key command waiting on its final argument.
    private enum Awaiting: Equatable {
        case find(forward: Bool, till: Bool)
        case replaceChar
        case textObject(inner: Bool)
    }

    /// What the `:` / `/` / `?` line is collecting.
    private enum CommandLineKind { case ex, searchForward, searchBackward }

    // MARK: - Wiring

    weak var target: VimTextTarget?
    /// Called after every key so the status bar can redraw.
    var onStateChange: ((VimStatus) -> Void)?
    /// `:w`, `:q`… — the workspace owns these.
    var onFileCommand: ((VimFileCommand) -> Void)?

    private(set) var mode: VimMode = .normal
    private(set) var message: String = ""

    /// One shift step. Vim's default `shiftwidth` is 8; 4 spaces matches what
    /// this editor's formatters emit.
    private let shiftWidth = 4

    // MARK: - Parser state

    private var countBuffer = ""
    private var operatorCount: Int?
    private var pendingOperator: Operator?
    private var awaiting: Awaiting?
    private var prefixG = false
    private var prefixZ = false
    private var pendingKeys = ""

    private var commandLineKind: CommandLineKind?
    private var commandLineText = ""

    private var visualAnchor = 0
    private var visualHead = 0
    private var desiredColumn = 0

    private var register = Register()
    private var lastFind: (char: Character, forward: Bool, till: Bool)?
    private var lastSearch: (pattern: String, forward: Bool)?

    // Dot-repeat. We record the keystrokes of the running normal-mode command
    // and, when it ends in insert mode, the text that was typed before Esc.
    private var recording: [VimKey] = []
    private var recordingValid = false
    private var pendingInsertRecording: [VimKey]?
    private var lastChange: (keys: [VimKey], insert: String)?
    private var isReplaying = false
    private var replayInsertText = ""

    // Insert-session bookkeeping, used to recover the typed text for `.`.
    private var insertStartCaret = 0
    private var insertStartLength = 0

    init(target: VimTextTarget? = nil) {
        self.target = target
    }

    // MARK: - Public entry points

    var status: VimStatus {
        VimStatus(enabled: true,
                  mode: mode,
                  pending: pendingKeys,
                  message: message,
                  commandLine: commandLineKind.map { kind in
                      switch kind {
                      case .ex: return ":" + commandLineText
                      case .searchForward: return "/" + commandLineText
                      case .searchBackward: return "?" + commandLineText
                      }
                  })
    }

    /// Feed one keystroke. Returns `true` when the engine consumed it; `false`
    /// means the caller should hand the event to `NSTextView` (insert mode).
    @discardableResult
    func handle(key: VimKey) -> Bool {
        let consumed = route(key)
        publish()
        return consumed
    }

    /// Called when the buffer is handed to the engine (mode reset on enable,
    /// tab switch, or programmatic reload).
    func reset() {
        mode = .normal
        clearPending()
        commandLineKind = nil
        commandLineText = ""
        message = ""
        clampNormalCaret()
        publish()
    }

    /// Leaving Vim mode: make sure the caret is a plain insertion point again.
    func prepareForDisable() {
        if mode.isVisual, let target {
            target.vimSelection = NSRange(location: visualHead, length: 0)
        }
        mode = .normal
        clearPending()
    }

    private func publish() {
        onStateChange?(status)
    }

    private func route(_ key: VimKey) -> Bool {
        if commandLineKind != nil {
            handleCommandLineKey(key)
            return true
        }
        switch mode {
        case .insert:
            guard key.isEscape else { return false }
            exitInsert()
            return true
        case .normal, .visual, .visualLine:
            return handleNormal(key)
        }
    }

    // MARK: - Normal / visual dispatch

    private func handleNormal(_ key: VimKey) -> Bool {
        guard target != nil else { return false }

        if !isReplaying {
            if !hasPendingState {
                recording.removeAll()
                recordingValid = (mode == .normal)
            }
            recording.append(key)
        }

        if key.isEscape {
            if mode.isVisual { leaveVisual() } else { clearPending() }
            message = ""
            return true
        }

        // Waiting on the argument of f/F/t/T, r, or a text object.
        if let awaiting {
            self.awaiting = nil
            pendingKeys.append(key.char)
            switch awaiting {
            case .find(let forward, let till):
                lastFind = (key.char, forward, till)
                findChar(key.char, forward: forward, till: till, count: takeCount() ?? 1)
            case .replaceChar:
                replaceChar(with: key.char, count: takeCount() ?? 1)
            case .textObject(let inner):
                applyTextObject(key.char, inner: inner)
            }
            return true
        }

        if prefixG { prefixG = false; return handleGCommand(key) }
        if prefixZ { prefixZ = false; return handleZCommand(key) }

        // Counts. A leading "0" is the line-start motion, not a count digit.
        if !key.control, key.char.isNumber, !(key.char == "0" && countBuffer.isEmpty) {
            countBuffer.append(key.char)
            pendingKeys.append(key.char)
            return true
        }

        if key.control { return handleControl(key.char) }

        pendingKeys.append(key.char)

        // A motion (possibly consumed by a pending operator).
        if let motion = resolveMotion(key.char, count: takeCount()) {
            performMotion(to: motion.target, kind: motion.kind,
                          keepDesiredColumn: motion.keepsDesiredColumn)
            return true
        }

        return handleCommand(key.char)
    }

    private var hasPendingState: Bool {
        !countBuffer.isEmpty || pendingOperator != nil || awaiting != nil || prefixG || prefixZ
    }

    private func clearPending() {
        countBuffer = ""
        operatorCount = nil
        pendingOperator = nil
        awaiting = nil
        prefixG = false
        prefixZ = false
        pendingKeys = ""
    }

    /// Consume the digits typed so far, if any.
    private func takeCount() -> Int? {
        guard !countBuffer.isEmpty, let value = Int(countBuffer) else { return nil }
        countBuffer = ""
        return max(value, 1)
    }

    /// Total repeat for a motion after an operator: `2d3w` deletes 6 words.
    private func effectiveCount(_ motionCount: Int?) -> Int {
        (operatorCount ?? 1) * (motionCount ?? 1)
    }

    // MARK: - Caret

    private var text: NSString { target?.vimString ?? "" }

    var caret: Int {
        if mode.isVisual { return min(visualHead, text.length) }
        return min(target?.vimSelection.location ?? 0, text.length)
    }

    private func setCaret(_ index: Int, keepDesiredColumn: Bool = false) {
        guard let target else { return }
        let i = max(0, min(index, target.vimString.length))
        if mode.isVisual {
            visualHead = i
            syncVisualSelection()
        } else {
            target.vimSelection = NSRange(location: i, length: 0)
        }
        if !keepDesiredColumn { desiredColumn = i - lineStart(i) }
        target.vimScrollCaretVisible()
    }

    /// In normal mode the caret sits *on* a character, never on the newline
    /// that ends the line (unless the line is empty).
    private func clampNormalCaret() {
        guard mode == .normal, let target else { return }
        let s = target.vimString
        let i = min(target.vimSelection.location, s.length)
        let start = lineStart(i)
        let end = lineEnd(i)
        if i >= end, i > start {
            target.vimSelection = NSRange(location: max(start, end - 1), length: 0)
        } else if i > s.length {
            target.vimSelection = NSRange(location: s.length, length: 0)
        }
    }

    private func syncVisualSelection() {
        guard let target else { return }
        let s = target.vimString
        var lo = min(visualAnchor, visualHead)
        var hi = max(visualAnchor, visualHead)
        if mode == .visualLine {
            lo = lineStart(lo)
            hi = lineEnd(hi)
        } else {
            hi = min(hi + 1, s.length)
        }
        target.vimSelection = NSRange(location: lo, length: max(0, hi - lo))
        target.vimScrollCaretVisible()
    }

    /// The range a visual-mode operator applies to.
    private func visualRange() -> (range: NSRange, kind: MotionKind) {
        let lo = min(visualAnchor, visualHead)
        let hi = max(visualAnchor, visualHead)
        if mode == .visualLine {
            return (lineSpan(from: lo, to: hi), .linewise)
        }
        return (NSRange(location: lo, length: min(hi + 1, text.length) - lo), .inclusive)
    }

    private func leaveVisual() {
        let head = visualHead
        mode = .normal
        clearPending()
        target?.vimSelection = NSRange(location: min(head, text.length), length: 0)
        clampNormalCaret()
    }

    // MARK: - Motions

    private struct Motion {
        let target: Int
        let kind: MotionKind
        var keepsDesiredColumn = false
    }

    /// Single-key motions. Multi-key ones (`f`, `gg`, text objects) come in via
    /// the `awaiting` / prefix paths.
    private func resolveMotion(_ c: Character, count: Int?) -> Motion? {
        let s = text
        let n = effectiveCount(count)
        let i = caret

        switch c {
        case "h":
            return Motion(target: max(lineStart(i), i - n), kind: .exclusive)
        case "l", " ":
            return Motion(target: min(lineEnd(i), i + n), kind: .exclusive)
        case "j":
            return Motion(target: verticalTarget(from: i, lines: n), kind: .linewise, keepsDesiredColumn: true)
        case "k":
            return Motion(target: verticalTarget(from: i, lines: -n), kind: .linewise, keepsDesiredColumn: true)
        case "0":
            return Motion(target: lineStart(i), kind: .exclusive)
        case "^":
            return Motion(target: firstNonBlank(lineStart(i)), kind: .exclusive)
        case "$":
            var line = i
            for _ in 1..<max(n, 1) { line = nextLineStart(line) }
            // Exclusive so `d$` stops before the newline; plain `$` then clamps
            // onto the last character.
            return Motion(target: lineEnd(line), kind: .exclusive)
        case "w", "W":
            var t = i
            for _ in 0..<n { t = nextWordStart(t, big: c == "W") }
            // `dw` on the last word of a line stops at the line end instead of
            // swallowing the newline.
            if pendingOperator != nil, t > lineEnd(i), i < lineEnd(i) {
                t = lineEnd(i)
            }
            // `cw` behaves like `ce` when the caret is on a non-blank.
            if pendingOperator == .change, classOf(i, big: c == "W") != .blank {
                var e = i
                for _ in 0..<n { e = wordEnd(e, big: c == "W") }
                return Motion(target: e, kind: .inclusive)
            }
            return Motion(target: t, kind: .exclusive)
        case "b", "B":
            var t = i
            for _ in 0..<n { t = prevWordStart(t, big: c == "B") }
            return Motion(target: t, kind: .exclusive)
        case "e", "E":
            var t = i
            for _ in 0..<n { t = wordEnd(t, big: c == "E") }
            return Motion(target: t, kind: .inclusive)
        case "G":
            let t = count.map { lineStartOfNumber($0) } ?? lineStart(s.length)
            return Motion(target: firstNonBlank(t), kind: .linewise)
        case "{":
            var t = i
            for _ in 0..<n { t = paragraphBoundary(from: t, forward: false) }
            return Motion(target: t, kind: .exclusive)
        case "}":
            var t = i
            for _ in 0..<n { t = paragraphBoundary(from: t, forward: true) }
            return Motion(target: t, kind: .exclusive)
        case "%":
            guard let m = matchingBracket(from: i) else { target?.vimBeep(); clearPending(); return nil }
            return Motion(target: m, kind: .inclusive)
        case ";", ",":
            guard let last = lastFind else { target?.vimBeep(); clearPending(); return nil }
            let forward = c == ";" ? last.forward : !last.forward
            guard let t = findCharTarget(last.char, forward: forward, till: last.till, count: n) else {
                target?.vimBeep(); clearPending(); return nil
            }
            return Motion(target: t, kind: forward ? .inclusive : .exclusive)
        case "n", "N":
            guard let search = lastSearch else { target?.vimBeep(); clearPending(); return nil }
            let forward = c == "n" ? search.forward : !search.forward
            guard let r = searchRange(pattern: search.pattern, from: i, forward: forward) else {
                message = "Pattern not found: \(search.pattern)"
                target?.vimBeep(); clearPending(); return nil
            }
            target?.vimFlash(r)
            return Motion(target: r.location, kind: .exclusive)
        default:
            // Not a motion: put the key back for the command dispatcher, but
            // keep the count we consumed.
            if let count { countBuffer = String(count) }
            return nil
        }
    }

    private func performMotion(to index: Int, kind: MotionKind, keepDesiredColumn: Bool = false) {
        if let op = pendingOperator {
            let range = operatorRange(from: caret, to: index, kind: kind)
            applyOperator(op, range: range, kind: kind)
            clearPending()
        } else {
            setCaret(index, keepDesiredColumn: keepDesiredColumn)
            if mode == .normal { clampNormalCaret() }
            clearPending()
        }
    }

    private func operatorRange(from a: Int, to b: Int, kind: MotionKind) -> NSRange {
        let lo = min(a, b)
        let hi = max(a, b)
        switch kind {
        case .exclusive:
            return NSRange(location: lo, length: hi - lo)
        case .inclusive:
            return NSRange(location: lo, length: min(hi + 1, text.length) - lo)
        case .linewise:
            return lineSpan(from: lo, to: hi)
        }
    }

    /// Column-preserving vertical movement (`j` / `k`).
    private func verticalTarget(from index: Int, lines: Int) -> Int {
        var start = lineStart(index)
        if lines >= 0 {
            for _ in 0..<lines {
                let next = nextLineStart(start)
                if next == start { break }
                start = next
            }
        } else {
            for _ in 0..<(-lines) {
                if start == 0 { break }
                start = lineStart(start - 1)
            }
        }
        return min(start + desiredColumn, lineEnd(start))
    }

    // MARK: - Commands

    private func handleCommand(_ c: Character) -> Bool {
        let count = takeCount()
        let n = count ?? 1

        switch c {
        // -- operators -------------------------------------------------------
        case "d", "c", "y", ">", "<":
            let op: Operator = c == "d" ? .delete : c == "c" ? .change : c == "y" ? .yank
                             : c == ">" ? .indent : .outdent
            if mode.isVisual {
                let v = visualRange()
                leaveVisualKeepingCaret()
                applyOperator(op, range: v.range, kind: v.kind)
                return true
            }
            if let pending = pendingOperator {
                // Doubled operator (`dd`, `yy`, `>>`): linewise on `n` lines.
                if pending.doubledKey == c {
                    let start = lineStart(caret)
                    var end = start
                    for _ in 0..<max(effectiveCount(count), 1) { end = nextLineStart(end) }
                    applyOperator(pending, range: NSRange(location: start, length: end - start), kind: .linewise)
                    clearPending()
                    return true
                }
                clearPending()
                target?.vimBeep()
                return true
            }
            pendingOperator = op
            operatorCount = count
            return true

        // -- character search ------------------------------------------------
        case "f", "F", "t", "T":
            awaiting = .find(forward: c == "f" || c == "t", till: c == "t" || c == "T")
            if let count { countBuffer = String(count) }
            return true

        // -- mode switches ---------------------------------------------------
        case "i", "a":
            // After an operator (or in visual mode) these start a text object;
            // on their own they enter insert mode.
            if pendingOperator != nil || mode.isVisual {
                awaiting = .textObject(inner: c == "i")
                return true
            }
            if c == "a" { setCaret(min(caret + 1, lineEnd(caret))) }
            enterInsert()
        case "I":
            if mode.isVisual { leaveVisual() }
            setCaret(firstNonBlank(lineStart(caret)))
            enterInsert()
        case "A":
            if mode.isVisual { leaveVisual() }
            setCaret(lineEnd(caret))
            enterInsert()
        case "o", "O":
            if mode.isVisual {
                if c == "o" { swap(&visualAnchor, &visualHead); syncVisualSelection(); clearPending(); return true }
                leaveVisual()
            }
            openLine(below: c == "o")
        case "v":
            if mode == .visual { leaveVisual() } else { enterVisual(line: false) }
        case "V":
            if mode == .visualLine { leaveVisual() } else { enterVisual(line: true) }

        // -- single-key edits ------------------------------------------------
        case "x":
            deleteCharacters(count: n, before: false)
        case "X":
            deleteCharacters(count: n, before: true)
        case "D":
            applyOperator(.delete, range: NSRange(location: caret, length: lineEnd(caret) - caret), kind: .exclusive)
        case "C":
            applyOperator(.change, range: NSRange(location: caret, length: lineEnd(caret) - caret), kind: .exclusive)
        case "Y":
            let start = lineStart(caret)
            var end = start
            for _ in 0..<n { end = nextLineStart(end) }
            applyOperator(.yank, range: NSRange(location: start, length: end - start), kind: .linewise)
        case "s":
            if mode.isVisual {
                let v = visualRange(); leaveVisualKeepingCaret()
                applyOperator(.change, range: v.range, kind: v.kind)
                return true
            }
            let end = min(caret + n, lineEnd(caret))
            applyOperator(.change, range: NSRange(location: caret, length: end - caret), kind: .exclusive)
        case "S":
            let start = lineStart(caret)
            var end = start
            for _ in 0..<n { end = nextLineStart(end) }
            applyOperator(.change, range: NSRange(location: start, length: end - start), kind: .linewise)
        case "p", "P":
            if mode.isVisual { pasteOverSelection(); return true }
            paste(after: c == "p", count: n)
        case "r":
            awaiting = .replaceChar
            countBuffer = String(n)
            return true
        case "~":
            toggleCase(count: n)
        case "J":
            joinLines(count: max(n, 2))
        case "u":
            if mode.isVisual {
                let v = visualRange(); leaveVisualKeepingCaret()
                applyOperator(.lowercase, range: v.range, kind: v.kind)
                return true
            }
            target?.vimUndo()
            clampNormalCaret()
        case "U":
            if mode.isVisual {
                let v = visualRange(); leaveVisualKeepingCaret()
                applyOperator(.uppercase, range: v.range, kind: v.kind)
                return true
            }
            target?.vimBeep()
        case "g":
            prefixG = true
            return true
        case "z":
            prefixZ = true
            return true

        // -- search / command line -------------------------------------------
        case "/":
            commandLineKind = .searchForward
            commandLineText = ""
        case "?":
            commandLineKind = .searchBackward
            commandLineText = ""
        case ":":
            commandLineKind = .ex
            commandLineText = ""
        case "*", "#":
            searchWordUnderCaret(forward: c == "*")

        case ".":
            repeatLastChange()
            return true

        default:
            target?.vimBeep()
            clearPending()
            return true
        }

        clearPending()
        return true
    }

    private func handleGCommand(_ key: VimKey) -> Bool {
        pendingKeys.append("g")
        let count = takeCount()
        switch key.char {
        case "g":
            let t = firstNonBlank(count.map { lineStartOfNumber($0) } ?? 0)
            performMotion(to: t, kind: .linewise)
        case "u", "U":
            if mode.isVisual {
                let v = visualRange(); leaveVisualKeepingCaret()
                applyOperator(key.char == "u" ? .lowercase : .uppercase, range: v.range, kind: v.kind)
            } else {
                pendingOperator = key.char == "u" ? .lowercase : .uppercase
                operatorCount = count
            }
        case "v":
            // `gv` — reselect the previous visual range.
            if !mode.isVisual, visualAnchor != visualHead {
                mode = .visual
                syncVisualSelection()
            }
            clearPending()
        default:
            target?.vimBeep()
            clearPending()
        }
        return true
    }

    private func handleZCommand(_ key: VimKey) -> Bool {
        switch key.char {
        case "z": target?.vimAlignCaret(.center)
        case "t": target?.vimAlignCaret(.top)
        case "b": target?.vimAlignCaret(.bottom)
        default: target?.vimBeep()
        }
        clearPending()
        return true
    }

    private func handleControl(_ c: Character) -> Bool {
        let page = max(target?.vimLinesPerPage ?? 20, 2)
        switch c {
        case "d": performMotion(to: verticalTarget(from: caret, lines: page / 2), kind: .exclusive, keepDesiredColumn: true)
        case "u": performMotion(to: verticalTarget(from: caret, lines: -(page / 2)), kind: .exclusive, keepDesiredColumn: true)
        case "f": performMotion(to: verticalTarget(from: caret, lines: page - 2), kind: .exclusive, keepDesiredColumn: true)
        case "b": performMotion(to: verticalTarget(from: caret, lines: -(page - 2)), kind: .exclusive, keepDesiredColumn: true)
        case "r":
            target?.vimRedo()
            clampNormalCaret()
            clearPending()
        case "o", "i":
            clearPending()   // jump list: not implemented, swallow silently
        default:
            return false     // let AppKit have it (Ctrl-A/E etc.)
        }
        return true
    }

    // MARK: - Mode transitions

    private func enterInsert() {
        guard let target else { return }
        mode = .insert
        insertStartCaret = target.vimSelection.location
        insertStartLength = target.vimString.length
        if !isReplaying { pendingInsertRecording = recordingValid ? recording : nil }
        clearPending()
        if isReplaying {
            // Dot-repeat: replay the text typed the first time instead of
            // waiting for keystrokes that will never come.
            insertTextAtCaret(replayInsertText)
            exitInsert()
        }
    }

    private func exitInsert() {
        guard let target else { return }
        let typed = capturedInsertText()
        mode = .normal
        if let keys = pendingInsertRecording {
            lastChange = (keys, typed)
            pendingInsertRecording = nil
        }
        // Vim steps back onto the last inserted character.
        let caretNow = target.vimSelection.location
        if caretNow > lineStart(caretNow) {
            target.vimSelection = NSRange(location: caretNow - 1, length: 0)
        }
        clampNormalCaret()
        clearPending()
    }

    /// Text added during the insert session, recovered by comparing the buffer
    /// length and caret with where insert started. Falls back to "" for edits
    /// we can't attribute (e.g. the user clicked elsewhere mid-insert).
    private func capturedInsertText() -> String {
        guard let target else { return "" }
        let s = target.vimString
        let delta = s.length - insertStartLength
        let caretNow = target.vimSelection.location
        guard delta > 0, caretNow == insertStartCaret + delta,
              insertStartCaret + delta <= s.length else { return "" }
        return s.substring(with: NSRange(location: insertStartCaret, length: delta))
    }

    private func enterVisual(line: Bool) {
        let start = caret
        visualAnchor = start
        visualHead = start
        mode = line ? .visualLine : .visual
        syncVisualSelection()
        clearPending()
    }

    /// End visual mode but leave the caret where the operator will want it.
    private func leaveVisualKeepingCaret() {
        mode = .normal
        clearPending()
    }

    // MARK: - Editing primitives

    private func insertTextAtCaret(_ string: String) {
        guard let target, !string.isEmpty else { return }
        let at = min(target.vimSelection.location, target.vimString.length)
        target.vimReplace(NSRange(location: at, length: 0), with: string)
        target.vimSelection = NSRange(location: at + (string as NSString).length, length: 0)
    }

    private func applyOperator(_ op: Operator, range: NSRange, kind: MotionKind) {
        guard let target, range.location != NSNotFound else { return }
        let s = target.vimString
        let r = NSRange(location: max(0, min(range.location, s.length)),
                        length: max(0, min(range.length, s.length - min(range.location, s.length))))

        switch op {
        case .yank:
            register = Register(text: s.substring(with: r), linewise: kind == .linewise)
            setCaret(kind == .linewise ? firstNonBlank(lineStart(r.location)) : r.location)
            clampNormalCaret()

        case .delete:
            guard r.length > 0 else { return }
            register = Register(text: s.substring(with: r), linewise: kind == .linewise)
            target.vimReplace(r, with: "")
            if kind == .linewise {
                let at = min(r.location, target.vimString.length)
                setCaret(firstNonBlank(lineStart(at)))
            } else {
                setCaret(r.location)
            }
            clampNormalCaret()
            recordChange()

        case .change:
            register = Register(text: s.substring(with: r), linewise: kind == .linewise)
            if kind == .linewise {
                // Keep an (indented) empty line to type on, like Vim's `cc`.
                let indent = leadingWhitespace(atLineStart: r.location)
                let endsWithNewline = r.length > 0 && s.substring(with: r).hasSuffix("\n")
                let replacement = indent + (endsWithNewline ? "\n" : "")
                target.vimReplace(r, with: replacement)
                target.vimSelection = NSRange(location: r.location + (indent as NSString).length, length: 0)
            } else {
                if r.length > 0 { target.vimReplace(r, with: "") }
                target.vimSelection = NSRange(location: r.location, length: 0)
            }
            mode = .normal
            enterInsert()

        case .indent, .outdent:
            let span = lineSpan(from: r.location, to: max(r.location, NSMaxRange(r) - (r.length > 0 ? 1 : 0)))
            shift(span: span, out: op == .outdent)
            recordChange()

        case .lowercase, .uppercase:
            guard r.length > 0 else { return }
            let sub = s.substring(with: r)
            let converted = op == .lowercase ? sub.lowercased() : sub.uppercased()
            target.vimReplace(r, with: converted)
            setCaret(r.location)
            clampNormalCaret()
            recordChange()
        }
    }

    private func shift(span: NSRange, out: Bool) {
        guard let target, span.length > 0 || text.length == 0 else { return }
        let s = target.vimString
        let body = s.substring(with: span)
        let hadTrailingNewline = body.hasSuffix("\n")
        var lines = body.components(separatedBy: "\n")
        if hadTrailingNewline { lines.removeLast() }
        let pad = String(repeating: " ", count: shiftWidth)
        let shifted = lines.map { line -> String in
            if out {
                var l = Substring(line)
                var removed = 0
                while removed < shiftWidth, let first = l.first, first == " " || first == "\t" {
                    l = l.dropFirst()
                    removed += first == "\t" ? shiftWidth : 1
                }
                return String(l)
            }
            return line.isEmpty ? line : pad + line
        }
        let result = shifted.joined(separator: "\n") + (hadTrailingNewline ? "\n" : "")
        target.vimReplace(span, with: result)
        setCaret(firstNonBlank(lineStart(min(span.location, target.vimString.length))))
    }

    private func deleteCharacters(count: Int, before: Bool) {
        guard let target else { return }
        if mode.isVisual {
            let v = visualRange()
            leaveVisualKeepingCaret()
            applyOperator(.delete, range: v.range, kind: v.kind)
            return
        }
        let i = caret
        let range: NSRange
        if before {
            let start = max(lineStart(i), i - count)
            range = NSRange(location: start, length: i - start)
        } else {
            let end = min(lineEnd(i), i + count)
            range = NSRange(location: i, length: end - i)
        }
        guard range.length > 0 else { target.vimBeep(); return }
        register = Register(text: target.vimString.substring(with: range), linewise: false)
        target.vimReplace(range, with: "")
        setCaret(range.location)
        clampNormalCaret()
        recordChange()
    }

    private func replaceChar(with c: Character, count: Int) {
        guard let target else { return }
        if mode.isVisual {
            let v = visualRange()
            leaveVisualKeepingCaret()
            let sub = target.vimString.substring(with: v.range)
            let replacement = String(sub.map { $0 == "\n" ? "\n" : c })
            target.vimReplace(v.range, with: replacement)
            setCaret(v.range.location)
            clampNormalCaret()
            recordChange()
            return
        }
        let i = caret
        let end = min(lineEnd(i), i + count)
        guard end > i else { target.vimBeep(); return }
        let range = NSRange(location: i, length: end - i)
        target.vimReplace(range, with: String(repeating: String(c), count: range.length))
        setCaret(end - 1)
        recordChange()
    }

    private func toggleCase(count: Int) {
        guard let target else { return }
        if mode.isVisual {
            let v = visualRange()
            leaveVisualKeepingCaret()
            let flipped = String(target.vimString.substring(with: v.range).map(flipCase))
            target.vimReplace(v.range, with: flipped)
            setCaret(v.range.location)
            clampNormalCaret()
            recordChange()
            return
        }
        let i = caret
        let end = min(lineEnd(i), i + count)
        guard end > i else { target.vimBeep(); return }
        let range = NSRange(location: i, length: end - i)
        let flipped = String(target.vimString.substring(with: range).map(flipCase))
        target.vimReplace(range, with: flipped)
        setCaret(min(end, lineEnd(i)))
        clampNormalCaret()
        recordChange()
    }

    private func flipCase(_ c: Character) -> Character {
        if c.isLowercase { return Character(c.uppercased()) }
        if c.isUppercase { return Character(c.lowercased()) }
        return c
    }

    private func openLine(below: Bool) {
        guard let target else { return }
        let i = caret
        let indent = leadingWhitespace(atLineStart: lineStart(i))
        if below {
            let end = lineEnd(i)
            target.vimReplace(NSRange(location: end, length: 0), with: "\n" + indent)
            target.vimSelection = NSRange(location: end + 1 + (indent as NSString).length, length: 0)
        } else {
            let start = lineStart(i)
            target.vimReplace(NSRange(location: start, length: 0), with: indent + "\n")
            target.vimSelection = NSRange(location: start + (indent as NSString).length, length: 0)
        }
        mode = .normal
        enterInsert()
    }

    private func joinLines(count: Int) {
        guard let target else { return }
        if mode.isVisual {
            let v = visualRange()
            leaveVisualKeepingCaret()
            let lines = target.vimString.substring(with: v.range).components(separatedBy: "\n").count
            setCaret(v.range.location)
            joinLines(count: max(lines, 2))
            return
        }
        for _ in 0..<(count - 1) {
            let s = target.vimString
            let end = lineEnd(caret)
            guard end < s.length else { target.vimBeep(); break }
            // Drop the newline plus the next line's indentation, leaving one space.
            var stop = end + 1
            while stop < s.length, let c = character(at: stop, in: s), c == " " || c == "\t" { stop += 1 }
            let nextIsEmpty = stop >= s.length || character(at: stop, in: s) == "\n"
            let separator = (end == lineStart(caret) || nextIsEmpty) ? "" : " "
            target.vimReplace(NSRange(location: end, length: stop - end), with: separator)
            setCaret(end)
        }
        clampNormalCaret()
        recordChange()
    }

    private func paste(after: Bool, count: Int) {
        guard let target, !register.text.isEmpty else { target?.vimBeep(); return }
        let s = target.vimString
        if register.linewise {
            var body = String(repeating: register.text, count: count)
            if !body.hasSuffix("\n") { body += "\n" }
            if after {
                let end = lineEnd(caret)
                if end >= s.length {
                    // Last line has no trailing newline — prepend one instead.
                    let insertion = "\n" + String(body.dropLast())
                    target.vimReplace(NSRange(location: s.length, length: 0), with: insertion)
                    setCaret(firstNonBlank(s.length + 1))
                } else {
                    target.vimReplace(NSRange(location: end + 1, length: 0), with: body)
                    setCaret(firstNonBlank(end + 1))
                }
            } else {
                let start = lineStart(caret)
                target.vimReplace(NSRange(location: start, length: 0), with: body)
                setCaret(firstNonBlank(start))
            }
        } else {
            let body = String(repeating: register.text, count: count)
            let at = after ? min(caret + (lineEnd(caret) > caret ? 1 : 0), s.length) : caret
            target.vimReplace(NSRange(location: at, length: 0), with: body)
            setCaret(at + (body as NSString).length - 1)
        }
        clampNormalCaret()
        recordChange()
    }

    private func pasteOverSelection() {
        guard let target, !register.text.isEmpty else { target?.vimBeep(); return }
        let v = visualRange()
        leaveVisualKeepingCaret()
        let removed = target.vimString.substring(with: v.range)
        let wasLinewise = v.kind == .linewise
        var body = register.text
        if register.linewise && !wasLinewise { body = "\n" + body }
        if !register.linewise && wasLinewise && !body.hasSuffix("\n") { body += "\n" }
        target.vimReplace(v.range, with: body)
        register = Register(text: removed, linewise: wasLinewise)
        setCaret(v.range.location)
        clampNormalCaret()
        recordChange()
    }

    // MARK: - Text objects

    private func applyTextObject(_ c: Character, inner: Bool) {
        guard let result = textObjectRange(c, inner: inner) else {
            target?.vimBeep()
            clearPending()
            return
        }
        if let op = pendingOperator {
            applyOperator(op, range: result.range, kind: result.kind)
            clearPending()
        } else if mode.isVisual {
            visualAnchor = result.range.location
            visualHead = max(result.range.location, NSMaxRange(result.range) - 1)
            if result.kind == .linewise { mode = .visualLine }
            syncVisualSelection()
            clearPending()
        } else {
            target?.vimBeep()
            clearPending()
        }
    }

    private func textObjectRange(_ c: Character, inner: Bool) -> (range: NSRange, kind: MotionKind)? {
        let s = text
        let i = caret
        switch c {
        case "w", "W":
            let big = c == "W"
            guard s.length > 0 else { return nil }
            let idx = min(i, s.length - 1)
            let cls = classOf(idx, big: big)
            var start = idx, end = idx
            while start > 0, classOf(start - 1, big: big) == cls, character(at: start - 1, in: s) != "\n" { start -= 1 }
            while end + 1 < s.length, classOf(end + 1, big: big) == cls, character(at: end + 1, in: s) != "\n" { end += 1 }
            var range = NSRange(location: start, length: end - start + 1)
            if !inner {
                // `aw` also takes the trailing run of blanks (or the leading one).
                var t = NSMaxRange(range)
                var grew = false
                while t < s.length, let ch = character(at: t, in: s), ch == " " || ch == "\t" { t += 1; grew = true }
                if grew {
                    range.length = t - range.location
                } else {
                    var h = range.location
                    while h > 0, let ch = character(at: h - 1, in: s), ch == " " || ch == "\t" { h -= 1 }
                    range = NSRange(location: h, length: NSMaxRange(range) - h)
                }
            }
            return (range, .inclusive)

        case "\"", "'", "`":
            guard let pair = quoteRange(delimiter: c, around: i) else { return nil }
            return inner
                ? (NSRange(location: pair.location + 1, length: max(0, pair.length - 2)), .inclusive)
                : (pair, .inclusive)

        case "(", ")", "b", "{", "}", "B", "[", "]", "<", ">":
            let open: Character
            let close: Character
            switch c {
            case "(", ")", "b": open = "("; close = ")"
            case "{", "}", "B": open = "{"; close = "}"
            case "[", "]": open = "["; close = "]"
            default: open = "<"; close = ">"
            }
            guard let pair = blockRange(open: open, close: close, around: i) else { return nil }
            return inner
                ? (NSRange(location: pair.location + 1, length: max(0, pair.length - 2)), .inclusive)
                : (pair, .inclusive)

        case "p":
            let start = paragraphBoundary(from: i, forward: false)
            let end = paragraphBoundary(from: i, forward: true)
            let span = lineSpan(from: start, to: max(start, end - 1))
            return (span, .linewise)

        default:
            return nil
        }
    }

    private func quoteRange(delimiter: Character, around index: Int) -> NSRange? {
        let s = text
        let start = lineStart(index)
        let end = lineEnd(index)
        var positions: [Int] = []
        var i = start
        while i < end {
            if character(at: i, in: s) == delimiter {
                // Skip an escaped delimiter.
                if i > start, character(at: i - 1, in: s) == "\\" { i += 1; continue }
                positions.append(i)
            }
            i += 1
        }
        guard positions.count >= 2 else { return nil }
        var p = 0
        while p + 1 < positions.count {
            let a = positions[p], b = positions[p + 1]
            if index <= b { return NSRange(location: a, length: b - a + 1) }
            p += 2
        }
        return nil
    }

    private func blockRange(open: Character, close: Character, around index: Int) -> NSRange? {
        let s = text
        guard s.length > 0 else { return nil }
        let i = min(index, s.length - 1)

        var openIndex: Int?
        var depth = 0
        var j = i
        // If the caret is on the opening brace itself, that's our start.
        if character(at: i, in: s) == open {
            openIndex = i
        } else {
            while j >= 0 {
                let c = character(at: j, in: s)
                if c == close, j != i { depth += 1 }
                else if c == open {
                    if depth == 0 { openIndex = j; break }
                    depth -= 1
                }
                j -= 1
            }
        }
        guard let start = openIndex else { return nil }

        depth = 0
        var k = start + 1
        while k < s.length {
            let c = character(at: k, in: s)
            if c == open { depth += 1 }
            else if c == close {
                if depth == 0 { return NSRange(location: start, length: k - start + 1) }
                depth -= 1
            }
            k += 1
        }
        return nil
    }

    private func matchingBracket(from index: Int) -> Int? {
        let s = text
        let pairs: [Character: (Character, Bool)] = [
            "(": (")", true), "[": ("]", true), "{": ("}", true),
            ")": ("(", false), "]": ("[", false), "}": ("{", false)
        ]
        // Vim scans forward on the line for the first bracket.
        var i = index
        let end = lineEnd(index)
        while i < end, let c = character(at: i, in: s), pairs[c] == nil { i += 1 }
        guard i < end, let c = character(at: i, in: s), let (mate, forward) = pairs[c] else { return nil }

        var depth = 0
        var j = i
        while j >= 0 && j < s.length {
            let cur = character(at: j, in: s)
            if cur == c { depth += 1 }
            else if cur == mate {
                depth -= 1
                if depth == 0 { return j }
            }
            j += forward ? 1 : -1
        }
        return nil
    }

    // MARK: - Character search (f F t T)

    private func findChar(_ c: Character, forward: Bool, till: Bool, count: Int) {
        guard let t = findCharTarget(c, forward: forward, till: till, count: count) else {
            target?.vimBeep()
            clearPending()
            return
        }
        performMotion(to: t, kind: forward ? .inclusive : .exclusive)
    }

    private func findCharTarget(_ c: Character, forward: Bool, till: Bool, count: Int) -> Int? {
        let s = text
        let start = lineStart(caret)
        let end = lineEnd(caret)
        var i = caret
        var found: Int?
        for _ in 0..<count {
            if forward {
                var j = i + 1
                // `t` repeated must skip past the character it stopped before.
                if till, found != nil { j += 1 }
                while j < end {
                    if character(at: j, in: s) == c { found = j; break }
                    j += 1
                }
                if j >= end { return nil }
            } else {
                var j = i - 1
                if till, found != nil { j -= 1 }
                while j >= start {
                    if character(at: j, in: s) == c { found = j; break }
                    j -= 1
                }
                if j < start { return nil }
            }
            guard let f = found else { return nil }
            i = f
        }
        guard let f = found else { return nil }
        if till { return forward ? f - 1 : f + 1 }
        return f
    }

    // MARK: - Search

    private func regex(for pattern: String) -> NSRegularExpression? {
        if let r = try? NSRegularExpression(pattern: pattern) { return r }
        return try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: pattern))
    }

    /// Next match of `pattern` from `index`, wrapping around the buffer.
    private func searchRange(pattern: String, from index: Int, forward: Bool) -> NSRange? {
        guard let re = regex(for: pattern) else { return nil }
        let s = text as String
        let full = NSRange(location: 0, length: text.length)
        let all = re.matches(in: s, options: [], range: full).map(\.range)
        guard !all.isEmpty else { return nil }
        if forward {
            return all.first(where: { $0.location > index }) ?? all.first
        }
        return all.last(where: { $0.location < index }) ?? all.last
    }

    private func searchWordUnderCaret(forward: Bool) {
        let s = text
        guard s.length > 0 else { target?.vimBeep(); return }
        var start = min(caret, s.length - 1)
        while start > 0, classOf(start - 1, big: false) == .word { start -= 1 }
        var end = start
        while end < s.length, classOf(end, big: false) == .word { end += 1 }
        guard end > start else { target?.vimBeep(); return }
        let word = s.substring(with: NSRange(location: start, length: end - start))
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b"
        lastSearch = (pattern, forward)
        if let r = searchRange(pattern: pattern, from: caret, forward: forward) {
            setCaret(r.location)
            clampNormalCaret()
            target?.vimFlash(r)
        } else {
            target?.vimBeep()
        }
    }

    // MARK: - Command line (`:` `/` `?`)

    private func handleCommandLineKey(_ key: VimKey) {
        guard let kind = commandLineKind else { return }
        if key.isEscape {
            commandLineKind = nil
            commandLineText = ""
            return
        }
        if key.isBackspace {
            if commandLineText.isEmpty { commandLineKind = nil }
            else { commandLineText.removeLast() }
            return
        }
        if key.isEnter {
            let line = commandLineText
            commandLineKind = nil
            commandLineText = ""
            switch kind {
            case .ex: executeEx(line)
            case .searchForward, .searchBackward: runSearch(line, forward: kind == .searchForward)
            }
            return
        }
        commandLineText.append(key.char)
    }

    private func runSearch(_ pattern: String, forward: Bool) {
        let p = pattern.isEmpty ? (lastSearch?.pattern ?? "") : pattern
        guard !p.isEmpty else { target?.vimBeep(); return }
        lastSearch = (p, forward)
        guard let r = searchRange(pattern: p, from: caret, forward: forward) else {
            message = "Pattern not found: \(p)"
            target?.vimBeep()
            return
        }
        message = ""
        setCaret(r.location)
        clampNormalCaret()
        target?.vimFlash(r)
    }

    private func executeEx(_ raw: String) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }
        message = ""

        switch line {
        case "w", "write":       onFileCommand?(.write); message = "Written"; return
        case "q", "quit":        onFileCommand?(.quit); return
        case "q!", "quit!":      onFileCommand?(.forceQuit); return
        case "wq", "x", "wq!":   onFileCommand?(.writeQuit); return
        case "noh", "nohl", "nohlsearch": message = ""; return
        case "$":                performMotion(to: firstNonBlank(lineStart(text.length)), kind: .linewise); return
        default: break
        }

        if let number = Int(line) {
            performMotion(to: firstNonBlank(lineStartOfNumber(number)), kind: .linewise)
            return
        }

        if line.hasPrefix("s/") || line.hasPrefix("%s/") {
            substitute(line)
            return
        }

        message = "Not an editor command: \(line)"
        target?.vimBeep()
    }

    /// `:s/pat/rep/flags` on the current line, `:%s/…` on the buffer.
    /// Flags: `g` (all on a line), `i` (ignore case).
    private func substitute(_ line: String) {
        guard let target else { return }
        let wholeFile = line.hasPrefix("%")
        let body = String(line.dropFirst(wholeFile ? 2 : 1))   // strip "%s" / "s"
        let parts = splitSubstitution(body)
        guard parts.count >= 2 else {
            message = "Malformed :s command"
            target.vimBeep()
            return
        }
        let pattern = parts[0]
        let replacement = parts[1]
        let flags = parts.count > 2 ? parts[2] : ""
        var options: NSRegularExpression.Options = []
        if flags.contains("i") { options.insert(.caseInsensitive) }
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else {
            message = "Bad pattern: \(pattern)"
            target.vimBeep()
            return
        }

        let scope = wholeFile
            ? NSRange(location: 0, length: target.vimString.length)
            : NSRange(location: lineStart(caret), length: lineEnd(caret) - lineStart(caret))
        let source = target.vimString.substring(with: scope)
        let full = NSRange(location: 0, length: (source as NSString).length)
        let matches = re.matches(in: source, options: [], range: full)
        guard !matches.isEmpty else {
            message = "Pattern not found: \(pattern)"
            target.vimBeep()
            return
        }

        // Without `g`, Vim replaces only the first match on each line.
        var chosen = matches
        if !flags.contains("g") {
            var seenLines = Set<Int>()
            chosen = matches.filter { match in
                let key = (source as NSString).lineRange(for: match.range).location
                return seenLines.insert(key).inserted
            }
        }
        // Apply right-to-left so the ranges we haven't used stay valid.
        var result = source as NSString
        for match in chosen.reversed() {
            let replaced = re.replacementString(for: match, in: source, offset: 0, template: replacement)
            result = result.replacingCharacters(in: match.range, with: replaced) as NSString
        }
        let applied = chosen.count
        target.vimReplace(scope, with: result as String)
        setCaret(min(scope.location, target.vimString.length))
        clampNormalCaret()
        message = "\(applied) substitution\(applied == 1 ? "" : "s")"
    }

    /// Split `/pat/rep/flags` honouring `\/` escapes.
    private func splitSubstitution(_ body: String) -> [String] {
        guard let delimiter = body.first else { return [] }
        var parts: [String] = []
        var current = ""
        var escaped = false
        for c in body.dropFirst() {
            if escaped {
                if c != delimiter { current.append("\\") }
                current.append(c)
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == delimiter {
                parts.append(current)
                current = ""
            } else {
                current.append(c)
            }
        }
        parts.append(current)
        return parts
    }

    // MARK: - Dot repeat

    private func recordChange() {
        guard !isReplaying, recordingValid, !recording.isEmpty else { return }
        lastChange = (recording, "")
    }

    private func repeatLastChange() {
        guard let change = lastChange else { target?.vimBeep(); clearPending(); return }
        isReplaying = true
        replayInsertText = change.insert
        clearPending()
        for key in change.keys {
            _ = route(key)
        }
        if mode == .insert { exitInsert() }
        isReplaying = false
        clearPending()
    }

    // MARK: - Buffer helpers

    private func character(at index: Int, in s: NSString) -> Character? {
        guard index >= 0, index < s.length else { return nil }
        guard let scalar = Unicode.Scalar(s.character(at: index)) else { return nil }
        return Character(scalar)
    }

    private enum CharClass { case blank, word, punct }

    private func classOf(_ index: Int, big: Bool) -> CharClass {
        guard let c = character(at: index, in: text) else { return .blank }
        if c == " " || c == "\t" || c == "\n" || c == "\r" { return .blank }
        if big { return .word }
        if c.isLetter || c.isNumber || c == "_" { return .word }
        return .punct
    }

    private func lineStart(_ index: Int) -> Int {
        let s = text
        let i = max(0, min(index, s.length))
        return s.lineRange(for: NSRange(location: i, length: 0)).location
    }

    /// Index of the newline that ends this line (or the buffer end).
    private func lineEnd(_ index: Int) -> Int {
        let s = text
        let i = max(0, min(index, s.length))
        let r = s.lineRange(for: NSRange(location: i, length: 0))
        var end = NSMaxRange(r)
        if end > r.location, character(at: end - 1, in: s) == "\n" { end -= 1 }
        if end > r.location, character(at: end - 1, in: s) == "\r" { end -= 1 }
        return end
    }

    private func nextLineStart(_ index: Int) -> Int {
        let s = text
        let i = max(0, min(index, s.length))
        return min(NSMaxRange(s.lineRange(for: NSRange(location: i, length: 0))), s.length)
    }

    /// Full lines covering `from...to`, including the last line's newline.
    private func lineSpan(from: Int, to: Int) -> NSRange {
        let s = text
        let lo = lineStart(min(from, to))
        var hi = nextLineStart(max(from, to))
        if hi < lo { hi = lo }
        return NSRange(location: lo, length: min(hi, s.length) - lo)
    }

    private func firstNonBlank(_ index: Int) -> Int {
        let s = text
        var i = lineStart(index)
        let end = lineEnd(index)
        while i < end, let c = character(at: i, in: s), c == " " || c == "\t" { i += 1 }
        return i
    }

    private func leadingWhitespace(atLineStart index: Int) -> String {
        let s = text
        let start = lineStart(index)
        return s.substring(with: NSRange(location: start, length: firstNonBlank(start) - start))
    }

    /// Start offset of 1-based line `number`, clamped to the buffer.
    private func lineStartOfNumber(_ number: Int) -> Int {
        let s = text
        var i = 0
        var line = 1
        while line < number, i < s.length {
            let next = nextLineStart(i)
            if next == i { break }
            i = next
            line += 1
        }
        return min(i, s.length)
    }

    private func paragraphBoundary(from index: Int, forward: Bool) -> Int {
        let s = text
        if forward {
            var i = nextLineStart(index)
            while i < s.length {
                if lineEnd(i) == i { return i }        // blank line
                let next = nextLineStart(i)
                if next == i { break }
                i = next
            }
            return s.length
        } else {
            var i = lineStart(index)
            while i > 0 {
                i = lineStart(i - 1)
                if lineEnd(i) == i { return i }
            }
            return 0
        }
    }

    // MARK: - Word motions

    private func nextWordStart(_ index: Int, big: Bool) -> Int {
        let s = text
        var i = index
        guard i < s.length else { return s.length }
        let start = classOf(i, big: big)
        if start != .blank {
            while i < s.length, classOf(i, big: big) == start { i += 1 }
        }
        while i < s.length, classOf(i, big: big) == .blank {
            // An empty line counts as a word.
            if character(at: i, in: s) == "\n", i + 1 < s.length, character(at: i + 1, in: s) == "\n" {
                return i + 1
            }
            i += 1
        }
        return i
    }

    private func prevWordStart(_ index: Int, big: Bool) -> Int {
        var i = index - 1
        guard i >= 0 else { return 0 }
        while i > 0, classOf(i, big: big) == .blank { i -= 1 }
        guard i >= 0 else { return 0 }
        let cls = classOf(i, big: big)
        if cls == .blank { return max(i, 0) }
        while i > 0, classOf(i - 1, big: big) == cls { i -= 1 }
        return i
    }

    private func wordEnd(_ index: Int, big: Bool) -> Int {
        let s = text
        var i = index + 1
        while i < s.length, classOf(i, big: big) == .blank { i += 1 }
        guard i < s.length else { return max(index, s.length - 1) }
        let cls = classOf(i, big: big)
        while i + 1 < s.length, classOf(i + 1, big: big) == cls { i += 1 }
        return i
    }
}
