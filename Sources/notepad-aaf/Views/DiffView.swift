import SwiftUI

/// Side-by-side comparison of the active file (left) and the tab to its right.
/// Added lines (only in the right file) are green, removed lines (only in the
/// left file) are red, unchanged lines are plain. Hosted in its own resizable
/// window (see `DiffWindowController`), not a fixed-size sheet.
struct DiffView: View {
    let diff: FileDiff
    let leftName: String
    let rightName: String
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 560, minHeight: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.split.2x1")
            VStack(alignment: .leading, spacing: 2) {
                Text("Compare").font(.headline)
                HStack(spacing: 6) {
                    Text(leftName).fontWeight(.medium)
                    Image(systemName: "arrow.left.arrow.right").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(rightName).fontWeight(.medium)
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }

            Spacer()

            if !diff.tooLarge {
                HStack(spacing: 10) {
                    Label("\(diff.addedCount)", systemImage: "plus")
                        .foregroundStyle(.green)
                    Label("\(diff.removedCount)", systemImage: "minus")
                        .foregroundStyle(.red)
                }
                .font(.system(size: 12, weight: .medium))
                .labelStyle(.titleAndIcon)
            }

            Button("Done") { onClose() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if diff.tooLarge {
            message("These files are too large to compare line by line (over \(DiffEngine.lineCap) lines).",
                    systemImage: "exclamationmark.triangle")
        } else if diff.isIdentical {
            message("The two files are identical.", systemImage: "checkmark.circle")
        } else {
            diffTable(diff)
        }
    }

    private func diffTable(_ diff: FileDiff) -> some View {
        ScrollView(.vertical) {
            DiffTableContent(rows: diff.rows)
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    private func message(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(text)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .background(Color(NSColor.textBackgroundColor))
    }
}

/// The rows of the diff, without a scroll container — factored out so it can be
/// rendered directly (see `DiffShot`), since `ScrollView` doesn't rasterise.
struct DiffTableContent: View {
    let rows: [DiffRow]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                HStack(alignment: .top, spacing: 0) {
                    DiffCell(number: row.leftNumber, text: row.leftText,
                             side: .left, kind: row.kind)
                    Divider()
                    DiffCell(number: row.rightNumber, text: row.rightText,
                             side: .right, kind: row.kind)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DiffCell: View {
    enum Side { case left, right }
    let number: Int?
    let text: String?
    let side: Side
    let kind: DiffKind

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(number.map(String.init) ?? "")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
                .padding(.trailing, 8)

            // Wrap long lines so each pane fills half the (resizable) window
            // instead of needing a horizontal scroll.
            Text(text ?? "")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 12)
        }
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
    }

    /// Highlight the side that actually differs: removed → tint the left cell,
    /// added → tint the right cell. Empty filler cells get a faint neutral tint.
    private var background: Color {
        switch kind {
        case .equal:
            return .clear
        case .removed:
            return side == .left ? Color.red.opacity(0.18) : Color.gray.opacity(0.08)
        case .added:
            return side == .right ? Color.green.opacity(0.18) : Color.gray.opacity(0.08)
        }
    }
}

/// Presents the diff in a standalone, user-resizable window (an `NSWindow`,
/// unlike a SwiftUI `.sheet`, which is fixed to its content size). Reuses a
/// single window so repeated comparisons don't pile up.
@MainActor
final class DiffWindowController {
    private var window: NSWindow?

    func present(diff: FileDiff, leftName: String, rightName: String) {
        let root = DiffView(diff: diff, leftName: leftName, rightName: rightName) { [weak self] in
            self?.window?.performClose(nil)
        }
        let hosting = NSHostingView(rootView: root)

        let window = self.window ?? makeWindow()
        window.title = "Compare — \(leftName) ↔ \(rightName)"
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentMinSize = NSSize(width: 560, height: 360)
        w.center()
        window = w
        return w
    }
}
