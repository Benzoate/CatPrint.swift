import Foundation

public enum CatPrinterError: Error, Sendable {
    case noSuchPrinterConnected
    case bluetoothNotPoweredOn
    case printerDisconnected
}
