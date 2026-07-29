import AppKit
import SwiftUI

@main
struct NotepadAAFApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var workspace = EditorWorkspace()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(workspace)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { workspace.showSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button("New") { workspace.newDocument() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Open…") { workspace.openFile() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { workspace.saveSelectedDocument() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Close Tab") {
                    if let doc = workspace.selectedDocument { workspace.closeDocument(doc) }
                }
                .keyboardShortcut("w", modifiers: .command)
            }
            CommandGroup(after: .textEditing) {
                Button("Find & Replace…") { workspace.showFindReplace = true }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Compare With File on Right") { workspace.compareWithRight() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Ask AI…") { workspace.openAskAI() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Divider()
                Button(workspace.vimEnabled ? "Disable Vim Mode" : "Enable Vim Mode") {
                    workspace.vimEnabled.toggle()
                }
                .keyboardShortcut("v", modifiers: [.control, .option])
            }
            CommandMenu("Format") {
                Button("Format Document") { workspace.formatSelected() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Divider()
                Button("URL Decode") { workspace.urlDecode() }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                Button("URL Encode") { workspace.urlEncode() }
                    .keyboardShortcut("u", modifiers: [.command, .control])
            }
        }
    }
}

/// Minimal delegate: promote to a regular foreground app (matters when launched
/// as a bare binary) and persist the session on quit. The SwiftUI `App`
/// lifecycle owns the window and its rendering.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--selftest") {
            exit(SelfTest.run())
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
