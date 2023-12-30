import Foundation
import CoreGraphics

enum PrinterCommands {
    case getDevState
    case setQuality200DPI
    case getDevInfo
    case latticeStart
    case latticeEnd
    case setPaper
    case printImage
    case printText
    case feedPaper(UInt8)
    case setEnergy(UInt)
    case printByteEncodedRow([UInt8])
    case printRunLengthEncodedRow([UInt8])

    var commandData: [UInt8] {
        switch self {
        case .getDevState:
            [0x51, 0x78, 0xa3, 0x00, 0x01, 0x00, 0x00, 0x00, 0xff]
        case .setQuality200DPI:
            [0x51, 0x78, 0xa4, 0x00, 0x01, 0x00, 0x32, 0x9e, 0xff]
        case .getDevInfo:
            [0x51, 0x78, 0xa8, 0x00, 0x01, 0x00, 0x00, 0x00, 0xff]
        case .latticeStart:
            [0x51, 0x78, 0xa6, 0x00, 0x0b, 0x00, 0xaa, 0x55, 0x17, 0x38, 0x44, 0x5f, 0x5f, 0x5f, 0x44, 0x38, 0x2c, 0xa1, 0xff]
        case .latticeEnd:
            [0x51, 0x78, 0xa6, 0x00, 0x0b, 0x00, 0xaa, 0x55, 0x17, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x17, 0x11, 0xff]
        case .setPaper:
            [0x51, 0x78, 0xa1, 0x00, 0x02, 0x00, 0x30, 0x00, 0xf9, 0xff]
        case .printImage:
            [0x51, 0x78, 0xbe, 0x00, 0x01, 0x00, 0x00, 0x00, 0xff]
        case .printText:
            [0x51, 0x78, 0xbe, 0x00, 0x01, 0x00, 0x00, 0x00, 0xff]
        case let .feedPaper(amount):
            [0x51, 0x78, 0xbd, 0x00, 0x01, 0x00, amount, 0x00, 0xff]
        case let .setEnergy(energy):
            setEnergy(energy)
        case let .printByteEncodedRow(data):
            printByteEncodedRow(data)
        case let .printRunLengthEncodedRow(data):
            printRunLengthEncodedRow(data)
        }
    }
    
    private func printByteEncodedRow(_ row: [UInt8]) -> [UInt8] {
        var result: [UInt8] = [0x51, 0x78, 0xa2, 0x00, UInt8(row.count), 0x00] +
        row +
        [0x00, 0xff]
        result[result.endIndex - 2] = checksum(result, startIndex: 6, amount: row.count)
        return result
    }
    
    private func printRunLengthEncodedRow(_ row: [UInt8]) -> [UInt8] {
        var result: [UInt8] = [0x51, 0x78, 0xbf, 0x00, UInt8(row.count), 0x00] +
        row +
        [0x00, 0xff]
        result[result.endIndex - 2] = checksum(result, startIndex: 6, amount: row.count)
        return result
    }
    
    private func setEnergy(_ energy: UInt) -> [UInt8] {
        var data: [UInt8] = [
            0x51, 0x78, 0xaf, 0x00, 0x02, 0x00,
            UInt8((energy >> 8) & 0xff),
            UInt8(energy & 0xff),
            0x00, 0xff
        ]
        data[8] = checksum(data, startIndex: 6, amount: 2)
        return data
    }
    
    private func checksum(_ data: [UInt8], startIndex: Int, amount: Int) -> UInt8 {
        var b2: UInt8 = 0
        for value in data[startIndex..<(startIndex + amount)] {
            b2 = checksumTable[Int((b2 ^ value) & 0xff)]
        }
        return b2
    }
    
