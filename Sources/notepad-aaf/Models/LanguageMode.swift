import AppKit
import Foundation

enum LanguageMode: String, CaseIterable, Codable, Identifiable {
    case json
    case yaml
    case xml
    case sql
    case plainText

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .json: return "JSON"
        case .yaml: return "YAML"
        case .xml: return "XML"
        case .sql: return "SQL"
        case .plainText: return "Plain text"
        }
    }

    var symbolName: String {
        switch self {
        case .json: return "curlybraces"
        case .yaml: return "list.bullet.rectangle.portrait"
        case .xml: return "chevron.left.forwardslash.chevron.right"
        case .sql: return "cylinder.split.1x2"
        case .plainText: return "doc.plaintext"
        }
    }

    static func inferred(from url: URL?) -> LanguageMode {
        guard let ext = url?.pathExtension.lowercased() else { return .plainText }
        switch ext {
        case "json": return .json
        case "yaml", "yml": return .yaml
        case "xml", "xsd", "svg", "plist": return .xml
        case "sql": return .sql
        default: return .plainText
        }
    }
}
