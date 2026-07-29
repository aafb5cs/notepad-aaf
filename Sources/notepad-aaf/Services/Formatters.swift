import Foundation

enum FormatterError: LocalizedError {
    case unsupportedMode
    case yamlUnsafeRewrite

    var errorDescription: String? {
        switch self {
        case .unsupportedMode:
            return "Formatting is not available for this language mode."
        case .yamlUnsafeRewrite:
            return "YAML rewrite may be structurally unsafe. Confirm before applying."
        }
    }
}

struct Formatters {
    func format(_ text: String, mode: LanguageMode, option: FormatOption) throws -> String {
        switch mode {
        case .json:
            return try formatJSON(text: text, option: option)
        case .xml:
            return try formatXML(text: text)
        case .yaml:
            return try formatYAMLSafeReindent(text: text)
        case .sql:
            return formatSQL(text: text, option: option)
        case .plainText:
            throw FormatterError.unsupportedMode
        }
    }

    private func formatSQL(text: String, option: FormatOption) -> String {
        switch option {
        case .sqlCompact: return SQLFormatter.compact(text)
        default: return SQLFormatter.pretty(text)
        }
    }

    private func formatJSON(text: String, option: FormatOption) throws -> String {
        guard let data = text.data(using: .utf8) else { return text }
        let object = try JSONSerialization.jsonObject(with: data)
        switch option {
        case .jsonMinify:
            let minData = try JSONSerialization.data(withJSONObject: object, options: [])
            return String(decoding: minData, as: UTF8.self)
        default:
            let prettyData = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            return String(decoding: prettyData, as: UTF8.self)
        }
    }

    private func formatXML(text: String) throws -> String {
        let document = try XMLDocument(xmlString: text, options: [])
        document.characterEncoding = "utf-8"
        return document.xmlString(options: [.nodePrettyPrint])
    }

    private func formatYAMLSafeReindent(text: String) throws -> String {
        if text.contains("\t") {
            throw FormatterError.yamlUnsafeRewrite
        }
        let lines = text.components(separatedBy: .newlines)
        let normalized = lines.map { line in
            line.replacingOccurrences(of: " +$", with: "", options: .regularExpression)
        }
        return normalized.joined(separator: "\n")
    }
}

enum FormatOption: String, CaseIterable, Identifiable {
    case auto
    case jsonPretty
    case jsonMinify
    case xmlPretty
    case yamlSafeReindent
    case sqlPretty
    case sqlCompact

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Format"
        case .jsonPretty: return "JSON: Pretty print"
        case .jsonMinify: return "JSON: Minify"
        case .xmlPretty: return "XML: Pretty print"
        case .yamlSafeReindent: return "YAML: Safe re-indent"
        case .sqlPretty: return "SQL: Format"
        case .sqlCompact: return "SQL: Single line"
        }
    }
}
