import Foundation

public extension CatPrinter {
    struct Printer: Hashable, Sendable {
        public let uuid: UUID
        public let name: String
    }
}
