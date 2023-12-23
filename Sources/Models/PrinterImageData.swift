import Foundation

struct PrinterImageData {
    var data: [UInt8]
    var width: Int
    var height: Int
    
    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        data = [UInt8](repeating: 0, count: width * height)
    }
}
