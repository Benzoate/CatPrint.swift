# CatPrint.swift

A swift library for printing to the cheap “Cat” thermoprinters that can be found on sites such as Aliexpress. I have tested this with the MX10, but I believe that these models will work with this library.

- CYLO BT PRINTER
- MXTP-100
- AZ-P2108X
- MX10 ✅ __[confirmed]__
- MX11
- BQ02
- EWTTO ET-Z049

## Installation
Add the repo to your project using SwiftPackage Manager

## Usage
You need to create an instance of `CatPrinter` and retain it for the duration of your session.

e.g.
```swift
import CatPrint

@MainActor
final class MyViewModel {
    let printer = CatPrinter(settings: .default)
}
```

You can then search for a printer with `try await printer.startScan()`. A `bluetoothNotPoweredOn` error will be raised if CoreBluetooth is not ready to scan, if you handle this error then you can try again after some time.

```swift
func searchForPrinters() async {
    do {
        try await printer.startScan()
    } catch CatPrinterError.bluetoothNotPoweredOn {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        await searchForPrinters()
    } catch { }
}
```

You can then listen for available cat printers by subscribing to `availablePrinters` and handle that in a method of your choosing. This property will automatically update as printers connect and disconnect.

```swift
await printer.$availablePrinters
    .dropFirst()
    .filter { $0.isEmpty == false }
    .map { State.foundPrinters(Array($0)) }
    .receive(on: RunLoop.main)
    .assign(to: &$state)
```

Finally, once you have a printer you want to print to — you can print by providing a `CGImage`. The `CGImage` will automatically be re-sampled to the pixel width of the printer and converted to grayscale. There are some image processing options such as dithering available via the `imageProcessing` property. 
```swift
do {
    try await printer.printImage(
                image, // CGImage
                printer: printerInfo
              )
} catch CatPrinterError.noSuchPrinterConnected {
} catch { }
```
