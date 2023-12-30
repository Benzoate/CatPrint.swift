import Foundation
@_implementationOnly import CoreBluetooth
import Combine
import CoreGraphics
import OSLog

public actor CatPrinter {
    @Published private(set) public var availablePrinters: Set<Printer> = []
    
    let settings: Settings
    
    private let centralManager: CBCentralManager = .init()
    private let managerProxy = CentralManagerProxy()
    private let peripheralProxy = PeripheralProxy()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "CatPrinter")
    
    private var scanningPeripherals: [CBPeripheral] = []
    private var connectedPrinters: [Printer: BluetoothInfo] = [:]
    
    private var cancellables: [AnyCancellable] = []
    
    private var printQueue: [Printer: [[PrinterCommands]]] = [:]
    private var isPrinting: [Printer: Bool] = [:]
    
    @MainActor public init(
        settings: Settings = .default
    ) {
        self.settings = settings
        centralManager.delegate = managerProxy
        Task {
            await setupObservers()
        }
    }
    
    /// Will attempt to discover nearby printers, supported printers will be published in `$availablePrinters`
    public func startScan() throws {
        guard centralManager.state == .poweredOn else {
            logger.info("Can not scan for peripherals as bluetooth is not powered on")
            throw CatPrinterError.bluetoothNotPoweredOn
        }
        logger.debug("Scanning for peripherals")
        let services: [CBUUID]? = settings.services.isEmpty ? nil : settings.services.map(CBUUID.init(string:))
        centralManager.scanForPeripherals(withServices: services)
    }
    
    /// Attempts to prints the image on the
    /// - Parameters:
    ///   - image: The image to print, it will be downscaled and coverted to grayscale no matter what, and processed as defined by `imageProcessing`
    ///   - printer: The printer to print with
    ///   - imageProcessing: The steps to take to prepare the image for printing
    /// - Throws:
    ///   - `CatPrinterError`
    public func printImage(
        _ image: CGImage,
        printer: Printer,
        imageProcessing: ImageProcessingOption = .all
    ) async throws {
        guard let bluetoothInfo = connectedPrinters[printer] else {
            logger.error("Attempted to print to a printer that is not connected \(printer.name)<\(printer.uuid)>")
            throw CatPrinterError.noSuchPrinterConnected
        }

        let setupCommands: [PrinterCommands] = [
            .getDevState,
            .setQuality200DPI,
            .latticeStart,
            .setEnergy(255)
        ]
        let imageCommands: [PrinterCommands] = PrinterCommands.printImageCommands(
            processImage(image: image, options: imageProcessing),
            printerWidth: settings.printerWidth,
            useRunLengthEncoding: settings.useRunLengthEncoding
        )
        let endCommands: [PrinterCommands] = [
            .feedPaper(25),
            .setPaper,
            .latticeEnd,
            .getDevState
         ]
        
        logger.debug("Image processed into \(imageCommands.count) print commands")
        guard isPrinting[printer] != true else {
            if printQueue[printer] == nil { printQueue[printer] = [] }
            printQueue[printer]?.append(setupCommands + imageCommands + endCommands)
            return
        }
        isPrinting[printer] = true
        await executeCommands(
            setupCommands + imageCommands + endCommands,
            bluetoothInfo: bluetoothInfo
        )
        while printQueue[printer]?.isEmpty == false {
            guard let commands = printQueue[printer]?.removeFirst() else { continue }
            await executeCommands(commands, bluetoothInfo: bluetoothInfo)
        }
        isPrinting[printer] = false
    }
    
    private func executeCommands(_ commands: [PrinterCommands], bluetoothInfo: BluetoothInfo) async {
        
        var commandData = Data(
            commands
            .map(\.commandData)
            .reduce(into: [UInt8](), +=)
        )
        
        logger.debug("Sending \(commandData.count / 1024)kb")
        let segmentSize = bluetoothInfo.peripheral.maximumWriteValueLength(for: .withoutResponse) - 5
        logger.debug("Segment size: \(segmentSize)")

        var packets: [Data] = []
        packets.reserveCapacity(commandData.count / segmentSize)
        while commandData.count > 0 {
            let segment = commandData.prefix(segmentSize)
            packets.append(segment)
            commandData = commandData.dropFirst(segment.count)
        }
        logger.debug("Data split into \(packets.count) packets")
        
        for (offset, data) in packets.enumerated() {
            bluetoothInfo.peripheral.writeValue(data, for: bluetoothInfo.characteristic, type: .withoutResponse)
            logger.debug("Sent packet \(offset), waiting 50ms")
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
    
    func processImage(
        image sourceImage: CGImage,
        options: ImageProcessingOption
    ) -> PrinterImageData {
        var image = sourceImage
        logger.debug("Processing image [width:\(sourceImage.width), height: \(sourceImage.height)]")
        if options.contains(.addWhiteBackground) {
            image = image.addWhiteBackground()
            logger.debug("Added white background to image")
        }

        if options.contains(.convertToGrayscale) {
            image = image.toGrayscale()
            logger.debug("Converted image to grayscale")
        }

        let targetSize = CGSize(
            width: settings.printerWidth,
            height: Int(Double(image.height) * Double(settings.printerWidth) / Double(image.width))
        )

        var result: PrinterImageData = .init(width: Int(targetSize.width), height: Int(targetSize.height))
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let context = CGContext(data: &result.data,
                                width: result.width,
                                height: result.height,
                                bitsPerComponent: 8,
                                bytesPerRow: result.width,
                                space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)
        context?.draw(
            image,
            in: CGRect(origin: .zero, size: targetSize)
        )
        
        if options.contains(.floydSteinbergDithering) {
            applyFloydSteinbergDithering(
                pixelData: &result.data,
                width: Int(targetSize.width),
                height: Int(targetSize.height)
            )
        }

        return result
    }

    private func applyFloydSteinbergDithering(
        pixelData: inout [UInt8],
        width: Int,
        height: Int
    ) {
        logger.debug("Applying Floyd-Steinberg dithering")
        func adjustPixel(y: Int, x: Int, delta: Int) {
            guard 0..<height ~= y, 0..<width ~= x else {
                return
            }
            let index = y * width + x
            pixelData[index] = UInt8(min(255, max(0, Int(pixelData[index]) + delta)))
        }
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                let newVal: UInt8 = if pixelData[index] > 127 { 255 } else { 0 }
                let err: Int = Int(pixelData[index]) - Int(newVal)
                pixelData[index] = newVal
                adjustPixel(y: y, x: x + 1, delta: err * 7/16)
                adjustPixel(y: y + 1, x: x - 1, delta: err * 3/16)
                adjustPixel(y: y + 1, x: x, delta: err * 5/16)
                adjustPixel(y: y + 1, x: x + 1, delta: err * 1/16)
            }
        }
    }
    
    
    private func connectToPeripheral(_ peripheral: CBPeripheral) {
        guard scanningPeripherals.contains(where: { $0.identifier == peripheral.identifier }) == false else {
            logger.info("Discovered peripheral but already connecting \(peripheral.name ?? "")<\(peripheral.identifier)>")
            return
        }
        logger.debug("Connecting to peripheral \(peripheral.name ?? "")<\(peripheral.identifier)>")
        peripheral.delegate = peripheralProxy
        centralManager.connect(peripheral)
        scanningPeripherals.append(peripheral)
    }
    
    private func onPeripheralDisconnected(_ peripheral: CBPeripheral) {
        logger.debug("Disconnected from peripheral \(peripheral.name ?? "")<\(peripheral.identifier)>")
        scanningPeripherals.removeAll(where: { $0.identifier == peripheral.identifier })

        availablePrinters
            .first(where: { $0.uuid == peripheral.identifier })
            .flatMap { _ = availablePrinters.remove($0) }
    }
    
    private func registerMatchedCharacteristic(
        peripheral: CBPeripheral,
        service: CBService,
        characteristic: CBCharacteristic
    ) {
        logger.debug("Connected to printer \(peripheral.name ?? "")<\(peripheral.identifier)>")
        let printer = Printer(uuid: peripheral.identifier, name: peripheral.name ?? "Printer")
        connectedPrinters[printer] = .init(peripheral: peripheral, service: service, characteristic: characteristic)
        scanningPeripherals.removeAll(where: { $0.identifier.uuidString == peripheral.identifier.uuidString })
        availablePrinters.insert(printer)
    }
    
    private func onServicesDiscovered(_ peripheral: CBPeripheral) {
        guard let services = peripheral.services else {
            logger.warning("Discovered services, but services array is nil")
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }
        let matchingServices = services
            .filter { settings.services.contains($0.uuid.uuidString) }

        guard matchingServices.isEmpty == false else {
            logger.warning("Discovered services, but none of them match")
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }
        
        for service in matchingServices {
            logger.debug("Searching for characteristics in service \(service.uuid) on peripheral \(peripheral.name ?? "")<\(peripheral.identifier)>")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }
    
    private func setupObservers() {
        managerProxy.peripheralDiscovered
            .map(\.peripheral)
            .filter { [settings] peripheral in
                settings.printerName.isEmpty || settings.printerName.contains(peripheral.name ?? "")
            }
            .sink { [weak self] peripheral in
                Task { [weak self] in
                    await self?.connectToPeripheral(peripheral)
                }
            }
            .store(in: &cancellables)
        
        managerProxy.peripheralConnected
            .sink { peripheral in
                peripheral.discoverServices(nil)
            }
            .store(in: &cancellables)
        
        managerProxy.peripheralDisconnected
            .sink { [weak self] peripheral in
                Task { [weak self] in
                    await self?.onPeripheralDisconnected(peripheral)
                }
            }
            .store(in: &cancellables)
        
        peripheralProxy.servicesDiscovered
            .sink { [weak self] peripheral in
                Task { [weak self] in
                    await self?.onServicesDiscovered(peripheral)
                }
            }
            .store(in: &cancellables)
        
        peripheralProxy.characteristicsDiscovered
            .flatMap { [charateristic = settings.charateristic] peripheral, service in
                (service.characteristics ?? [])
                    .filter { charateristic == $0.uuid.uuidString }
                    .map { (peripheral, service, $0) }
                    .publisher
            }
            .sink { [weak self] peripheral, service, characteristic in
                Task { [weak self] in
                    await self?.registerMatchedCharacteristic(
                        peripheral: peripheral,
                        service: service,
                        characteristic: characteristic
                    )
                }
            }
            .store(in: &cancellables)
    }
}