    private var checksumTable: [UInt8] {
        [
            0x00, 0x07, 0x0e, 0x09, 0x1c, 0x1b, 0x12, 0x15, 0x38, 0x3f, 0x36, 0x31, 
            0x24, 0x23, 0x2a, 0x2d, 0x70, 0x77, 0x7e, 0x79, 0x6c, 0x6b, 0x62, 0x65,
            0x48, 0x4f, 0x46, 0x41, 0x54, 0x53, 0x5a, 0x5d, 0xe0, 0xe7, 0xee, 0xe9,
            0xfc, 0xfb, 0xf2, 0xf5, 0xd8, 0xdf, 0xd6, 0xd1, 0xc4, 0xc3, 0xca, 0xcd,
            0x90, 0x97, 0x9e, 0x99, 0x8c, 0x8b, 0x82, 0x85, 0xa8, 0xaf, 0xa6, 0xa1,
            0xb4, 0xb3, 0xba, 0xbd, 0xc7, 0xc0, 0xc9, 0xce, 0xdb, 0xdc, 0xd5, 0xd2,
            0xff, 0xf8, 0xf1, 0xf6, 0xe3, 0xe4, 0xed, 0xea, 0xb7, 0xb0, 0xb9, 0xbe,
            0xab, 0xac, 0xa5, 0xa2, 0x8f, 0x88, 0x81, 0x86, 0x93, 0x94, 0x9d, 0x9a,
            0x27, 0x20, 0x29, 0x2e, 0x3b, 0x3c, 0x35, 0x32, 0x1f, 0x18, 0x11, 0x16,
            0x03, 0x04, 0x0d, 0x0a, 0x57, 0x50, 0x59, 0x5e, 0x4b, 0x4c, 0x45, 0x42,
            0x6f, 0x68, 0x61, 0x66, 0x73, 0x74, 0x7d, 0x7a, 0x89, 0x8e, 0x87, 0x80,
            0x95, 0x92, 0x9b, 0x9c, 0xb1, 0xb6, 0xbf, 0xb8, 0xad, 0xaa, 0xa3, 0xa4,
            0xf9, 0xfe, 0xf7, 0xf0, 0xe5, 0xe2, 0xeb, 0xec, 0xc1, 0xc6, 0xcf, 0xc8,
            0xdd, 0xda, 0xd3, 0xd4, 0x69, 0x6e, 0x67, 0x60, 0x75, 0x72, 0x7b, 0x7c,
            0x51, 0x56, 0x5f, 0x58, 0x4d, 0x4a, 0x43, 0x44, 0x19, 0x1e, 0x17, 0x10,
            0x05, 0x02, 0x0b, 0x0c, 0x21, 0x26, 0x2f, 0x28, 0x3d, 0x3a, 0x33, 0x34,
            0x4e, 0x49, 0x40, 0x47, 0x52, 0x55, 0x5c, 0x5b, 0x76, 0x71, 0x78, 0x7f,
            0x6a, 0x6d, 0x64, 0x63, 0x3e, 0x39, 0x30, 0x37, 0x22, 0x25, 0x2c, 0x2b,
            0x06, 0x01, 0x08, 0x0f, 0x1a, 0x1d, 0x14, 0x13, 0xae, 0xa9, 0xa0, 0xa7,
            0xb2, 0xb5, 0xbc, 0xbb, 0x96, 0x91, 0x98, 0x9f, 0x8a, 0x8d, 0x84, 0x83,
            0xde, 0xd9, 0xd0, 0xd7, 0xc2, 0xc5, 0xcc, 0xcb, 0xe6, 0xe1, 0xe8, 0xef,
            0xfa, 0xfd, 0xf4, 0xf3
        ]
    }
}

extension PrinterCommands {
    static func printImageCommands(
        _ printerData: PrinterImageData,
        printerWidth: Int = 384,
        useRunLengthEncoding: Bool
    ) -> [Self] {
        (0..<printerData.height)
            .map {
                Self.rowCommand(
                    printerData,
                    row: $0,
                    printerWidth: printerWidth,
                    useRunLengthEncoding: useRunLengthEncoding
                )
            }
    }
    
    private static func rowCommand(
        _ printerData: PrinterImageData,
        row: Int,
        printerWidth: Int,
        useRunLengthEncoding: Bool
    ) -> PrinterCommands {
        let dataSlice = printerData.data[(row * printerData.width)..<((row + 1) * printerData.width)]

        guard useRunLengthEncoding else {
            return .printByteEncodedRow(
                byteEncode(dataSlice, printerWidth: printerWidth)
            )
        }
        

        let runLengthEncoded = runLengthEncode(
            dataSlice,
            printerWidth: printerWidth
        )
        
        if runLengthEncoded.count > printerWidth / 8 {
            return .printByteEncodedRow(
                byteEncode(dataSlice, printerWidth: printerWidth)
            )
        }
        return .printRunLengthEncodedRow(runLengthEncoded)
    }
    
    private static func byteEncode(_ row: ArraySlice<UInt8>, printerWidth: Int) -> [UInt8] {
        var newData: [UInt8] = .init(repeating: 0, count: printerWidth / 8)
        for idx in 0..<newData.count {
            var value: UInt8 = 0
            for pixel in 0..<8 {
                let sliceIndex = row.startIndex + idx * 8 + pixel
                guard sliceIndex < row.endIndex else { continue }
                if row[sliceIndex] < 127 {
                    value |= 1 << pixel
                }
            }
            newData[idx] = value
        }
        return newData
    }
    
    private static func runLengthEncode(_ row: ArraySlice<UInt8>, printerWidth: Int) -> [UInt8] {
        func encodeRunLengthRepitition(repeats: Int, value: UInt8) -> [UInt8] {
            var repeats = repeats
            var result: [UInt8] = []
            while repeats > 0x7f {
                result.append(0x7f | (value << 7))
                repeats = repeats - 0x7f
            }
            if repeats > 0 {
                result.append(UInt8(repeats) | (value << 7))
            }
            return result
        }
        var newData: [UInt8] = .init()
        var count: Int = 0
        var lastValue: UInt8 = 0xff
        for grayValue in row {
            let value: UInt8 = grayValue < 127 ? 1 : 0
            if value == lastValue {
                count = count + 1
            } else {
                newData.append(contentsOf: encodeRunLengthRepitition(repeats: count, value: lastValue))
                count = 1
            }
            lastValue = value
        }
        if count > 0 {
            newData.append(contentsOf: encodeRunLengthRepitition(repeats: count, value: lastValue))
        }
        
        return newData
    }
}

