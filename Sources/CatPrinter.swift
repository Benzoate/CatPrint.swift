import Foundation
@_implementationOnly import CoreBluetooth
import CoreGraphics
import OSLog

public actor CatPrinter {
    public private(set) var availablePrinters: Set<Printer> = []

    /// Emits the current `availablePrinters` snapshot immediately, then every subsequent change.
    public var availablePrintersUpdates: AsyncStream<Set<Printer>> {
        AsyncStream { [weak self] continuation in
            let id = UUID()
            let printer = self
            continuation.onTermination = { _ in
                Task {
                    await printer?.removeAvailablePrintersContinuation(id)
                }
            }
            Task {
                guard let printer else {
                    continuation.finish()
                    return
                }
                await printer.addAvailablePrintersContinuation(id, continuation)
            }
        }
    }
    
    let settings: Settings
    
    private let centralManager: CBCentralManager = .init()
    private let managerProxy = CentralManagerProxy()
    private let peripheralProxy = PeripheralProxy()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "CatPrinter")
    
    private var scanningPeripherals: [CBPeripheral] = []
    private var connectedPrinters: [Printer: BluetoothInfo] = [:]
    private var availablePrintersContinuations: [UUID: AsyncStream<Set<Printer>>.Continuation] = [:]
    private var cancelledAvailablePrintersContinuations: Set<UUID> = []
    private var observationTasks: [Task<Void, Never>] = []
    
    private var printQueue: [Printer: [[PrinterCommands]]] = [:]
    private var isPrinting: [Printer: Bool] = [:]
    private var printGeneration: [Printer: Int] = [:]
    private var isReady = false
    private var readyContinuations: [CheckedContinuation<Void, Never>] = []
    
    @MainActor public init(
        settings: Settings = .default
    ) {
        self.settings = settings
        Task {
            await installObservers()
        }
    }

    deinit {
        observationTasks.forEach { $0.cancel() }
        readyContinuations.forEach { $0.resume() }
        for continuation in availablePrintersContinuations.values {
            continuation.finish()
        }
        managerProxy.finish()
        peripheralProxy.finish()
    }
    
    /// Will attempt to discover nearby printers. Supported printers are yielded by `availablePrintersUpdates`.
    public func startScan() async throws {
        await waitUntilReady()
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
        guard connectedPrinters[printer] != nil else {
            logger.error("Attempted to print to a printer that is not connected \(printer.name)<\(printer.uuid)>")
            throw CatPrinterError.noSuchPrinterConnected
        }

        let printerWidth = settings.printerWidth
        let useRunLengthEncoding = settings.useRunLengthEncoding
        let processedImage = await Task.detached {
            processPrinterImage(image, options: imageProcessing, printerWidth: printerWidth)
        }.value

        // Connection may have dropped while the image was processed off the actor.
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
            processedImage,
            printerWidth: printerWidth,
            useRunLengthEncoding: useRunLengthEncoding
        )
        let endCommands: [PrinterCommands] = [
            .feedPaper(25),
            .setPaper,
            .latticeEnd,
            .getDevState
         ]
        
        logger.debug("Image processed into \(imageCommands.count) print commands")
        let generation = printGeneration[printer] ?? 0
        guard isPrinting[printer] != true else {
            if printQueue[printer] == nil { printQueue[printer] = [] }
            printQueue[printer]?.append(setupCommands + imageCommands + endCommands)
            return
        }
        isPrinting[printer] = true
        defer {
            if (printGeneration[printer] ?? 0) == generation {
                isPrinting[printer] = false
            }
        }
        await executeCommands(
            setupCommands + imageCommands + endCommands,
            printer: printer,
            generation: generation,
            bluetoothInfo: bluetoothInfo
        )
        while printQueue[printer]?.isEmpty == false {
            guard isCurrentPrintSession(generation, printer: printer, bluetoothInfo: bluetoothInfo),
                  let commands = printQueue[printer]?.removeFirst() else {
                return
            }
            await executeCommands(
                commands,
                printer: printer,
                generation: generation,
                bluetoothInfo: bluetoothInfo
            )
        }
    }
    
    private func executeCommands(
        _ commands: [PrinterCommands],
        printer: Printer,
        generation: Int,
        bluetoothInfo: BluetoothInfo
    ) async {
        
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
            guard isCurrentPrintSession(generation, printer: printer, bluetoothInfo: bluetoothInfo) else {
                logger.debug("Print session ended, stopping command write")
                return
            }
            bluetoothInfo.peripheral.writeValue(data, for: bluetoothInfo.characteristic, type: .withoutResponse)
            logger.debug("Sent packet \(offset), waiting 50ms")
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func isCurrentPrintSession(
        _ generation: Int,
        printer: Printer,
        bluetoothInfo: BluetoothInfo
    ) -> Bool {
        (printGeneration[printer] ?? 0) == generation
            && connectedPrinters[printer]?.peripheral.identifier == bluetoothInfo.peripheral.identifier
    }

    private func invalidatePrintSession(for printer: Printer) {
        printGeneration[printer, default: 0] += 1
        printQueue[printer] = nil
        isPrinting[printer] = nil
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

        let printer = availablePrinters.first { $0.uuid == peripheral.identifier }
            ?? connectedPrinters.keys.first { $0.uuid == peripheral.identifier }
        guard let printer else { return }

        connectedPrinters[printer] = nil
        invalidatePrintSession(for: printer)
        updateAvailablePrinters { $0.remove(printer) }
    }
    
    private func registerMatchedCharacteristic(
        peripheral: CBPeripheral,
        service: CBService,
        characteristic: CBCharacteristic
    ) {
        logger.debug("Connected to printer \(peripheral.name ?? "")<\(peripheral.identifier)>")
        let printer = Printer(uuid: peripheral.identifier, name: peripheral.name ?? "Printer")
        if connectedPrinters[printer] != nil {
            invalidatePrintSession(for: printer)
        }
        connectedPrinters[printer] = .init(peripheral: peripheral, service: service, characteristic: characteristic)
        scanningPeripherals.removeAll(where: { $0.identifier.uuidString == peripheral.identifier.uuidString })
        updateAvailablePrinters { $0.insert(printer) }
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
    
    private func installObservers() {
        setupObservers()
        centralManager.delegate = managerProxy
        isReady = true
        readyContinuations.forEach { $0.resume() }
        readyContinuations.removeAll()
    }

    private func waitUntilReady() async {
        if isReady { return }
        await withCheckedContinuation { continuation in
            readyContinuations.append(continuation)
        }
    }

    private func setupObservers() {
        let peripheralDiscovered = managerProxy.peripheralDiscovered
        let peripheralDisconnected = managerProxy.peripheralDisconnected
        let servicesDiscovered = peripheralProxy.servicesDiscovered
        let characteristicsDiscovered = peripheralProxy.characteristicsDiscovered
        let printerNames = settings.printerName
        let characteristicId = settings.charateristic

        // Detached so these loops do not inherit the actor and keep CatPrinter alive.
        observationTasks = [
            Task.detached { [weak self] in
                for await discovery in peripheralDiscovered {
                    let peripheral = discovery.peripheral
                    guard printerNames.isEmpty || printerNames.contains(peripheral.name ?? "") else {
                        continue
                    }
                    await self?.connectToPeripheral(peripheral)
                }
            },
            Task.detached { [weak self] in
                for await peripheral in peripheralDisconnected {
                    await self?.onPeripheralDisconnected(peripheral)
                }
            },
            Task.detached { [weak self] in
                for await peripheral in servicesDiscovered {
                    await self?.onServicesDiscovered(peripheral)
                }
            },
            Task.detached { [weak self] in
                for await (peripheral, service) in characteristicsDiscovered {
                    let matches = (service.characteristics ?? [])
                        .filter { characteristicId == $0.uuid.uuidString }
                    for characteristic in matches {
                        await self?.registerMatchedCharacteristic(
                            peripheral: peripheral,
                            service: service,
                            characteristic: characteristic
                        )
                    }
                }
            }
        ]
    }

    private func addAvailablePrintersContinuation(
        _ id: UUID,
        _ continuation: AsyncStream<Set<Printer>>.Continuation
    ) {
        if cancelledAvailablePrintersContinuations.remove(id) != nil {
            continuation.finish()
            return
        }
        availablePrintersContinuations[id] = continuation
        continuation.yield(availablePrinters)
    }

    private func removeAvailablePrintersContinuation(_ id: UUID) {
        if availablePrintersContinuations.removeValue(forKey: id) == nil {
            cancelledAvailablePrintersContinuations.insert(id)
        }
    }

    private func updateAvailablePrinters(_ update: (inout Set<Printer>) -> Void) {
        update(&availablePrinters)
        for continuation in availablePrintersContinuations.values {
            continuation.yield(availablePrinters)
        }
    }
}

private extension CatPrinter {
    final class CentralManagerProxy: NSObject, CBCentralManagerDelegate {
        let peripheralDiscovered: AsyncStream<PeripheralDiscoveryData>
        let peripheralDisconnected: AsyncStream<CBPeripheral>

        private let peripheralDiscoveredContinuation: AsyncStream<PeripheralDiscoveryData>.Continuation
        private let peripheralDisconnectedContinuation: AsyncStream<CBPeripheral>.Continuation

        override init() {
            // Discovery includes repeated RSSI updates; keep only the newest burst.
            (peripheralDiscovered, peripheralDiscoveredContinuation) = makeAsyncStream(bufferingPolicy: .bufferingNewest(16))
            // Connect/disconnect must not be dropped while the actor is busy.
            (peripheralDisconnected, peripheralDisconnectedContinuation) = makeAsyncStream(bufferingPolicy: .unbounded)
            super.init()
        }

        func finish() {
            peripheralDiscoveredContinuation.finish()
            peripheralDisconnectedContinuation.finish()
        }
        
        func centralManagerDidUpdateState(_ central: CBCentralManager) {}
        
        func centralManager(
            _ central: CBCentralManager,
            didDiscover peripheral: CBPeripheral,
            advertisementData: [String : Any],
            rssi RSSI: NSNumber
        ) {
            peripheralDiscoveredContinuation.yield(
                .init(
                    peripheral: peripheral,
                    advertisementData: advertisementData,
                    rssi: RSSI
                )
            )
        }
        
        func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
            peripheral.discoverServices(nil)
        }
        
        func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
            peripheralDisconnectedContinuation.yield(peripheral)
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
        let servicesDiscovered: AsyncStream<CBPeripheral>
        let characteristicsDiscovered: AsyncStream<(CBPeripheral, CBService)>

        private let servicesDiscoveredContinuation: AsyncStream<CBPeripheral>.Continuation
        private let characteristicsDiscoveredContinuation: AsyncStream<(CBPeripheral, CBService)>.Continuation

        override init() {
            (servicesDiscovered, servicesDiscoveredContinuation) = makeAsyncStream(bufferingPolicy: .unbounded)
            (characteristicsDiscovered, characteristicsDiscoveredContinuation) = makeAsyncStream(bufferingPolicy: .unbounded)
            super.init()
        }

        func finish() {
            servicesDiscoveredContinuation.finish()
            characteristicsDiscoveredContinuation.finish()
        }
        
        func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
            servicesDiscoveredContinuation.yield(peripheral)
        }
        
        func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
            characteristicsDiscoveredContinuation.yield((peripheral, service))
        }

        func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
            servicesDiscoveredContinuation.yield(peripheral)
        }
    }
}

private func makeAsyncStream<Element>(
    bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy
) -> (AsyncStream<Element>, AsyncStream<Element>.Continuation) {
    var continuation: AsyncStream<Element>.Continuation!
    let stream = AsyncStream<Element>(bufferingPolicy: bufferingPolicy) { continuation = $0 }
    return (stream, continuation)
}

private func processPrinterImage(
    _ sourceImage: CGImage,
    options: CatPrinter.ImageProcessingOption,
    printerWidth: Int
) -> PrinterImageData {
    var image = sourceImage
    if options.contains(.addWhiteBackground) {
        image = image.addWhiteBackground()
    }

    if options.contains(.convertToGrayscale) {
        image = image.toGrayscale()
    }

    let targetSize = CGSize(
        width: printerWidth,
        height: Int(Double(image.height) * Double(printerWidth) / Double(image.width))
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
