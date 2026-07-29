import AppKit
import SwiftUI

/// SwiftUI wrapper around a fully configured `NSTextView` inside an
/// `NSScrollView`, with a line-number gutter, monospaced font, per-language
/// syntax highlighting and cursor tracking.
///
/// SwiftUI's `TextEditor` can't provide a gutter or attribute-level
/// highlighting, so we drop down to AppKit. Everything here is tuned to stay
/// responsive on multi-MB documents: highlighting only ever touches the visible
/// character range, the gutter only draws visible line fragments, and line /
/// column lookups are O(log n) against a cached table of line-start offsets.
struct EditorTextView: NSViewRepresentable {
    @ObservedObject var document: EditorDocument
    let onTextChange: (String) -> Void
    let onCursorChange: (Int, Int) -> Void
    var onTextViewReady: ((NSTextView) -> Void)? = nil
    /// Vim emulation (see `VimEngine`). Toggled from Settings / the Edit menu.
    var vimEnabled: Bool = false
    var onVimStatus: ((VimStatus) -> Void)? = nil
    var onVimFileCommand: ((VimFileCommand) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document, onTextChange: onTextChange, onCursorChange: onCursorChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        // Build an explicit TextKit 1 stack. `NSTextView.scrollableTextView()`
        // creates a TextKit 2 view on modern macOS; because our coordinator and
        // ruler access `.layoutManager`, that view silently downgrades to a
        // compatibility mode in which the TEXT does not render (gutter numbers
        // still draw). Constructing the TextKit 1 stack ourselves avoids it.
        let scroll = NSScrollView()
        let contentSize = NSSize(width: 800, height: 600)
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: contentSize.width,
                                                     height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let textView = VimTextView(frame: NSRect(origin: .zero, size: contentSize),
                                   textContainer: container)
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.usesFindBar = false
        textView.allowsUndo = true
        textView.font = font
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.delegate = context.coordinator
        textView.typingAttributes = [.foregroundColor: NSColor.labelColor, .font: font]

        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.documentView = textView

        // Line-number gutter. We deliberately do NOT use `NSScrollView`'s
        // `rulersVisible` ruler: on macOS Sequoia an `NSRulerView` offsets the
        // clip view (bounds.x = -rulerWidth) which breaks the text view's live
        // compositing (glyphs draw via drawRect but never reach the screen).
        // Instead we reserve a left content inset and float our own gutter view
        // in that margin, syncing it to scrolling.
        let gutterWidth: CGFloat = 46
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: gutterWidth, bottom: 0, right: 0)
        scroll.scrollerInsets = NSEdgeInsets(top: 0, left: -gutterWidth, bottom: 0, right: 0)

        let gutter = LineNumberGutterView(textView: textView, coordinator: context.coordinator)
        gutter.frame = NSRect(x: 0, y: 0, width: gutterWidth, height: scroll.bounds.height)
        gutter.autoresizingMask = [.height]
        scroll.addSubview(gutter)

        context.coordinator.textView = textView
        context.coordinator.gutterView = gutter
        context.coordinator.highlighter = SyntaxHighlighter(font: font)
        context.coordinator.load(text: document.text, language: document.effectiveLanguage)
        context.coordinator.onVimStatus = onVimStatus
        context.coordinator.onVimFileCommand = onVimFileCommand
        context.coordinator.setVimEnabled(vimEnabled)

        // Register this text view so Find & Replace can drive it.
        onTextViewReady?(textView)

        // Take keyboard focus once we're in a window, so the user can type
        // immediately instead of having to click into the editor first (initial
        // focus otherwise lands on a toolbar button).
        DispatchQueue.main.async { [weak textView] in
            guard let textView, let window = textView.window else { return }
            if window.firstResponder !== textView {
                window.makeFirstResponder(textView)
            }
        }