private extension CatPrinter {
    final class CentralManagerProxy: NSObject, CBCentralManagerDelegate {
        private let stateUpdateSubject: PassthroughSubject<CBManagerState, Never> = .init()
        private let peripheralDiscoveredSubject: PassthroughSubject<PeripheralDiscoveryData, Never> = .init()
        private let peripheralConnectedSubject: PassthroughSubject<CBPeripheral, Never> = .init()
        private let peripheralDisconnectedSubject: PassthroughSubject<CBPeripheral, Never> = .init()
        
        var stateUpdated: some Publisher<CBManagerState, Never> { stateUpdateSubject }
        var peripheralDiscovered: some Publisher<PeripheralDiscoveryData, Never> { peripheralDiscoveredSubject }
        var peripheralConnected: some Publisher<CBPeripheral, Never> { peripheralConnectedSubject }
        var peripheralDisconnected: some Publisher<CBPeripheral, Never> { peripheralDisconnectedSubject }
        
        func centralManagerDidUpdateState(_ central: CBCentralManager) {
            stateUpdateSubject.send(central.state)
        }
        
        func centralManager(
            _ central: CBCentralManager,
            didDiscover peripheral: CBPeripheral,
            advertisementData: [String : Any],
            rssi RSSI: NSNumber
        ) {
            peripheralDiscoveredSubject.send(
                .init(
                    peripheral: peripheral,
                    advertisementData: advertisementData,
                    rssi: RSSI
                )
            )
        }
        
        func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
            peripheralConnectedSubject.send(peripheral)
        }
        
        func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
            peripheralDisconnectedSubject.send(peripheral)
        }
        
        struct PeripheralDiscoveryData {
            let peripheral: CBPeripheral
            let advertisementData: [String : Any]
            let rssi: NSNumber
        }
    }
}

private extension CatPrinter {
    
    final class PeripheralProxy: NSObject, CBPeripheralDelegate {
        private let servicesDiscoveredSubject: PassthroughSubject<CBPeripheral, Never> = .init()
        private let characteristicsDiscoveredSubject: PassthroughSubject<(CBPeripheral, CBService), Never> = .init()
        
        var servicesDiscovered: some Publisher<CBPeripheral, Never> { servicesDiscoveredSubject }
        var characteristicsDiscovered: some Publisher<(CBPeripheral, CBService), Never> { characteristicsDiscoveredSubject }
        
        func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
            servicesDiscoveredSubject.send(peripheral)
        }
        
        func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
            characteristicsDiscoveredSubject.send((peripheral, service))
        }

        func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
            servicesDiscoveredSubject.send(peripheral)
        }
    }
}
