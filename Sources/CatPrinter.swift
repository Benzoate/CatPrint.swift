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
    private let lifetime = Lifetime()
    
    private var isPrinting: [Printer: Bool] = [:]
    private var printGeneration: [Printer: Int] = [:]
    private var printWaiters: [Printer: [PrintWaiter]] = [:]
    
    @MainActor public init(
        settings: Settings = .default
    ) {
        self.settings = settings
        let managerProxy = managerProxy
        let peripheralProxy = peripheralProxy
        lifetime.addStreamFinisher { managerProxy.finish() }
        lifetime.addStreamFinisher { peripheralProxy.finish() }
        setupObservers(
            printerNames: settings.printerName,
            characteristicId: settings.charateristic
        )
        // Default CBCentralManager queue is main; assign the delegate here, not from the actor.
        centralManager.delegate = managerProxy
    }
    
    /// Will attempt to discover nearby printers. Supported printers are yielded by `availablePrintersUpdates`.
    public func startScan() async throws {
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
        try Task.checkCancellation()

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
        try await acquirePrintSlot(printer)
        let generation = printGeneration[printer] ?? 0
        defer { releasePrintSlot(printer, generation: generation) }

        guard let bluetoothInfo = connectedPrinters[printer] else {
            throw CatPrinterError.printerDisconnected
        }
        try await executeCommands(
            setupCommands + imageCommands + endCommands,
            printer: printer,
            generation: generation,
            bluetoothInfo: bluetoothInfo
        )
    }
    
    private func executeCommands(
        _ commands: [PrinterCommands],
        printer: Printer,
        generation: Int,
        bluetoothInfo: BluetoothInfo
    ) async throws {
        
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
            try Task.checkCancellation()
            guard isCurrentPrintSession(generation, printer: printer, bluetoothInfo: bluetoothInfo) else {
                logger.debug("Print session ended, stopping command write")
                throw CatPrinterError.printerDisconnected
            }
            bluetoothInfo.peripheral.writeValue(data, for: bluetoothInfo.characteristic, type: .withoutResponse)
            logger.debug("Sent packet \(offset), waiting 50ms")
            try await Task.sleep(nanoseconds: 50_000_000)
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
        isPrinting[printer] = nil
        let waiters = printWaiters.removeValue(forKey: printer) ?? []
        for waiter in waiters {
            waiter.continuation.resume(throwing: CatPrinterError.printerDisconnected)
        }
    }

    private func acquirePrintSlot(_ printer: Printer) async throws {
        while true {
            try Task.checkCancellation()
            guard connectedPrinters[printer] != nil else {
                throw CatPrinterError.printerDisconnected
            }
            if isPrinting[printer] != true {
                isPrinting[printer] = true
                return
            }

            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    printWaiters[printer, default: []].append(
                        PrintWaiter(id: id, continuation: continuation)
                    )
                }
            } onCancel: {
                Task { await self.removePrintWaiter(id, printer: printer) }
            }
        }
    }

    private func releasePrintSlot(_ printer: Printer, generation: Int) {
        guard (printGeneration[printer] ?? 0) == generation else { return }
        isPrinting[printer] = false
        if let waiter = printWaiters[printer]?.isEmpty == false
            ? printWaiters[printer]?.removeFirst()
            : nil {
            waiter.continuation.resume()
        }
    }

    private func removePrintWaiter(_ id: UUID, printer: Printer) {
        guard let index = printWaiters[printer]?.firstIndex(where: { $0.id == id }) else { return }
        let waiter = printWaiters[printer]?.remove(at: index)
        waiter?.continuation.resume(throwing: CancellationError())
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
            return
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
    
    private func onPeripheralConnectionFailed(_ peripheral: CBPeripheral) {
        logger.warning("Failed to connect to peripheral \(peripheral.name ?? "")<\(peripheral.identifier)>")
        scanningPeripherals.removeAll(where: { $0.identifier == peripheral.identifier })
    }

    private func setupObservers(
        printerNames: Set<String>,
        characteristicId: String
    ) {
        let peripheralDiscovered = managerProxy.peripheralDiscovered
        let peripheralDisconnected = managerProxy.peripheralDisconnected
        let peripheralConnectionFailed = managerProxy.peripheralConnectionFailed
        let servicesDiscovered = peripheralProxy.servicesDiscovered
        let characteristicsDiscovered = peripheralProxy.characteristicsDiscovered

        // Detached so these loops do not inherit the actor and keep CatPrinter alive.
        lifetime.setObservationTasks([
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
                for await peripheral in peripheralConnectionFailed {
                    await self?.onPeripheralConnectionFailed(peripheral)
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
        ])
    }

    private func addAvailablePrintersContinuation(
        _ id: UUID,
        _ continuation: AsyncStream<Set<Printer>>.Continuation
    ) {
        lifetime.addAvailablePrintersContinuation(id, continuation, current: availablePrinters)
    }

    private func removeAvailablePrintersContinuation(_ id: UUID) {
        lifetime.removeAvailablePrintersContinuation(id)
    }

    private func updateAvailablePrinters(_ update: (inout Set<Printer>) -> Void) {
        update(&availablePrinters)
        lifetime.yieldAvailablePrinters(availablePrinters)
    }

    private struct PrintWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    /// Nonisolated owner for work that must outlive the actor's isolated state.
    /// `deinit` only cancels observer tasks and finishes streams.
    private final class Lifetime {
        private var observationTasks: [Task<Void, Never>] = []
        private var availablePrintersContinuations: [UUID: AsyncStream<Set<Printer>>.Continuation] = [:]
        private var cancelledAvailablePrintersContinuations: Set<UUID> = []
        private var streamFinishers: [() -> Void] = []

        func setObservationTasks(_ tasks: [Task<Void, Never>]) {
            observationTasks = tasks
        }

        func addStreamFinisher(_ finish: @escaping () -> Void) {
            streamFinishers.append(finish)
        }

        func addAvailablePrintersContinuation(
            _ id: UUID,
            _ continuation: AsyncStream<Set<Printer>>.Continuation,
            current: Set<Printer>
        ) {
            if cancelledAvailablePrintersContinuations.remove(id) != nil {
                continuation.finish()
                return
            }
            availablePrintersContinuations[id] = continuation
            continuation.yield(current)
        }

        func removeAvailablePrintersContinuation(_ id: UUID) {
            if availablePrintersContinuations.removeValue(forKey: id) == nil {
                cancelledAvailablePrintersContinuations.insert(id)
            }
        }

        func yieldAvailablePrinters(_ printers: Set<Printer>) {
            for continuation in availablePrintersContinuations.values {
                continuation.yield(printers)
            }
        }

        deinit {
            observationTasks.forEach { $0.cancel() }
            for continuation in availablePrintersContinuations.values {
                continuation.finish()
            }
            streamFinishers.forEach { $0() }
        }
    }
}

private extension CatPrinter {
    final class CentralManagerProxy: NSObject, CBCentralManagerDelegate {
        let peripheralDiscovered: AsyncStream<PeripheralDiscoveryData>
        let peripheralDisconnected: AsyncStream<CBPeripheral>
        let peripheralConnectionFailed: AsyncStream<CBPeripheral>

        private let peripheralDiscoveredContinuation: AsyncStream<PeripheralDiscoveryData>.Continuation
        private let peripheralDisconnectedContinuation: AsyncStream<CBPeripheral>.Continuation
        private let peripheralConnectionFailedContinuation: AsyncStream<CBPeripheral>.Continuation

        override init() {
            (peripheralDiscovered, peripheralDiscoveredContinuation) = makeAsyncStream(bufferingPolicy: .unbounded)
            (peripheralDisconnected, peripheralDisconnectedContinuation) = makeAsyncStream(bufferingPolicy: .unbounded)
            (peripheralConnectionFailed, peripheralConnectionFailedContinuation) = makeAsyncStream(bufferingPolicy: .unbounded)
            super.init()
        }

        func finish() {
            peripheralDiscoveredContinuation.finish()
            peripheralDisconnectedContinuation.finish()
            peripheralConnectionFailedContinuation.finish()
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

        func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
            peripheralConnectionFailedContinuation.yield(peripheral)
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
