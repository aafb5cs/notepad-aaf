import Foundation

struct SessionState: Codable {
    let tabs: [PersistedTab]
    /// Identity of the tab that was frontmost, so we can reselect it on restore.
    let selectedID: UUID?
}

final class SessionStore {
    private let key = "notepad-aaf.session.v1"

    func save(tabs: [EditorDocument], selected: EditorDocument?) {
        let persistedTabs = tabs.map { doc -> PersistedTab in
            // Keep the buffer for anything that isn't a clean on-disk file: that
            // covers brand-new untitled documents and unsaved edits, which are
            // exactly the cases the user would otherwise lose on quit.
            let needsText = doc.isDirty || doc.fileURL == nil
            return PersistedTab(
                id: doc.id,
                filePath: doc.fileURL?.path,
                languageOverride: doc.languageOverride,
                text: needsText ? doc.text : nil,
                isDirty: doc.isDirty
            )
        }
        let state = SessionState(tabs: persistedTabs, selectedID: selected?.id)
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    func restore() -> SessionState? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SessionState.self, from: data)
    }
}
