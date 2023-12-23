
public extension CatPrinter {
    struct ImageProcessingOption: OptionSet {
        public let rawValue: Int
        
        public static let addWhiteBackground = ImageProcessingOption(rawValue: 1 << 0)
        public static let convertToGrayscale = ImageProcessingOption(rawValue: 1 << 1)
        public static let floydSteinbergDithering = ImageProcessingOption(rawValue: 1 << 2)
        
        public static let all: ImageProcessingOption = [.addWhiteBackground, .convertToGrayscale, .floydSteinbergDithering]
        
        public init(rawValue: Int) {
            self.rawValue = rawValue
        }
    }
}
