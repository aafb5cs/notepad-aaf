import AppKit

/// The window theme the user picked. Applied by forcing `NSApp.appearance`,
/// which covers every window (SwiftUI scene, the AppKit diff / Ask AI windows,
/// and the embedded editor) at once. `.system` follows macOS.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// `nil` means "don't override" — follow the system setting.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}
