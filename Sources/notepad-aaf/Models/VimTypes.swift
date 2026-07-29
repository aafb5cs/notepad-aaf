import Foundation

/// Editing mode of the Vim emulation. `visualBlock` is deliberately absent —
/// see `VimEngine` for the list of supported commands.
enum VimMode: Equatable {
    case normal
    case insert
    case visual
    case visualLine

    var label: String {
        switch self {
        case .normal: return "NORMAL"
        case .insert: return "INSERT"
        case .visual: return "VISUAL"
        case .visualLine: return "V-LINE"
        }
    }

    var isVisual: Bool { self == .visual || self == .visualLine }
}

/// One keystroke as the engine sees it. Modifiers other than Control are
/// resolved by the view layer before this is built (Command-shortcuts never
/// reach the engine, Shift is already folded into `char`).
struct VimKey: Equatable {
    let char: Character
    let control: Bool

    init(_ char: Character, control: Bool = false) {
        self.char = char
        self.control = control
    }

    static let escape = VimKey("\u{1b}")
    static let enter = VimKey("\r")
    static let backspace = VimKey("\u{8}")

    /// Esc, Ctrl-[ and Ctrl-C all cancel, as in Vim.
    var isEscape: Bool {
        if control { return char == "[" || char == "c" }
        return char == "\u{1b}"
    }

    var isEnter: Bool { char == "\r" || char == "\n" }
    var isBackspace: Bool { char == "\u{8}" || char == "\u{7f}" }
}

/// Everything the status bar needs to render. Kept as one `Equatable` value so
/// publishing it doesn't churn SwiftUI on unrelated keystrokes.
struct VimStatus: Equatable {
    var enabled: Bool = false
    var mode: VimMode = .normal
    /// Partially typed command, shown right-aligned like Vim's `showcmd`.
    var pending: String = ""
    /// Result/error text from the last `:` command.
    var message: String = ""
    /// Contents of the `:` / `/` / `?` line while it's being typed.
    var commandLine: String? = nil
}

/// `:` commands the engine can't carry out itself — they belong to the
/// workspace (saving, closing tabs).
enum VimFileCommand: Equatable {
    case write
    case quit
    case writeQuit
    case forceQuit
}

/// Target line placement for `zz` / `zt` / `zb`.
enum VimScrollAlign {
    case center
    case top
    case bottom
}

/// The buffer the engine drives. Implemented by the editor's `NSTextView`
/// adapter in the app, and by a plain in-memory stub in `SelfTest`, which is
/// what makes the whole command set testable without a window.
protocol VimTextTarget: AnyObject {
    var vimString: NSString { get }
    var vimSelection: NSRange { get set }
    /// Must route through the view's undo/change machinery so `u` works and the
    /// document model sees the edit.
    func vimReplace(_ range: NSRange, with text: String)
    func vimScrollCaretVisible()
    func vimAlignCaret(_ align: VimScrollAlign)
    /// Briefly flash a range (used after a search jump).
    func vimFlash(_ range: NSRange)
    func vimUndo()
    func vimRedo()
    func vimBeep()
    /// Visible line count, used by Ctrl-D/U/F/B.
    var vimLinesPerPage: Int { get }
}
