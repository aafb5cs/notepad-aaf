import Foundation

struct ValidationStatus: Equatable {
    let isValid: Bool
    let message: String
    let line: Int?
    let column: Int?

    static let idle = ValidationStatus(isValid: true, message: "Ready", line: nil, column: nil)
    static let valid = ValidationStatus(isValid: true, message: "Valid", line: nil, column: nil)

    static func invalid(message: String, line: Int? = nil, column: Int? = nil) -> ValidationStatus {
        ValidationStatus(isValid: false, message: message, line: line, column: column)
    }
}