        // Re-color and re-number the newly exposed region while scrolling.
        let clipView = scroll.contentView
        clipView.postsBoundsChangedNotifications = true
        context.coordinator.boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak coordinator = context.coordinator] _ in
            coordinator?.highlightVisibleRange()
            coordinator?.gutterView?.needsDisplay = true
        }

        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onTextChange = onTextChange
        context.coordinator.onCursorChange = onCursorChange
        context.coordinator.onVimStatus = onVimStatus
        context.coordinator.onVimFileCommand = onVimFileCommand
        context.coordinator.setVimEnabled(vimEnabled)
        // Pull in text that changed outside the editor (Format / Replace All).
        context.coordinator.syncProgrammaticChanges(text: document.text,
                                                     revision: document.editorRevision,
                                                     language: document.effectiveLanguage)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        if let observer = coordinator.boundsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onTextChange: (String) -> Void
        var onCursorChange: (Int, Int) -> Void
        var onVimStatus: ((VimStatus) -> Void)?
        var onVimFileCommand: ((VimFileCommand) -> Void)?
        weak var textView: NSTextView?
        weak var gutterView: LineNumberGutterView?
        var highlighter = SyntaxHighlighter()
        var boundsObserver: Any?
        private(set) var vimEngine: VimEngine?

        private var language: LanguageMode
        private var lastRevision: Int = 0
        private var isProgrammaticChange = false
        private var highlightWorkItem: DispatchWorkItem?
        private var occurrenceWorkItem: DispatchWorkItem?
        private static let wordCharacterSet = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))

        /// Character offset at the start of each logical line. Rebuilt on every
        /// edit; drives O(log n) line/column lookups for the gutter and status bar.
        private(set) var lineStarts: [Int] = [0]

        init(document: EditorDocument,
             onTextChange: @escaping (String) -> Void,
             onCursorChange: @escaping (Int, Int) -> Void) {
            self.onTextChange = onTextChange
            self.onCursorChange = onCursorChange
            self.language = document.effectiveLanguage
            self.lastRevision = document.editorRevision
        }

        func load(text: String, language: LanguageMode) {
            guard let textView = textView else { return }
            self.language = language
            isProgrammaticChange = true
            textView.string = text
            isProgrammaticChange = false
            rebuildLineStarts(text as NSString)
            highlightVisibleRange()
            gutterView?.needsDisplay = true
            updateCursor()
        }

        // MARK: Vim

        /// Attach or detach the Vim layer. Creating the engine puts the buffer
        /// in normal mode; detaching restores plain `NSTextView` behaviour.
        func setVimEnabled(_ enabled: Bool) {
            if enabled {
                guard vimEngine == nil else { return }
                let engine = VimEngine(target: self)
                engine.onStateChange = { [weak self] status in
                    // Async so we never mutate observed state while SwiftUI is
                    // in the middle of an update pass (this is also called from
                    // `updateNSView`).
                    guard let self else { return }
                    let callback = self.onVimStatus
                    DispatchQueue.main.async { callback?(status) }
                }
                engine.onFileCommand = { [weak self] command in
                    self?.onVimFileCommand?(command)
                }
                vimEngine = engine
                (textView as? VimTextView)?.vimEngine = engine
                engine.reset()
            } else {
                guard let engine = vimEngine else { return }
                engine.prepareForDisable()
                vimEngine = nil
                (textView as? VimTextView)?.vimEngine = nil
                let callback = onVimStatus
                DispatchQueue.main.async { callback?(VimStatus(enabled: false)) }
            }
            textView?.needsDisplay = true
        }

        /// Reload the buffer only when the model text was changed by something
        /// other than this text view (Format, Replace All). Guarded by an integer
        /// revision so we never do an O(n) string compare on every SwiftUI update.
        func syncProgrammaticChanges(text: String, revision: Int, language: LanguageMode) {
            let languageChanged = (language != self.language)
            self.language = language
            guard let textView = textView else { return }

            if revision != lastRevision {
                lastRevision = revision
                let caret = textView.selectedRange().location
                isProgrammaticChange = true
                textView.string = text
                isProgrammaticChange = false
                let clamped = NSRange(location: min(caret, (text as NSString).length), length: 0)
                textView.setSelectedRange(clamped)
                rebuildLineStarts(text as NSString)
                highlightVisibleRange()
                gutterView?.needsDisplay = true
                updateCursor()
                // A wholesale buffer swap invalidates any half-typed Vim
                // command; drop back to a clean normal mode.
                vimEngine?.reset()
            } else if languageChanged {
                highlightVisibleRange()
            }
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard !isProgrammaticChange, let textView = textView else { return }
            let text = textView.string
            rebuildLineStarts(text as NSString)
            // Typing updates the model via `updateText`, which does NOT bump
            // `editorRevision`, so `lastRevision` stays equal to the model's
            // revision and the coming `updateNSView` correctly skips a reload.
            onTextChange(text)
            scheduleHighlight()
            // Force a full redraw of the visible text. NSTextView otherwise only
            // invalidates the small changed rect, which doesn't reliably composite
            // when the view is hosted inside SwiftUI's layer-backed hierarchy —
            // the reported symptom where typed/pasted characters don't repaint
            // until a newline forces a larger relayout.
            textView.needsDisplay = true
            gutterView?.needsDisplay = true
            updateCursor()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            updateCursor()
            gutterView?.needsDisplay = true
            scheduleOccurrenceHighlight()
        }

        // MARK: Highlighting

        private func scheduleHighlight() {
            highlightWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.highlightVisibleRange() }
            highlightWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: work)
        }

        func highlightVisibleRange() {
            guard let textView = textView,
                  let layoutManager = textView.layoutManager,
                  let container = textView.textContainer,
                  let storage = textView.textStorage else { return }
            let glyphRange = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: container)
            let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            // Pad by a screenful so a flick-scroll still lands on colored text.
            let pad = max(charRange.length, 2000)
            let start = max(0, charRange.location - pad)
            let end = min(storage.length, NSMaxRange(charRange) + pad)
            highlighter.highlight(textStorage: storage,
                                  language: language,
                                  range: NSRange(location: start, length: end - start))
            textView.needsDisplay = true
        }

        // MARK: Occurrence highlighting

        private func scheduleOccurrenceHighlight() {
            occurrenceWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.highlightOccurrences() }
            occurrenceWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
        }

        /// Highlight every occurrence of the whole word under the caret, like an
        /// IDE. Uses the layout manager's *temporary* attributes so it's purely
        /// visual — no effect on the text, undo, or syntax colors.
        private func highlightOccurrences() {
            guard let textView = textView, let layoutManager = textView.layoutManager else { return }
            let nsText = textView.string as NSString
            let full = NSRange(location: 0, length: nsText.length)
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)

            // Skip very large files to keep clicks/arrows responsive.
            guard nsText.length > 0, nsText.length <= 1_000_000 else { return }

            let sel = textView.selectedRange()
            guard let wordRange = wordRange(at: sel.location, in: nsText) else { return }
            // If there's a selection, only proceed when it's exactly that word.
            if sel.length > 0, !NSEqualRanges(sel, wordRange) { return }

            let word = nsText.substring(with: wordRange)
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            let matches = regex.matches(in: nsText as String, options: [], range: full)
            guard matches.count > 1 else { return }   // nothing to shadow if it's unique

            let color = NSColor.systemYellow.withAlphaComponent(0.35)
            for match in matches {
                layoutManager.addTemporaryAttribute(.backgroundColor, value: color,
                                                    forCharacterRange: match.range)
            }
        }

        /// The range of the alphanumeric/underscore word containing `index`.
        private func wordRange(at index: Int, in nsText: NSString) -> NSRange? {
            let length = nsText.length
            guard length > 0 else { return nil }
            func isWord(_ i: Int) -> Bool {
                guard i >= 0, i < length else { return false }
                guard let scalar = Unicode.Scalar(nsText.character(at: i)) else { return false }
                return Coordinator.wordCharacterSet.contains(scalar)
            }
            guard isWord(index) || isWord(index - 1) else { return nil }
            var start = index
            var end = index
            while start > 0, isWord(start - 1) { start -= 1 }
            while end < length, isWord(end) { end += 1 }
            guard end > start else { return nil }
            return NSRange(location: start, length: end - start)
        }

        // MARK: Line bookkeeping

        private func rebuildLineStarts(_ s: NSString) {
            var starts: [Int] = [0]
            let length = s.length
            if length == 0 { lineStarts = starts; return }
            s.enumerateSubstrings(in: NSRange(location: 0, length: length),
                                  options: [.byLines, .substringNotRequired]) { _, _, enclosing, _ in
                let next = NSMaxRange(enclosing)
                if next < length { starts.append(next) }
            }
            lineStarts = starts
        }

        /// 1-based line number for a UTF-16 character index (binary search).
        func lineNumber(forCharacterIndex index: Int) -> Int {
            var lo = 0
            var hi = lineStarts.count - 1
            var result = 0
            while lo <= hi {
                let mid = (lo + hi) / 2
                if lineStarts[mid] <= index {
                    result = mid
                    lo = mid + 1
                } else {
                    hi = mid - 1
                }
            }
            return result + 1
        }

        var lineCount: Int { lineStarts.count }

        private func updateCursor() {
            guard let textView = textView else { return }
            let loc = textView.selectedRange().location
            let line = lineNumber(forCharacterIndex: loc)
            let column = loc - lineStarts[min(line - 1, lineStarts.count - 1)] + 1
            onCursorChange(line, max(column, 1))
        }
    }
}

