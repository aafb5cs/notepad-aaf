import SwiftUI

/// VS Code-style tab strip: flat, flush tabs with a colored file-type icon, an
/// accent bar on the active tab, and a dirty-dot that turns into a close button
/// on hover.
struct TabStripView: View {
    @EnvironmentObject private var workspace: EditorWorkspace

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(workspace.documents) { doc in
                    TabItemView(document: doc,
                                isSelected: workspace.selectedDocumentID == doc.id,
                                onSelect: { workspace.selectedDocumentID = doc.id },
                                onClose: { workspace.closeDocument(doc) })
                    Divider().frame(height: 22)
                }
            }
        }
        .frame(height: 36)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

private struct TabItemView: View {
    @ObservedObject var document: EditorDocument
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false
    @State private var isCloseHovered = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: document.effectiveLanguage.symbolName)
                .font(.system(size: 12))
                .foregroundStyle(iconColor)

            Text(document.displayName)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .lineLimit(1)

            trailingControl
                .frame(width: 16, height: 16)
        }
        .padding(.horizontal, 11)
        .frame(height: 36)
        .background(isSelected ? Color(NSColor.textBackgroundColor) : Color.clear)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(isSelected ? Color.accentColor : Color.clear)
                .frame(height: 2)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
        .help(document.fileURL?.path ?? document.displayName)
    }

    @ViewBuilder
    private var trailingControl: some View {
        if isHovered || isSelected {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(isCloseHovered ? Color.primary : Color.secondary)
                    .frame(width: 16, height: 16)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isCloseHovered ? Color.secondary.opacity(0.25) : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .onHover { isCloseHovered = $0 }
        } else if document.isDirty {
            Circle()
                .fill(Color.secondary)
                .frame(width: 8, height: 8)
        } else {
            Color.clear
        }
    }

    private var iconColor: Color {
        switch document.effectiveLanguage {
        case .json: return .orange
        case .yaml: return .purple
        case .xml: return .blue
        case .sql: return .teal
        case .plainText: return .secondary
        }
    }
}
