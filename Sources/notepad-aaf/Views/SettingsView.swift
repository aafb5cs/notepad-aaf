import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var workspace: EditorWorkspace
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings")
                .font(.title3.bold())

            // Scrollable so the panel keeps working as sections are added.
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    editorSection
                    aiSection
                    aboutSection
                }
                .padding(.horizontal, 1)   // room for the group boxes' edges
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460, height: 620)
    }

    private var editorSection: some View {
        GroupBox("Editor") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Theme", selection: $workspace.appearance) {
                    ForEach(AppAppearance.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("Restore open tabs on launch", isOn: $workspace.restoreSessionOnLaunch)

                Toggle("Auto-save", isOn: $workspace.autoSaveEnabled)
                HStack {
                    Text("Save every")
                    Spacer()
                    Picker("", selection: $workspace.autoSaveInterval) {
                        Text("10 seconds").tag(10.0)
                        Text("30 seconds").tag(30.0)
                        Text("1 minute").tag(60.0)
                        Text("5 minutes").tag(300.0)
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
                .disabled(!workspace.autoSaveEnabled)
                .foregroundStyle(workspace.autoSaveEnabled ? .primary : .secondary)
                Text("Writes tabs with unsaved changes back to their files. Untitled tabs are skipped — they need a save dialog, so save one with ⌘S and it's auto-saved from then on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Vim key bindings", isOn: $workspace.vimEnabled)
                Text("Modal editing: normal / insert / visual modes, operators with motions and text objects, registers, `/` search, `:w` `:q` `:s///`, and dot-repeat. Toggle any time with ⌃⌥V.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Text("Validation debounce")
                    Spacer()
                    Text("\(Int(workspace.validationDebounce * 1000)) ms")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $workspace.validationDebounce, in: 0.1...1.0, step: 0.05)
            }
            .padding(6)
        }
    }

    private var aiSection: some View {
        GroupBox("AI (Ask AI)") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Provider", selection: $workspace.llmProvider) {
                    ForEach(LLMProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }

                HStack {
                    Text("API key")
                    SecureField(workspace.llmProvider == .anthropic ? "sk-ant-…" : "sk-…",
                                text: $workspace.llmAPIKey)
                }

                HStack {
                    Text("Model")
                    TextField(workspace.llmProvider.defaultModel, text: $workspace.llmModel)
                }

                HStack {
                    Text("Base URL")
                    TextField(workspace.llmProvider.defaultBaseURL, text: $workspace.llmBaseURL)
                }

                Text("Leave model / base URL blank to use the defaults. The key is stored in this app's preferences in plain text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .textFieldStyle(.roundedBorder)
            .padding(6)
        }
    }

    private var aboutSection: some View {
        GroupBox("About") {
            VStack(alignment: .leading, spacing: 4) {
                Text("notepad-aaf")
                    .font(.headline)
                Text("A lightweight native macOS editor for JSON, YAML, XML and plain text.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }
}
