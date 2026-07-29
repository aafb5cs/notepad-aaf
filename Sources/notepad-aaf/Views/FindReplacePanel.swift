import SwiftUI

/// Inline Find & Replace bar (VS Code / Notepad++ style). Lives in the layout
/// above the editor so the editor stays interactive while searching — Find Next
/// moves and flashes the selection in the live text view.
struct FindReplaceBar: View {
    @EnvironmentObject private var workspace: EditorWorkspace
    @FocusState private var findFocused: Bool

    var body: some View {
        VStack(spacing: 6) {
            // Find row
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    TextField("Find", text: $workspace.findQuery)
                        .textFieldStyle(.plain)
                        .focused($findFocused)
                        .onSubmit { workspace.findNext(forward: !NSEvent.modifierFlags.contains(.shift)) }
                        .frame(minWidth: 160)
                    toggle("Aa", help: "Match case", isOn: $workspace.caseSensitive)
                    toggle(".*", help: "Regular expression", isOn: $workspace.regexEnabled)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(fieldBackground)

                Text(matchLabel)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(workspace.findError ? Color.red : Color.secondary)
                    .frame(minWidth: 66, alignment: .leading)

                iconButton("chevron.left", help: "Previous (⇧⏎)") { workspace.findNext(forward: false) }
                iconButton("chevron.right", help: "Next (⏎)") { workspace.findNext(forward: true) }
                iconButton("xmark", help: "Close (Esc)") { workspace.showFindReplace = false }
            }

            // Replace row
            HStack(spacing: 6) {
                TextField("Replace", text: $workspace.replaceQuery)
                    .textFieldStyle(.plain)
                    .onSubmit { workspace.replaceCurrent() }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(fieldBackground)

                Button("Replace") { workspace.replaceCurrent() }
                Button("Replace All") { workspace.replaceAll() }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
        .overlay {
            // Esc closes the bar (works while a field is focused).
            Button("") { workspace.showFindReplace = false }
                .keyboardShortcut(.cancelAction)
                .frame(width: 0, height: 0)
                .opacity(0)
        }
        .onAppear { findFocused = true; workspace.updateMatchCount() }
        .onChange(of: workspace.findQuery) { _ in workspace.updateMatchCount() }
        .onChange(of: workspace.regexEnabled) { _ in workspace.updateMatchCount() }
        .onChange(of: workspace.caseSensitive) { _ in workspace.updateMatchCount() }
        .onChange(of: workspace.selectedDocumentID) { _ in workspace.updateMatchCount() }
    }

    private var matchLabel: String {
        if workspace.findError { return "Bad regex" }
        if workspace.findQuery.isEmpty { return "" }
        if workspace.matchCount == 0 { return "No results" }
        if workspace.currentMatch == 0 { return "\(workspace.matchCount) found" }
        return "\(workspace.currentMatch) of \(workspace.matchCount)"
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(Color(NSColor.textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).frame(width: 22, height: 20)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private func toggle(_ label: String, help: String, isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .frame(width: 22, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isOn.wrappedValue ? Color.accentColor.opacity(0.85) : Color.clear)
                )
                .foregroundStyle(isOn.wrappedValue ? Color.white : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