// MARK: - Vim

/// Bridges `VimEngine` to the live `NSTextView`. Every mutation goes through
/// `shouldChangeText` / `didChangeText` so the edit lands in the undo stack and
/// reaches the document model through the normal delegate path.
extension EditorTextView.Coordinator: VimTextTarget {
    var vimString: NSString {
        // `mutableString` is the storage's own backing object — no copy, which
        // matters because the engine reads it on every key.
        textView?.textStorage?.mutableString ?? ""
    }

    var vimSelection: NSRange {
        get { textView?.selectedRange() ?? NSRange(location: 0, length: 0) }
        set { textView?.setSelectedRange(newValue) }
    }

    func vimReplace(_ range: NSRange, with text: String) {
        guard let textView, let storage = textView.textStorage else { return }
        let clamped = NSRange(location: min(range.location, storage.length),
                              length: min(range.length, max(0, storage.length - range.location)))
        guard textView.shouldChangeText(in: clamped, replacementString: text) else { return }
        storage.replaceCharacters(in: clamped, with: text)
        textView.didChangeText()
    }

    func vimScrollCaretVisible() {
        textView?.scrollRangeToVisible(textView?.selectedRange() ?? NSRange(location: 0, length: 0))
    }

    func vimAlignCaret(_ align: VimScrollAlign) {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let clip = textView.enclosingScrollView?.contentView else { return }
        let caret = textView.selectedRange()
        let glyphRange = layoutManager.glyphRange(forCharacterRange: caret, actualCharacterRange: nil)
        let lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        let height = clip.bounds.height
        let offset: CGFloat
        switch align {
        case .top: offset = lineRect.minY
        case .center: offset = lineRect.midY - height / 2
        case .bottom: offset = lineRect.maxY - height
        }
        let maxY = max(0, (textView.frame.height) - height)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(max(0, offset), maxY)))
        textView.enclosingScrollView?.reflectScrolledClipView(clip)
    }

    func vimFlash(_ range: NSRange) {
        textView?.showFindIndicator(for: range)
    }

    func vimUndo() {
        guard let manager = textView?.undoManager, manager.canUndo else { vimBeep(); return }
        manager.undo()
    }

    func vimRedo() {
        guard let manager = textView?.undoManager, manager.canRedo else { vimBeep(); return }
        manager.redo()
    }

    func vimBeep() {
        NSSound.beep()
    }

    var vimLinesPerPage: Int {
        guard let textView, let layoutManager = textView.layoutManager else { return 20 }
        let lineHeight = layoutManager.defaultLineHeight(for: textView.font ?? NSFont.systemFont(ofSize: 13))
        guard lineHeight > 0 else { return 20 }
        return max(Int(textView.visibleRect.height / lineHeight), 2)
    }
}

