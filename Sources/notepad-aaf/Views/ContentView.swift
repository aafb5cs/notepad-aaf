import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var workspace: EditorWorkspace

    var body: some View {
        VStack(spacing: 0) {
            EditorToolbar()
            Divider()
            TabStripView()
            Divider()
            if workspace.showFindReplace {
                FindReplaceBar()
                    .environmentObject(workspace)
            }
            editorArea
            StatusBarView()
        }
        .confirmationDialog("YAML formatting safety", isPresented: $workspace.showYAMLWarning, titleVisibility: .visible) {
            Button("Apply safe re-indent") {
                workspace.confirmYAMLFormatting()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("YAML indentation is semantic. This command only performs conservative whitespace normalization.")
        }
        .sheet(isPresented: $workspace.showSettings) {
            SettingsView()
                .environmentObject(workspace)
        }
        .alert("Compare files", isPresented: $workspace.showDiffMessage) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(workspace.diffMessageText)
        }
    }

    @ViewBuilder
    private var editorArea: some View {
        if let doc = workspace.selectedDocument {
            EditorTextView(document: doc, onTextChange: { updatedText in
                workspace.updateText(for: doc, text: updatedText)
            }, onCursorChange: { line, col in
                workspace.updateCursor(for: doc, line: line, column: col)
            }, onTextViewReady: { tv in
                workspace.activeTextView = tv
            }, vimEnabled: workspace.vimEnabled, onVimStatus: { status in
                workspace.vimStatus = status
            }, onVimFileCommand: { command in
                workspace.handleVimFileCommand(command)
            })
            .id(doc.id)
            .clipped()
        } else {
            VStack(spacing: 8) {
                Image(systemName: "doc")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text("No document selected")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.textBackgroundColor))
        }
    }
}
