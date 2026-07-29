import SwiftUI

struct StatusBarView: View {
    @EnvironmentObject private var workspace: EditorWorkspace

    var body: some View {
        // The inner view observes the document directly so language / cursor /
        // validation / line-ending update live (observing only the workspace
        // misses document-level @Published changes).
        Group {
            if let doc = workspace.selectedDocument {
                StatusBarContent(document: doc, workspace: workspace, vim: workspace.vimStatus)
            } else {
                HStack { Spacer() }
            }
        }
        .font(.system(size: 11, weight: .regular, design: .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(height: 28)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(alignment: .top) { Divider() }
    }
}

private struct StatusBarContent: View {
    @ObservedObject var document: EditorDocument
    let workspace: EditorWorkspace
    let vim: VimStatus

    var body: some View {
        HStack(spacing: 14) {
            if vim.enabled {
                // Also a switch: clicking the badge turns Vim mode back off.
                Button { workspace.vimEnabled = false } label: {
                    Text(vim.mode.label)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 3).fill(modeColor))
                }
                .buttonStyle(.plain)
                .help("Vim mode is on — Esc returns to normal mode, click to turn Vim off (⌃⌥V)")
            }

            Label {
                Text(statusLabel(document.validationStatus))
            } icon: {
                Image(systemName: document.validationStatus.isValid ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(document.validationStatus.isValid ? Color.green : Color.orange)
            }

            Divider().frame(height: 14)

            Text("Ln \(document.cursorLine), Col \(document.cursorColumn)")
            Text("UTF-8")
            Text(document.lineEnding)

            if vim.enabled, let commandLine = vim.commandLine {
                // The `:` / `/` line being typed, shown where Vim puts it.
                Text(commandLine + "▏")
                    .lineLimit(1)
            } else if vim.enabled, !vim.message.isEmpty {
                Text(vim.message)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if vim.enabled, !vim.pending.isEmpty {
                Text(vim.pending)
                    .foregroundStyle(.secondary)
            }

            Picker("Language", selection: Binding(
                get: { document.effectiveLanguage },
                set: { workspace.applyLanguageOverride($0) }
            )) {
                ForEach(LanguageMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .labelsHidden()
            .frame(width: 160)
        }
    }

    private var modeColor: Color {
        switch vim.mode {
        case .normal: return .accentColor
        case .insert: return .green
        case .visual, .visualLine: return .orange
        }
    }

    private func statusLabel(_ status: ValidationStatus) -> String {
        if status.isValid { return "Valid" }
        if let line = status.line, let col = status.column {
            return "Invalid @ \(line):\(col)"
        }
        return "Invalid"
    }
}
