import AppKit
import Foundation

enum LanguageMode: String, CaseIterable, Codable, Identifiable {
    case json
    case yaml
    case xml
    case sql
    case nginx
    case plainText

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .json: return "JSON"
        case .yaml: return "YAML"
        case .xml: return "XML"
        case .sql: return "SQL"
        case .nginx: return "NGINX"
        case .plainText: return "Plain text"
        }
    }

    var symbolName: String {
        switch self {
        case .json: return "curlybraces"
        case .yaml: return "list.bullet.rectangle.portrait"
        case .xml: return "chevron.left.forwardslash.chevron.right"
        case .sql: return "cylinder.split.1x2"
        case .nginx: return "server.rack"
        case .plainText: return "doc.plaintext"
        }
    }

    static func inferred(from url: URL?) -> LanguageMode {
        guard let url else { return .plainText }
        let name = url.lastPathComponent.lowercased()
        // `sites-available/example.com` and friends carry no useful extension,
        // so the nginx-ish filename is the only signal available.
        if name.hasPrefix("nginx.") || name == "nginx" { return .nginx }

        switch url.pathExtension.lowercased() {
        case "json": return .json
        case "yaml", "yml": return .yaml
        case "xml", "xsd", "svg", "plist": return .xml
        case "sql": return .sql
        case "conf", "nginx", "vhost": return .nginx
        default: return .plainText
        }
    }
}