/// `NSTextView` that routes keystrokes through a `VimEngine` when one is
/// attached, and draws a block caret outside of insert mode.
final class VimTextView: NSTextView {
    var vimEngine: VimEngine? {
        didSet { needsDisplay = true }
    }

    override func keyDown(with event: NSEvent) {
        guard let engine = vimEngine else { super.keyDown(with: event); return }
        // Menu shortcuts (⌘S, ⌘F …) always win over the Vim layer.
        guard !event.modifierFlags.contains(.command),
              let key = VimKey(event: event) else { super.keyDown(with: event); return }
        if engine.handle(key: key) { return }
        super.keyDown(with: event)
    }

    /// Vim's normal/visual caret covers a whole character. Drawn translucent so
    /// the character underneath stays readable.
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        guard let engine = vimEngine, engine.mode != .insert else {
            super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
            return
        }
        var wide = rect
        wide.size.width = blockCaretWidth
        super.drawInsertionPoint(in: wide, color: color.withAlphaComponent(0.45), turnedOn: flag)
    }

    /// Without this the narrow invalidation rect AppKit computes leaves half of
    /// the block caret on screen when it blinks or moves.
    override func setNeedsDisplay(_ invalidRect: NSRect, avoidAdditionalLayout flag: Bool) {
        var rect = invalidRect
        if vimEngine != nil { rect.size.width += blockCaretWidth }
        super.setNeedsDisplay(rect, avoidAdditionalLayout: flag)
    }

    private var blockCaretWidth: CGFloat {
        let advance = font?.maximumAdvancement.width ?? 8
        return max(advance, 6)
    }
}

