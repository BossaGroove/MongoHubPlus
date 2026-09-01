import Foundation

/// An error produced while parsing or serializing Extended JSON.
public struct EJSONError: Error, CustomStringConvertible, Equatable, Sendable {
    /// UTF-8 byte offset into the input where the error was detected (parse errors only).
    public let offset: Int?
    public let message: String

    public init(_ message: String, offset: Int? = nil) {
        self.message = message
        self.offset = offset
    }

    public var description: String {
        if let offset { return "\(message) (at offset \(offset))" }
        return message
    }
}
