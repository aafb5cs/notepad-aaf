import SwiftUI

/// VS Code-style tab strip: flat, flush tabs with a colored file-type icon, an
/// accent bar on the active tab, and a dirty-dot that turns into a close button
/// on hover.
///
/// The strip scrolls horizontally once the tabs outgrow the window and follows
/// the selection, so a newly opened tab is always brought into view. The empty
/// space after the last tab is a double-click target for a new tab.
struct TabStripView: View {
    @EnvironmentObject private var workspace: EditorWorkspace

    /// Width of the tabs alone (the trailing filler is excluded, since it
    /// stretches), and where each tab currently sits relative to the visible
    /// strip. Both are re-measured on every layout pass, so the chevrons act on
    /// the strip's real position rather than on a running count of their own
    /// clicks — which a trackpad scroll would silently invalidate.
    @State private var tabsWidth: CGFloat = 0
    @State private var tabFrames: [UUID: CGRect] = [:]

    private static let stripHeight: CGFloat = 36
    /// Width of an overflow chevron, and so of the gutter the tabs keep clear
    /// at either end to stay out from under it.
    private static let chevronWidth: CGFloat = 26
    /// Width the filler keeps once it has nothing left to fill, so the
    /// double-click target survives an overflowing strip — and, being wider
    /// than a chevron, it doubles as the gutter at the trailing end.
    private static let fillerMinWidth: CGFloat = 28
    private static let coordinateSpace = "tab-strip"

    var body: some View {
        GeometryReader { geometry in
            let viewport = geometry.size.width
            ScrollViewReader { proxy in
                scrollingTabs(viewport: viewport)
                    .overlay(alignment: .leading) {
                        if isOverflowing(viewport) {
                            let target = clippedAtLeading()
                            chevron("chevron.left", "Scroll tabs left", enabled: target != nil) {
                                scroll(to: target, edge: .leading, viewport: viewport, proxy)
                            }
                        }
                    }
                    .overlay(alignment: .trailing) {
                        if isOverflowing(viewport) {
                            let target = clippedAtTrailing(viewport)
                            chevron("chevron.right", "Scroll tabs right", enabled: target != nil) {
                                scroll(to: target, edge: .trailing, viewport: viewport, proxy)
                            }
                        }
                    }
                    .onChange(of: workspace.selectedDocumentID) { id in
                        reveal(id, viewport: viewport, proxy)
                    }
                    .onAppear {
                        if let id = workspace.selectedDocumentID { proxy.scrollTo(id) }
                    }
            }
        }
        .frame(height: Self.stripHeight)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func scrollingTabs(viewport: CGFloat) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(workspace.documents) { doc in
                        TabItemView(document: doc,
                                    isSelected: workspace.selectedDocumentID == doc.id,
                                    onSelect: { workspace.selectedDocumentID = doc.id },
                                    onClose: { workspace.closeDocument(doc) })
                            .id(doc.id)
                            .background(measureFrame(doc))
                        Divider().frame(height: 22)
                    }
                }
                .background(measure(TabsWidthKey.self) { $0.size.width })
                emptyArea
            }
            // Gutter for the leading chevron, so the first tab isn't stuck
            // underneath it at rest. The trailing end already has `emptyArea`.
            .padding(.leading, isOverflowing(viewport) ? Self.chevronWidth : 0)
            // Force the row to span the strip even when the tabs don't, so
            // `emptyArea` covers the rest of the bar. Once they overflow, the
            // row keeps its natural (wider) width.
            .frame(minWidth: viewport, alignment: .leading)
        }
        .coordinateSpace(name: Self.coordinateSpace)
        .onPreferenceChange(TabsWidthKey.self) { tabsWidth = $0 }
        .onPreferenceChange(TabFramesKey.self) { tabFrames = $0 }
    }

    /// Filler after the last tab: takes the leftover width of the strip, and
    /// opens a new tab on a double-click.
    private var emptyArea: some View {
        Color.clear
            .frame(minWidth: Self.fillerMinWidth, maxWidth: .infinity)
            .frame(height: Self.stripHeight)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { workspace.newDocument() }
            .help("Double-click for a new tab")
    }

    /// An end-of-strip arrow, laid over the tabs rather than beside them —
    /// taking width from the viewport would change the overflow answer that
    /// decides whether these are shown at all.
    private func chevron(_ symbol: String, _ label: String,
                         enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(enabled ? Color.secondary : Color.secondary.opacity(0.3))
                .frame(width: Self.chevronWidth, height: Self.stripHeight)
                .background(Color(NSColor.windowBackgroundColor))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
    }

    private func isOverflowing(_ viewport: CGFloat) -> Bool {
        tabsWidth > viewport + 1
    }

    /// The tabs each chevron would bring into view: the last one clipped by the
    /// leading edge, and the first one clipped by the trailing edge. Deriving
    /// them from the measured frames is what keeps the arrows honest — they
    /// step from where the strip actually is, and go inert exactly when there
    /// is nothing left to reveal on that side.
    private func clippedAtLeading() -> EditorDocument? {
        index(TabStripGeometry.clippedAtLeading(frames: measuredFrames(),
                                                gutter: Self.chevronWidth))
    }

    private func clippedAtTrailing(_ viewport: CGFloat) -> EditorDocument? {
        index(TabStripGeometry.clippedAtTrailing(frames: measuredFrames(),
                                                 viewport: viewport,
                                                 gutter: Self.chevronWidth))
    }

    private func measuredFrames() -> [CGRect?] {
        workspace.documents.map { tabFrames[$0.id] }
    }

    private func index(_ position: Int?) -> EditorDocument? {
        position.map { workspace.documents[$0] }
    }

    /// Bring `document` flush against one end of the strip, just clear of the
    /// chevron sitting there.
    private func scroll(to document: EditorDocument?, edge: HorizontalEdge,
                        viewport: CGFloat, _ proxy: ScrollViewProxy) {
        guard let document, let width = tabFrames[document.id]?.width else { return }
        let fraction = TabStripGeometry.anchorFraction(tabWidth: width, viewport: viewport,
                                                       gutter: Self.chevronWidth, edge: edge)
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(document.id, anchor: UnitPoint(x: fraction, y: 0.5))
        }
    }

    /// Follow the selection, but only when the tab isn't already sitting in the
    /// clear — so clicking a visible tab doesn't shuffle the strip under the
    /// pointer.
    private func reveal(_ id: UUID?, viewport: CGFloat, _ proxy: ScrollViewProxy) {
        guard let id, let document = workspace.documents.first(where: { $0.id == id }) else { return }
        guard let frame = tabFrames[id] else {
            // A freshly opened tab has no measured frame yet; the plain anchor
            // still brings it into view once it lands.
            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
            return
        }
        guard isOverflowing(viewport) else { return }
        if frame.maxX > viewport - Self.chevronWidth + 1 {
            scroll(to: document, edge: .trailing, viewport: viewport, proxy)
        } else if frame.minX < Self.chevronWidth - 1 {
            scroll(to: document, edge: .leading, viewport: viewport, proxy)
        }
    }

    private func measure<K: PreferenceKey>(_ key: K.Type,
                                           _ value: @escaping (GeometryProxy) -> CGFloat) -> some View
    where K.Value == CGFloat {
        GeometryReader { geometry in
            Color.clear.preference(key: key, value: value(geometry))
        }
    }

    /// Each tab's frame in the strip's own (non-scrolling) space, so a negative
    /// `minX` means "scrolled off the left".
    private func measureFrame(_ document: EditorDocument) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: TabFramesKey.self,
                value: [document.id: geometry.frame(in: .named(Self.coordinateSpace))])
        }
    }
}

