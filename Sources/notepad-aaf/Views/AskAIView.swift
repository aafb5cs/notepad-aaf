import SwiftUI
import AppKit

/// The "Ask AI" chat panel: a scrolling transcript, a multi-line prompt box, and
/// per-answer Copy / Insert actions. Hosted in its own resizable window
/// (`AskAIWindowController`).
struct AskAIView: View {
    @ObservedObject var chat: AskAIChat

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !chat.isConfigured {
                notConfiguredBanner
                Divider()
            }
            transcript
            Divider()
            composer
        }
        .frame(minWidth: 460, minHeight: 380)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
            VStack(alignment: .leading, spacing: 1) {
                Text("Ask AI").font(.headline)
                Text("Chatting about “\(chat.fileName)”")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var notConfiguredBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text("Add an API key to start chatting.")
                .font(.system(size: 12))
            Spacer()
            Button("Open Settings…") { chat.onOpenSettings() }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if chat.messages.isEmpty {
                        emptyState
                    }
                    ForEach(chat.messages) { message in
                        MessageBubble(message: message, onInsert: chat.onInsert)
                            .id(message.id)
                    }
                    if chat.isSending {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Thinking…").foregroundStyle(.secondary).font(.system(size: 12))
                        }
                        .id("sending")
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(NSColor.textBackgroundColor))
            .onChange(of: chat.messages.count) { _ in
                if let last = chat.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            .onChange(of: chat.isSending) { sending in
                if sending { withAnimation { proxy.scrollTo("sending", anchor: .bottom) } }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ask about this file")
                .font(.system(size: 13, weight: .medium))
            Text("Your question is sent along with the file's current contents. Try “summarize this”, “find bugs”, or “convert this JSON to YAML”.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 4)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextEditor(text: $chat.input)
                .font(.system(size: 13))
                .frame(minHeight: 34, maxHeight: 120)
                .overlay(alignment: .topLeading) {
                    if chat.input.isEmpty {
                        Text("Ask a question…")
                            .foregroundStyle(.tertiary)
                            .font(.system(size: 13))
                            .padding(.leading, 5)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor)))

            Button {
                chat.submit()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
            }
            .buttonStyle(.plain)
            .foregroundStyle(chat.canSubmit ? Color.accentColor : Color.secondary)
            .disabled(!chat.canSubmit)
            .help("Send")
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(12)
    }
}

private struct MessageBubble: View {
    let message: AskAIChat.Message
    let onInsert: (String) -> Void
    @State private var copied = false

    private var isUser: Bool { message.role == .user }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            Text(isUser ? "You" : "AI")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)

            Text(message.text)
                .font(.system(size: 13, design: isUser ? .default : .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(message.isError ? Color.red : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(bubbleColor))
                .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)

            if !isUser && !message.isError {
                HStack(spacing: 10) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.text, forType: .string)
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    Button {
                        onInsert(message.text)
                    } label: {
                        Label("Insert into note", systemImage: "text.insert")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var bubbleColor: Color {
        if message.isError { return Color.red.opacity(0.10) }
        return isUser ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.10)
    }
}

/// Presents an `AskAIView` in a standalone, user-resizable window (not a
/// fixed-size sheet). Reuses one window across invocations.
@MainActor
final class AskAIWindowController {
    private var window: NSWindow?

    func present(chat: AskAIChat) {
        let root = AskAIView(chat: chat)
        let hosting = NSHostingView(rootView: root)

        let window = self.window ?? makeWindow()
        window.title = "Ask AI — \(chat.fileName)"
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentMinSize = NSSize(width: 460, height: 380)
        w.center()
        window = w
        return w
    }
}
