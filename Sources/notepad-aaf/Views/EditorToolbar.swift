import SwiftUI

/// A custom in-window toolbar strip. We host the SwiftUI view tree in a
/// hand-made `NSWindow` (see `AppDelegate`), where SwiftUI's `.toolbar`
/// modifier isn't reliably rendered — so the toolbar lives in the layout itself.
struct EditorToolbar: View {
    @EnvironmentObject private var workspace: EditorWorkspace

    private var formatTitle: String {
        switch workspace.selectedDocument?.effectiveLanguage {
        case .json: return "Format JSON"
        case .xml: return "Format XML"
        case .yaml: return "Re-indent YAML"
        case .sql: return "Format SQL"
        case .nginx: return "Re-indent NGINX"
        default: return "Format"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            toolButton("New", "plus.square") { workspace.newDocument() }
            toolButton("Open", "folder") { workspace.openFile() }
            toolButton("Save", "square.and.arrow.down") { workspace.saveSelectedDocument() }

            Divider().frame(height: 18)

            toolButton("Find & Replace", "magnifyingglass") { workspace.showFindReplace = true }
            toolButton("Compare with file on the right", "rectangle.split.2x1") { workspace.compareWithRight() }
            toolButton("Ask AI about this file", "sparkles") { workspace.openAskAI() }
                .disabled(workspace.selectedDocument == nil)

            // Split "Format" button: primary action formats with the language
            // default; the menu exposes the format-specific options.
            Menu {
                Button("JSON: Pretty print") { workspace.formatSelected(primary: false, explicitOption: .jsonPretty) }
                Button("JSON: Minify") { workspace.formatSelected(primary: false, explicitOption: .jsonMinify) }
                Button("XML: Pretty print") { workspace.formatSelected(primary: false, explicitOption: .xmlPretty) }
                Button("YAML: Safe re-indent") { workspace.formatSelected(primary: true, explicitOption: .yamlSafeReindent) }
                Button("SQL: Format") { workspace.formatSelected(primary: false, explicitOption: .sqlPretty) }
                Button("SQL: Single line") { workspace.formatSelected(primary: false, explicitOption: .sqlCompact) }
                Button("NGINX: Re-indent") { workspace.formatSelected(primary: false, explicitOption: .nginxPretty) }
                Divider()
                Button("URL Decode") { workspace.urlDecode() }
                Button("URL Encode") { workspace.urlEncode() }
            } label: {
                Label(formatTitle, systemImage: "wand.and.stars")
            } primaryAction: {
                workspace.formatSelected()
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(workspace.selectedDocument == nil)

            Spacer()

            // Vim on/off, as an actual switch so the current state is readable
            // at a glance without opening Settings.
            Toggle(isOn: $workspace.vimEnabled) {
                Image(systemName: "keyboard")
                    .font(.system(size: 12))
                    .foregroundStyle(workspace.vimEnabled ? Color.accentColor : Color.secondary)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help(workspace.vimEnabled ? "Vim mode: on — click to disable (⌃⌥V)"
                                       : "Vim mode: off — click to enable (⌃⌥V)")
            .accessibilityLabel("Vim mode")

            Divider().frame(height: 18)


            toolButton("Settings", "gearshape") { workspace.showSettings = true }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func toolButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .frame(width: 26, height: 22)
        }
        .buttonStyle(.borderless)
        .help(title)
    }
}
