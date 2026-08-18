<img src="notepad-aaf.png" alt="AAF" width="180">

# notepad-aaf

A lightweight, native macOS editor for the files you keep opening in a hurry —
JSON, YAML, XML, SQL, NGINX configs and plain text. Tabs, syntax highlighting,
live validation, one-key formatting, a diff view, optional Vim key bindings, and
an "Ask AI" side panel.

Pure Swift + SwiftUI/AppKit. No third-party dependencies.

---

## Features

- **Tabs with session restore** — reopen where you left off, including unsaved
  scratch buffers. Double-click the empty space in the tab bar for a new tab;
  when the tabs outgrow the window the strip scrolls, with arrows at each end
  and ⌘⇧] / ⌘⇧[ to step through them.
- **Syntax highlighting** that only re-colors the *visible* region, so multi-MB
  files stay responsive.
- **Live validation** with the error's line and column, debounced while typing.
- **Formatting** per language (see the table below), on ⇧⌘L or the toolbar's
  split Format button.
- **Find & Replace** with literal or regex search, case sensitivity, and a match
  counter.
- **Compare with the tab on the right** (⇧⌘D) — a side-by-side line diff in its
  own window.
- **Vim mode** (⌃⌥V) — normal / insert / visual, operators with motions and text
  objects, registers, `/` search, `:w` `:q` `:s///`, and dot-repeat.
- **Ask AI** (⇧⌘A) — ask about the open file via Anthropic or any
  OpenAI-compatible endpoint; insert a reply at the cursor.
- **URL encode / decode** over the selection or the whole document.
- **Auto-save** (off by default) for tabs that already have a file on disk.

## Language support

| Mode | Formatting | Validation |
|---|---|---|
| **JSON** | pretty print (sorted keys), minify | parse errors with line/column |
| **YAML** | safe re-indent — trailing whitespace only, never restructures | tabs, odd indentation, indent jumps, missing keys |
| **XML** | pretty print | well-formedness with line/column |
| **SQL** | clause-per-line format, or collapse to a single line | unterminated strings/comments, unbalanced parens |
| **NGINX** | one directive per line, blocks indented, comments and blank lines preserved | unbalanced braces, missing `;`, unterminated quotes |
| **Plain text** | — | always valid |

The mode comes from the file extension and can be overridden any time from the
picker in the status bar. Formatting a plain-text buffer sniffs the content
first, so pasted JSON, XML, SQL or an nginx config is recognised and switched to
the right mode automatically.

Formatters only ever change whitespace (and keyword case, for SQL). Regexes,
string literals, variables and comments are re-emitted exactly as written.

## Requirements

- macOS 13 (Ventura) or later
- Swift 5.9+ toolchain (Xcode 15 or the standalone toolchain) to build

## Build and run

```bash
git clone https://github.com/aafb5cs/notepad-aaf.git
cd notepad-aaf
swift run                 # debug build, launches the app
```

```
cp -R notepad-aaf.app /Applications/
./build-app.sh && cp -R notepad-aaf.app /Applications
```

To produce a double-clickable `notepad-aaf.app` (universal arm64 + x86_64,
ad-hoc signed for this Mac):

```bash
./build-app.sh
```

Use `UNIVERSAL=0 ./build-app.sh` for a faster arm64-only build while developing.
Sending the app to another Mac needs signing and notarization — see
[DISTRIBUTING.md](DISTRIBUTING.md).

## Tests

The non-UI services ship with a headless smoke test covering the validators,
formatters, diff engine, session persistence, highlighter and the Vim engine:

```bash
swift build && .build/debug/notepad-aaf --selftest
```

It prints one line per check and exits non-zero on failure.

## Keyboard shortcuts

| | |
|---|---|
| ⌘N / ⌘O / ⌘S / ⌘W | New / Open / Save / Close tab |
| ⌘⇧] / ⌘⇧[ | Next / previous tab (wraps around) |
| ⌘F | Find & Replace |
| ⇧⌘L | Format document |
| ⇧⌘U / ⌃⌘U | URL decode / encode |
| ⇧⌘D | Compare with the tab on the right |
| ⇧⌘A | Ask AI |
| ⌃⌥V | Toggle Vim mode |
| ⌘, | Settings |

## Settings

Theme, session restore, auto-save interval, validation debounce, Vim mode, and
the AI provider (Anthropic or OpenAI-compatible: API key, model, base URL —
blank fields fall back to that provider's defaults).

> The API key is stored in this app's `UserDefaults` in plain text.

## Layout

```
Sources/notepad-aaf/
  Models/       LanguageMode, EditorDocument, ValidationStatus, LLMConfig, VimTypes
  Services/     Formatters, Validators, SyntaxHighlighter, SQLFormatter,
                NginxFormatter, DiffEngine, VimEngine, SessionStore, LLMService
  ViewModels/   EditorWorkspace (app state), AskAIChat
  Views/        ContentView, EditorTextView, EditorToolbar, TabStripView,
                StatusBarView, FindReplacePanel, DiffView, AskAIView, SettingsView
  SelfTest.swift
```

Adding a language means touching `LanguageMode`, `Formatters`, `Validators`,
`SyntaxHighlighter`, and the small `switch` in `EditorToolbar` / `TabStripView` —
`NginxFormatter.swift` and its `SelfTest` block are a complete worked example.

## License

[MIT](LICENSE) © 2026 Saif.

The AAF logo and app icon (`Resources/aaf-logo.png`, `Resources/AppIcon.icns`,
`notepad-aaf.png`) are branding, not code, and are not covered by the MIT grant.