extension VimKey {
    /// Translate an AppKit key event. Returns `nil` for keys the engine has no
    /// concept of (function keys, dead keys), which the caller passes to
    /// `NSTextView` instead.
    init?(event: NSEvent) {
        guard let characters = event.charactersIgnoringModifiers,
              let scalar = characters.unicodeScalars.first else { return nil }

        switch Int(scalar.value) {
        case NSUpArrowFunctionKey: self.init("k")
        case NSDownArrowFunctionKey: self.init("j")
        case NSLeftArrowFunctionKey: self.init("h")
        case NSRightArrowFunctionKey: self.init("l")
        case NSPageUpFunctionKey: self.init("b", control: true)
        case NSPageDownFunctionKey: self.init("f", control: true)
        case NSHomeFunctionKey: self.init("0")
        case NSEndFunctionKey: self.init("$")
        default:
            // Remaining private-use code points are function keys.
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF { return nil }
            self.init(Character(scalar), control: event.modifierFlags.contains(.control))
        }
    }
}

/// A line-number gutter implemented as a plain `NSView` floating in the scroll
/// view's left content-inset margin (NOT an `NSRulerView`, which breaks text
/// compositing on Sequoia). It stays fixed while the text scrolls, drawing
/// numbers for the currently visible line fragments only.
final class LineNumberGutterView: NSView {
    private weak var textView: NSTextView?
    private weak var coordinator: EditorTextView.Coordinator?
    private let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    override var isFlipped: Bool { true }

    init(textView: NSTextView, coordinator: EditorTextView.Coordinator) {
        self.textView = textView
        self.coordinator = coordinator
        super.init(frame: NSRect(x: 0, y: 0, width: 46, height: 100))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()

        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        let content = textView.string as NSString
        let inset = textView.textContainerInset.height
        let visibleRect = textView.visibleRect
        let attrs: [NSAttributedString.Key: Any] = [
            .font: numberFont,
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        // Map a document-space y to this fixed gutter's coordinate space.
        func draw(_ number: Int, atDocY docY: CGFloat) {
            let y = docY - visibleRect.minY + inset
            let label = "\(number)" as NSString
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: bounds.width - size.width - 6, y: y), withAttributes: attrs)
        }

        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        var glyphIndex = visibleGlyphRange.location
        let end = NSMaxRange(visibleGlyphRange)
        while glyphIndex < end {
            var effectiveRange = NSRange()
            let fragmentRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex,
                                                              effectiveRange: &effectiveRange,
                                                              withoutAdditionalLayout: true)
            let charIndex = layoutManager.characterIndexForGlyph(at: effectiveRange.location)
            let logicalLine = content.lineRange(for: NSRange(location: charIndex, length: 0))
            if charIndex == logicalLine.location {
                let number = coordinator?.lineNumber(forCharacterIndex: charIndex) ?? 1
                draw(number, atDocY: fragmentRect.minY)
            }
            glyphIndex = NSMaxRange(effectiveRange)
        }

        // Trailing empty line (empty buffer, or one ending in "\n").
        if end == layoutManager.numberOfGlyphs {
            let extraRect = layoutManager.extraLineFragmentRect
            if extraRect.height > 0 {
                let number = content.length == 0 ? 1 : (coordinator?.lineCount ?? 0) + 1
                draw(number, atDocY: extraRect.minY)
            }
        }

        NSColor.separatorColor.setStroke()
        let border = NSBezierPath()
        border.move(to: NSPoint(x: bounds.width - 0.5, y: 0))
        border.line(to: NSPoint(x: bounds.width - 0.5, y: bounds.height))
        border.stroke()
    }
}