/// The overflow-arrow arithmetic, kept clear of SwiftUI so the self-test can
/// exercise it: which tab an arrow reveals, and where to park it.
///
/// Every frame here is in the strip's own space — the visible window onto the
/// tabs — so a tab is off to the left at `minX < 0` and off to the right at
/// `maxX > viewport`. `gutter` is the width an arrow covers at either end;
/// a tab underneath one counts as clipped, since it can't be read or clicked.
enum TabStripGeometry {
    /// Index of the last tab the leading arrow still has something to reveal
    /// of, or `nil` when the strip is already at its start.
    static func clippedAtLeading(frames: [CGRect?], gutter: CGFloat) -> Int? {
        frames.lastIndex(matching: { $0.minX < gutter - 1 })
    }

    /// Index of the first tab the trailing arrow still has something to reveal
    /// of, or `nil` when the strip is already at its end.
    static func clippedAtTrailing(frames: [CGRect?], viewport: CGFloat, gutter: CGFloat) -> Int? {
        frames.firstIndex(matching: { $0.maxX > viewport - gutter + 1 })
    }

    /// The anchor that leaves a gutter-wide margin between a tab and the end of
    /// the strip it is being scrolled to.
    ///
    /// `ScrollViewProxy` offers no scroll-by-offset form, only an anchor — but
    /// an anchor lines the same relative point up in both the tab and the
    /// strip, so a tab of width `w` anchored at `t` lands with its leading edge
    /// at `t * (viewport - w)`. Setting that to the gutter (or its mirror for
    /// the trailing edge) and solving for `t` gives the fractions below. They
    /// stay inside 0...1 for any tab narrower than the strip less its gutter;
    /// a wider one clamps to the plain edge anchor.
    static func anchorFraction(tabWidth: CGFloat, viewport: CGFloat,
                               gutter: CGFloat, edge: HorizontalEdge) -> CGFloat {
        let slack = viewport - tabWidth
        guard slack > 1 else { return edge == .leading ? 0 : 1 }
        switch edge {
        case .leading: return min(gutter / slack, 1)
        case .trailing: return max((slack - gutter) / slack, 0)
        }
    }
}

private extension Array where Element == CGRect? {
    /// Unmeasured tabs (a frame that hasn't landed yet) never count as clipped;
    /// guessing would make an arrow live before its target has a position.
    func firstIndex(matching predicate: (CGRect) -> Bool) -> Int? {
        indices.first { self[$0].map(predicate) ?? false }
    }

    func lastIndex(matching predicate: (CGRect) -> Bool) -> Int? {
        indices.last { self[$0].map(predicate) ?? false }
    }
}

private struct TabsWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct TabFramesKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, latest in latest }
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
        case .nginx: return .green
        case .plainText: return .secondary
        }
    }
}
