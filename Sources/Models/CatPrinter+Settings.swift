import Foundation

public extension CatPrinter {
    struct Settings {
        public let services: Set<String>
        public let charateristic: String
        public let printerName: Set<String>
        public let printerWidth: Int
        public let useRunLengthEncoding: Bool
        
        public init(
            services: Set<String>,
            charateristic: String,
            printerName: Set<String>,
            printerWidth: Int,
            useRunLengthEncoding: Bool = false
        ) {
            self.services = services
            self.charateristic = charateristic
            self.printerName = printerName
            self.printerWidth = printerWidth
            self.useRunLengthEncoding = useRunLengthEncoding
        }
    }
}

public extension CatPrinter.Settings {
    static var `default`: Self {
        .init(
            services: ["AE30", "AF30"],
            charateristic: "AE01",
            printerName: [],
            printerWidth: 384,
            useRunLengthEncoding: false
        )
    }
}

