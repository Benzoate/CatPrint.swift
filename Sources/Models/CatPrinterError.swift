import Foundation

public enum CatPrinterError: Error {
    case noSuchPrinterConnected
    case bluetoothNotPoweredOn
    case printerDisconnected
}
