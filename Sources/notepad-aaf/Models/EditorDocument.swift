import Foundation

final class EditorDocument: ObservableObject, Identifiable {
    let id: UUID
    @Published var fileURL: URL?
    @Published var text: String
    @Published var isDirty: Bool
    @Published var languageOverride: LanguageMode?
    @Published var validationStatus: ValidationStatus
    @Published var cursorLine: Int
    @Published var cursorColumn: Int

    /// Bumped whenever `text` is replaced by something other than the editor view
    /// itself (Format, Replace All, reload). The editor watches this to know when
    /// to reload its buffer without doing an O(n) string comparison every update.
    @Published var editorRevision: Int = 0

    init(
        id: UUID = UUID(),
        fileURL: URL? = nil,
        text: String = "",
        isDirty: Bool = false,
        languageOverride: LanguageMode? = nil
    ) {
        self.id = id
        self.fileURL = fileURL
        self.text = text
        self.isDirty = isDirty
        self.languageOverride = languageOverride
        self.validationStatus = .idle
        self.cursorLine = 1
        self.cursorColumn = 1
    }

    var displayName: String {
        if let name = fileURL?.lastPathComponent, !name.isEmpty {
            return name
        }
        return "Untitled"
    }

    var effectiveLanguage: LanguageMode {
        languageOverride ?? LanguageMode.inferred(from: fileURL)
    }

    var lineEnding: String {
        text.contains("\r\n") ? "CRLF" : "LF"
    }
}

struct PersistedTab: Codable {
    let id: UUID
    /// Absolute path on disk, or `nil` for a never-saved ("Untitled") document.
    let filePath: String?
    let languageOverride: LanguageMode?
    /// Buffer contents, stored only for unsaved/dirty tabs so their in-progress
    /// text survives a quit. `nil` for clean on-disk files (re-read from disk).
    let text: String?
    let isDirty: Bool
}
