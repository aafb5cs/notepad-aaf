import AppKit
import Foundation

@MainActor
final class EditorWorkspace: ObservableObject {
    @Published var documents: [EditorDocument] = []
    @Published var selectedDocumentID: UUID?
    @Published var showFindReplace: Bool = false
    @Published var showSettings: Bool = false

    // File comparison (compare the active tab with the tab to its right).
    // The result is shown in its own resizable window; only the "no file to the
    // right" message uses SwiftUI alert state.
    @Published var showDiffMessage: Bool = false
    @Published var diffMessageText: String = ""
    private let diffWindow = DiffWindowController()
    @Published var showYAMLWarning: Bool = false
    @Published var pendingFormatter: FormatOption = .auto
    @Published var findQuery: String = ""
    @Published var replaceQuery: String = ""
    @Published var regexEnabled: Bool = false
    @Published var caseSensitive: Bool = false
    @Published var matchCount: Int = 0
    @Published var currentMatch: Int = 0
    @Published var findError: Bool = false

    /// The text view of the currently visible editor. Registered by the editor
    /// so find/replace can drive selection and edits on the live view.
    weak var activeTextView: NSTextView?

    @Published var restoreSessionOnLaunch: Bool = UserDefaults.standard.object(forKey: "notepad-aaf.restoreSession") as? Bool ?? true {
        didSet { UserDefaults.standard.set(restoreSessionOnLaunch, forKey: "notepad-aaf.restoreSession") }
    }
    @Published var validationDebounce: Double = UserDefaults.standard.object(forKey: "notepad-aaf.validationDebounce") as? Double ?? 0.3 {
        didSet { UserDefaults.standard.set(validationDebounce, forKey: "notepad-aaf.validationDebounce") }
    }
    /// Periodic write-back of edited files. Off by default; when on, dirty
    /// documents that already live on disk are written every `autoSaveInterval`.
    @Published var autoSaveEnabled: Bool = UserDefaults.standard.object(forKey: "notepad-aaf.autoSaveEnabled") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(autoSaveEnabled, forKey: "notepad-aaf.autoSaveEnabled")
            restartAutoSaveTimer()
        }
    }
    @Published var autoSaveInterval: Double = UserDefaults.standard.object(forKey: "notepad-aaf.autoSaveInterval") as? Double ?? 30 {
        didSet {
            UserDefaults.standard.set(autoSaveInterval, forKey: "notepad-aaf.autoSaveInterval")
            restartAutoSaveTimer()
        }
    }
    private var autoSaveTimer: Timer?

    /// Vim emulation. Off by default; persisted like the other preferences.
    @Published var vimEnabled: Bool = UserDefaults.standard.object(forKey: "notepad-aaf.vimEnabled") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(vimEnabled, forKey: "notepad-aaf.vimEnabled")
            if !vimEnabled { vimStatus = VimStatus(enabled: false) }
        }
    }
    /// Mode / pending keys / `:` line, mirrored into the status bar.
    @Published var vimStatus: VimStatus = VimStatus(enabled: false)

    @Published var appearance: AppAppearance =
        AppAppearance(rawValue: UserDefaults.standard.string(forKey: "notepad-aaf.appearance") ?? "") ?? .system {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: "notepad-aaf.appearance")
            applyAppearance()
        }
    }

    // "Ask AI" configuration (stored in UserDefaults; the API key is plaintext).
    @Published var llmProvider: LLMProvider =
        LLMProvider(rawValue: UserDefaults.standard.string(forKey: "notepad-aaf.llm.provider") ?? "") ?? .anthropic {
        didSet { UserDefaults.standard.set(llmProvider.rawValue, forKey: "notepad-aaf.llm.provider") }
    }
    @Published var llmAPIKey: String = UserDefaults.standard.string(forKey: "notepad-aaf.llm.apiKey") ?? "" {
        didSet { UserDefaults.standard.set(llmAPIKey, forKey: "notepad-aaf.llm.apiKey") }
    }
    @Published var llmModel: String = UserDefaults.standard.string(forKey: "notepad-aaf.llm.model") ?? "" {
        didSet { UserDefaults.standard.set(llmModel, forKey: "notepad-aaf.llm.model") }
    }
    @Published var llmBaseURL: String = UserDefaults.standard.string(forKey: "notepad-aaf.llm.baseURL") ?? "" {
        didSet { UserDefaults.standard.set(llmBaseURL, forKey: "notepad-aaf.llm.baseURL") }
    }
    private let askAIWindow = AskAIWindowController()

    private let validators = Validators()
    private let formatters = Formatters()
    private let sessionStore = SessionStore()
    private var validationWorkItems: [UUID: DispatchWorkItem] = [:]
    private var sessionPersistWorkItem: DispatchWorkItem?

    init() {
        applyAppearance()
        restartAutoSaveTimer()
        if restoreSessionOnLaunch {
            restoreSession()
        }
        if documents.isEmpty {
            newDocument()
        }

        // Persist the session whenever the app loses focus (Cmd-Tab away) or
        // quits, so the current tabs/selection and any unsaved text are captured
        // even without an explicit Save.
        for name in [NSApplication.willResignActiveNotification,
                     NSApplication.willTerminateNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.persistSession() }
            }
        }
    }

    var selectedDocument: EditorDocument? {
        get { documents.first(where: { $0.id == selectedDocumentID }) }
        set { selectedDocumentID = newValue?.id }
    }

    func newDocument() {
        let doc = EditorDocument()
        documents.append(doc)
        selectedDocumentID = doc.id
        persistSession()
    }

    func closeDocument(_ document: EditorDocument) {
        documents.removeAll { $0.id == document.id }
        if selectedDocumentID == document.id {
            selectedDocumentID = documents.first?.id
        }
        if documents.isEmpty {
            newDocument()
        }
        persistSession()
    }

    func saveSelectedDocument() {
        guard let doc = selectedDocument else { return }
        if doc.fileURL == nil {
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = doc.displayName
            if panel.runModal() == .OK {
                doc.fileURL = panel.url
            } else {
                return
            }
        }

        if write(doc) {
            persistSession()
        } else {
            NSSound.beep()
        }
    }

    /// Write a document to its file. Returns `false` (leaving the tab dirty) if
    /// it has nowhere to go or the write failed.
    @discardableResult
    private func write(_ document: EditorDocument) -> Bool {
        guard let url = document.fileURL else { return false }
        do {
            try document.text.write(to: url, atomically: true, encoding: .utf8)
            document.isDirty = false
            return true
        } catch {
            return false
        }
    }

    // MARK: - Auto-save

    /// Untitled tabs are deliberately excluded: saving one needs a save panel,
    /// and a timer must never put a modal dialog on screen. They keep their
    /// unsaved text through the session store instead.
    nonisolated static func shouldAutoSave(_ document: EditorDocument) -> Bool {
        document.isDirty && document.fileURL != nil
    }

    /// Write every eligible dirty document. A failed write stays dirty, so the
    /// tab keeps showing unsaved changes rather than silently losing them.
    func autoSaveDirtyDocuments() {
        let targets = documents.filter { EditorWorkspace.shouldAutoSave($0) }
        guard !targets.isEmpty else { return }
        var written = 0
        for document in targets where write(document) { written += 1 }
        if written > 0 { persistSession() }
    }

    private func restartAutoSaveTimer() {
        autoSaveTimer?.invalidate()
        autoSaveTimer = nil
        guard autoSaveEnabled, autoSaveInterval > 0 else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: autoSaveInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoSaveDirtyDocuments() }
        }
        // Generous tolerance: this is housekeeping, it shouldn't wake the CPU
        // on a precise schedule.
        timer.tolerance = autoSaveInterval * 0.25
        autoSaveTimer = timer
    }

    func openFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = []

        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            if let existing = documents.first(where: { $0.fileURL == url }) {
                selectedDocumentID = existing.id
                continue
            }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                let doc = EditorDocument(fileURL: url, text: text, isDirty: false)
                documents.append(doc)
                selectedDocumentID = doc.id
                validateDebounced(document: doc)
            } catch {
                NSSound.beep()
            }
        }
        persistSession()
    }

    /// Compare the active document with the file in the tab immediately to its
    /// right. If the active tab is the rightmost (no file to the right), show a
    /// message instead.
    func compareWithRight() {
        guard let current = selectedDocument,
              let idx = documents.firstIndex(where: { $0.id == current.id }) else { return }
        let rightIndex = idx + 1
        guard rightIndex < documents.count else {
            diffMessageText = "There's no file to the right of “\(current.displayName)” to compare with.\n\nOpen a second file (it opens as a new tab on the right), or select the left file, then compare."
            showDiffMessage = true
            return
        }
        let rightDoc = documents[rightIndex]
        let result = DiffEngine.diff(left: current.text, right: rightDoc.text)
        diffWindow.present(diff: result, leftName: current.displayName, rightName: rightDoc.displayName)
    }

    // MARK: - Vim

    /// Carry out the `:` commands the engine hands back (it owns everything
    /// that only touches the buffer; these touch the document).
    func handleVimFileCommand(_ command: VimFileCommand) {
        switch command {
        case .write:
            saveSelectedDocument()
        case .quit:
            guard let doc = selectedDocument else { return }
            if doc.isDirty {
                vimStatus.message = "No write since last change (add ! to override)"
                NSSound.beep()
            } else {
                closeDocument(doc)
            }
        case .forceQuit:
            if let doc = selectedDocument { closeDocument(doc) }
        case .writeQuit:
            saveSelectedDocument()
            if let doc = selectedDocument, !doc.isDirty { closeDocument(doc) }
        }
    }

    /// Force the app-wide appearance to the chosen theme (or follow the system).
    func applyAppearance() {
        NSApplication.shared.appearance = appearance.nsAppearance
    }

    // MARK: - Ask AI

    var llmConfig: LLMConfig {
        LLMConfig(provider: llmProvider, apiKey: llmAPIKey, model: llmModel, baseURL: llmBaseURL)
    }

    /// Open the AI chat for the current document. The note is captured now and
    /// sent as context; the window is resizable and reused across opens.
    func openAskAI() {
        guard let doc = selectedDocument else { return }
        let chat = AskAIChat(
            fileName: doc.displayName,
            noteText: doc.text,
            config: llmConfig,
            onInsert: { [weak self] text in self?.insertIntoEditor(text) },
            onOpenSettings: { [weak self] in self?.showSettings = true })
        askAIWindow.present(chat: chat)
    }

    /// Insert `text` into the active editor at the cursor (replacing any
    /// selection). Undoable, and flows back through the normal change pipeline.
    func insertIntoEditor(_ text: String) {
        guard let tv = activeTextView else { NSSound.beep(); return }
        let range = tv.selectedRange()
        if tv.shouldChangeText(in: range, replacementString: text) {
            tv.textStorage?.replaceCharacters(in: range, with: text)
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: range.location + (text as NSString).length, length: 0))
            tv.window?.makeFirstResponder(tv)
        }
    }

    func updateText(for document: EditorDocument, text: String) {
        document.text = text
        document.isDirty = true
        validateDebounced(document: document)
        schedulePersistSession()
    }

    /// Replace a document's text from outside the editor view (Format, Replace
    /// All). Bumps `editorRevision` so the editor reloads its buffer.
    func applyProgrammaticText(for document: EditorDocument, text: String) {
        document.text = text
        document.isDirty = true
        document.editorRevision += 1
        validateDebounced(document: document)
        schedulePersistSession()
    }

    func updateCursor(for document: EditorDocument, line: Int, column: Int) {
        document.cursorLine = line
        document.cursorColumn = column
    }

    func applyLanguageOverride(_ mode: LanguageMode) {
        selectedDocument?.languageOverride = mode
        if let selectedDocument {
            validateDebounced(document: selectedDocument)
        }
        persistSession()
    }

    func formatSelected(primary: Bool = true, explicitOption: FormatOption? = nil) {
        guard let doc = selectedDocument else { return }

        // "Just format it": if the document is in plain-text mode and the user
        // hit the generic Format action, sniff the content for JSON/XML, switch
        // the language mode to match (so highlighting + validation follow) and
        // pretty-print it.
        if explicitOption == nil, doc.effectiveLanguage == .plainText,
           let detected = detectFormattableLanguage(doc.text) {
            doc.languageOverride = detected
            validateDebounced(document: doc)
        }

        let option = explicitOption ?? defaultFormatOption(for: doc.effectiveLanguage)

        if doc.effectiveLanguage == .yaml && option == .yamlSafeReindent && primary {
            pendingFormatter = option
            showYAMLWarning = true
            return
        }

        do {
            let formatted = try formatters.format(doc.text, mode: doc.effectiveLanguage, option: option)
            applyProgrammaticText(for: doc, text: formatted)
        } catch {
            NSSound.beep()
        }
    }

    func confirmYAMLFormatting() {
        showYAMLWarning = false
        formatSelected(primary: false, explicitOption: pendingFormatter)
    }

    // MARK: - Text transforms

    /// Apply `transform` to the current selection, or the whole document when
    /// nothing is selected. Undoable; re-selects the transformed range.
    private func transformActiveText(_ transform: (String) -> String?) {
        guard let tv = activeTextView else { NSSound.beep(); return }
        let nsText = tv.string as NSString
        var range = tv.selectedRange()
        if range.length == 0 { range = NSRange(location: 0, length: nsText.length) }
        guard range.length > 0, let result = transform(nsText.substring(with: range)) else {
            NSSound.beep(); return
        }
        if tv.shouldChangeText(in: range, replacementString: result) {
            tv.textStorage?.replaceCharacters(in: range, with: result)
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: range.location, length: (result as NSString).length))
        }
    }

    /// Percent-decode the selection/document (e.g. `%20` → space, `%2F` → `/`).
    /// Like `decodeURIComponent`, `+` is left as-is so base64 tokens aren't harmed.
    func urlDecode() {
        transformActiveText { $0.removingPercentEncoding }
    }

    /// Percent-encode the selection/document (everything but RFC 3986 unreserved).
    func urlEncode() {
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        transformActiveText { $0.addingPercentEncoding(withAllowedCharacters: unreserved) }
    }

    // MARK: - Find & Replace

    /// All match ranges for the current query in `nsText` (empty on invalid regex).
    private func searchRanges(in nsText: NSString) -> [NSRange] {
        guard !findQuery.isEmpty else { return [] }
        let full = NSRange(location: 0, length: nsText.length)
        if regexEnabled {
            var opts: NSRegularExpression.Options = []
            if !caseSensitive { opts.insert(.caseInsensitive) }
            guard let regex = try? NSRegularExpression(pattern: findQuery, options: opts) else { return [] }
            return regex.matches(in: nsText as String, options: [], range: full).map(\.range)
        } else {
            var result: [NSRange] = []
            let opts: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
            var start = 0
            while start < nsText.length {
                let r = nsText.range(of: findQuery, options: opts,
                                     range: NSRange(location: start, length: nsText.length - start))
                if r.location == NSNotFound { break }
                result.append(r)
                start = r.location + max(r.length, 1)
            }
            return result
        }
    }

    private func regexIsValid() -> Bool {
        guard regexEnabled, !findQuery.isEmpty else { return true }
        return (try? NSRegularExpression(pattern: findQuery)) != nil
    }

    /// Recompute the match count/position without moving the selection.
    func updateMatchCount() {
        findError = !regexIsValid()
        guard let tv = activeTextView, !findError else { matchCount = 0; currentMatch = 0; return }
        let ranges = searchRanges(in: tv.string as NSString)
        matchCount = ranges.count
        let sel = tv.selectedRange()
        if let idx = ranges.firstIndex(where: { NSEqualRanges($0, sel) }) {
            currentMatch = idx + 1
        } else {
            currentMatch = 0
        }
    }

    func findNext(forward: Bool = true) {
        findError = !regexIsValid()
        guard let tv = activeTextView, !findError else { return }
        let nsText = tv.string as NSString
        let ranges = searchRanges(in: nsText)
        matchCount = ranges.count
        guard !ranges.isEmpty else { currentMatch = 0; NSSound.beep(); return }

        let sel = tv.selectedRange()
        let target: Int
        if forward {
            target = ranges.firstIndex(where: { $0.location >= NSMaxRange(sel) }) ?? 0
        } else {
            target = ranges.lastIndex(where: { NSMaxRange($0) <= sel.location }) ?? (ranges.count - 1)
        }
        let range = ranges[target]
        tv.setSelectedRange(range)
        tv.scrollRangeToVisible(range)
        tv.showFindIndicator(for: range)
        currentMatch = target + 1
    }

    private func replacement(for matchedText: String) -> String {
        guard regexEnabled else { return replaceQuery }
        var opts: NSRegularExpression.Options = []
        if !caseSensitive { opts.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: findQuery, options: opts) else { return replaceQuery }
        let ns = matchedText as NSString
        return regex.stringByReplacingMatches(in: matchedText,
                                              range: NSRange(location: 0, length: ns.length),
                                              withTemplate: replaceQuery)
    }

    private func selectionIsMatch(_ nsText: NSString, _ sel: NSRange) -> Bool {
        guard sel.length > 0, sel.location != NSNotFound, NSMaxRange(sel) <= nsText.length else { return false }
        let sub = nsText.substring(with: sel)
        if regexEnabled {
            var opts: NSRegularExpression.Options = []
            if !caseSensitive { opts.insert(.caseInsensitive) }
            guard let regex = try? NSRegularExpression(pattern: findQuery, options: opts) else { return false }
            let range = NSRange(location: 0, length: (sub as NSString).length)
            if let m = regex.firstMatch(in: sub, options: [.anchored], range: range) {
                return m.range.length == range.length
            }
            return false
        } else {
            return sub.compare(findQuery, options: caseSensitive ? [] : [.caseInsensitive]) == .orderedSame
        }
    }

    /// Replace the current selection if it's a match, then advance to the next.
    func replaceCurrent() {
        findError = !regexIsValid()
        guard let tv = activeTextView, !findError, !findQuery.isEmpty else { return }
        let nsText = tv.string as NSString
        let sel = tv.selectedRange()
        if selectionIsMatch(nsText, sel) {
            let newText = replacement(for: nsText.substring(with: sel))
            if tv.shouldChangeText(in: sel, replacementString: newText) {
                tv.textStorage?.replaceCharacters(in: sel, with: newText)
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: sel.location + (newText as NSString).length, length: 0))
            }
        }
        findNext(forward: true)
    }

    func replaceAll() {
        findError = !regexIsValid()
        guard let tv = activeTextView, !findError, !findQuery.isEmpty else { return }
        let nsText = tv.string as NSString
        let full = NSRange(location: 0, length: nsText.length)
        let newString: String
        if regexEnabled {
            var opts: NSRegularExpression.Options = []
            if !caseSensitive { opts.insert(.caseInsensitive) }
            guard let regex = try? NSRegularExpression(pattern: findQuery, options: opts) else { NSSound.beep(); return }
            newString = regex.stringByReplacingMatches(in: nsText as String, range: full, withTemplate: replaceQuery)
        } else {
            newString = nsText.replacingOccurrences(of: findQuery, with: replaceQuery,
                                                    options: caseSensitive ? [] : [.caseInsensitive], range: full)
        }
        if tv.shouldChangeText(in: full, replacementString: newString) {
            tv.textStorage?.replaceCharacters(in: full, with: newString)
            tv.didChangeText()
        }
        matchCount = 0
        currentMatch = 0
    }

    func validateDebounced(document: EditorDocument) {
        validationWorkItems[document.id]?.cancel()
        let id = document.id
        let text = document.text
        let mode = document.effectiveLanguage

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let status = self.validators.validate(text: text, mode: mode)
            Task { @MainActor in
                guard let target = self.documents.first(where: { $0.id == id }) else { return }
                target.validationStatus = status
            }
        }
        validationWorkItems[document.id] = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + validationDebounce, execute: work)
    }

    func defaultFormatOption(for mode: LanguageMode) -> FormatOption {
        switch mode {
        case .json: return .jsonPretty
        case .xml: return .xmlPretty
        case .yaml: return .yamlSafeReindent
        case .sql: return .sqlPretty
        case .nginx: return .nginxPretty
        case .plainText: return .auto
        }
    }

    /// Sniff plain-text content for a formattable structured language.
    private func detectFormattableLanguage(_ text: String) -> LanguageMode? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if (trimmed.hasPrefix("{") || trimmed.hasPrefix("[")),
           let data = trimmed.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return .json
        }
        if trimmed.hasPrefix("<"), (try? XMLDocument(xmlString: trimmed, options: [])) != nil {
            return .xml
        }
        // Only sniff SQL when the text opens with a statement keyword — anything
        // looser would misfire on ordinary prose.
        let firstWord = trimmed.prefix(while: { $0.isLetter }).uppercased()
        if ["SELECT", "INSERT", "UPDATE", "DELETE", "CREATE", "ALTER", "DROP", "WITH", "TRUNCATE"]
            .contains(firstWord) {
            return .sql
        }
        // Needs a block directive *and* a terminated directive, so `{ }`-heavy
        // text that isn't a config doesn't get reformatted as one.
        if NginxFormatter.looksLikeConfig(trimmed) {
            return .nginx
        }
        return nil
    }

    func persistSession() {
        sessionPersistWorkItem?.cancel()
        sessionStore.save(tabs: documents, selected: selectedDocument)
    }

    /// Coalesce rapid edits into a single session write ~0.5s after typing stops,
    /// so keystrokes don't hammer UserDefaults.
    private func schedulePersistSession() {
        sessionPersistWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.persistSession() }
        }
        sessionPersistWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func restoreSession() {
        guard let state = sessionStore.restore() else { return }
        for tab in state.tabs {
            let url = tab.filePath.map { URL(fileURLWithPath: $0) }
            let text: String
            if let stored = tab.text {
                // Unsaved/dirty tab: use the buffer we saved at quit.
                text = stored
            } else if let url, let disk = try? String(contentsOf: url, encoding: .utf8) {
                // Clean on-disk file: re-read current contents.
                text = disk
            } else {
                // File was moved/deleted and we have no stored text — drop the tab.
                continue
            }
            let doc = EditorDocument(id: tab.id, fileURL: url, text: text,
                                     isDirty: tab.isDirty, languageOverride: tab.languageOverride)
            documents.append(doc)
            validateDebounced(document: doc)
        }
        if let selectedID = state.selectedID,
           documents.contains(where: { $0.id == selectedID }) {
            selectedDocumentID = selectedID
        } else {
            selectedDocumentID = documents.first?.id
        }
    }
}
