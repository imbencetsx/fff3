import CoreBluetooth
import Foundation
import os
import Fff3Core

enum ConnectionState: Equatable, Sendable {
    case idle
    case connecting(attempt: Int)
    case connected
    case waitingToRetry(failures: Int, retryInMillis: Int)
    case bluetoothOff
    case permissionMissing
    case unsupported
}

enum BluetoothStatus: Sendable { case unknown, ready, off, permissionMissing, unsupported }

struct ScannedStrip: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let family: LedFamily
    let rssi: Int
}

/// Every strip's link, on one serial queue. CoreBluetooth calls back on that queue too, so the
/// state below is only touched there. Results go to the main actor through the `on…` callbacks.
final class LedController: NSObject, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.kernoeb.fff3.ble", qos: .userInteractive)
    /// Time from send to a finished write, for the music beat clock.
    let linkLatency = WriteLatency()
    /// Time each command waits before its Bluetooth write, for the music beat clock.
    let queueWait = WriteLatency()

    private var central: CBCentralManager!
    private var links: [UUID: StripLink] = [:]
    private var status = BluetoothStatus.unknown
    private var scanning = false
    private var scanned: [UUID: ScannedStrip] = [:]
    private var scanPublishedAt: UInt64 = 0

    private let onStates: @Sendable ([UUID: ConnectionState]) -> Void
    private let onScan: @Sendable ([ScannedStrip]) -> Void
    private let onStatus: @Sendable (BluetoothStatus) -> Void

    init(
        onStates: @escaping @Sendable ([UUID: ConnectionState]) -> Void,
        onScan: @escaping @Sendable ([ScannedStrip]) -> Void,
        onStatus: @escaping @Sendable (BluetoothStatus) -> Void
    ) {
        self.onStates = onStates
        self.onScan = onScan
        self.onStatus = onStatus
        super.init()
        queue.async {
            self.central = CBCentralManager(delegate: self, queue: self.queue, options: [CBCentralManagerOptionShowPowerAlertKey: true])
        }
    }

    /// Keeps one link per known strip, and closes the links of strips that were removed.
    func setDevices(_ devices: [KnownDevice]) {
        queue.async {
            let wanted = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
            for (id, link) in self.links where wanted[id] == nil || wanted[id]!.family != link.family {
                link.close()
                self.links[id] = nil
            }
            for device in devices where self.links[device.id] == nil {
                self.links[device.id] = StripLink(id: device.id, family: device.family, controller: self)
            }
            for device in devices {
                self.links[device.id]?.colorCalibration = device.colorCalibration ?? ColorCalibration()
            }
            if self.status == .ready { self.links.values.forEach { $0.start() } }
            self.publishStates()
        }
    }

    /// Never blocks. A command a strip's family cannot do is skipped for that strip.
    func send(_ ids: [UUID], _ commands: [Command]) {
        queue.async {
            for id in ids {
                guard let link = self.links[id] else { continue }
                for command in commands { link.send(command) }
            }
        }
    }

    func previewColorCalibration(_ id: UUID, _ calibration: ColorCalibration) {
        queue.async { self.links[id]?.colorCalibration = calibration }
    }

    func retryNow() {
        queue.async { self.links.values.forEach { $0.retryNow() } }
    }

    func startScan() {
        queue.async {
            self.scanning = true
            self.scanned = [:]
            self.onScan([])
            self.beginScan()
        }
    }

    func stopScan() {
        queue.async {
            self.scanning = false
            if self.central?.isScanning == true { self.central.stopScan() }
        }
    }

    /// Disconnects every strip, for example when the app quits. Waits up to a second for connected
    /// strips to receive what is queued, such as the colours that end music sync.
    func closeAll() {
        let deadline = nowNanos() + 1_000_000_000
        while nowNanos() < deadline, !queue.sync(execute: { self.links.values.allSatisfy { $0.state != .connected || $0.isIdle } }) {
            Thread.sleep(forTimeInterval: 0.01)
        }
        queue.sync { self.links.values.forEach { $0.close() } }
    }

    private func beginScan() {
        guard scanning, status == .ready, central.isScanning == false else { return }
        // The strips do not always advertise their service, so scan for everything and filter by name.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    fileprivate func publishStates() {
        let states = links.mapValues { $0.state }
        onStates(states)
    }

    fileprivate func peripheral(for id: UUID) -> CBPeripheral? {
        central.retrievePeripherals(withIdentifiers: [id]).first
    }

    fileprivate var centralManager: CBCentralManager { central }
    fileprivate var bluetoothStatus: BluetoothStatus { status }
}

extension LedController: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        status = switch central.state {
        case .poweredOn: .ready
        case .poweredOff, .resetting: .off
        case .unauthorized: .permissionMissing
        case .unsupported: .unsupported
        default: .unknown
        }
        onStatus(status)
        for link in links.values {
            if status == .ready { link.start() } else { link.bluetoothGone(status) }
        }
        if status == .ready { beginScan() }
        publishStates()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        guard scanning else { return }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        guard let family = LedFamily.detect(name), let name else { return }
        scanned[peripheral.identifier] = ScannedStrip(id: peripheral.identifier, name: name, family: family, rssi: rssi.intValue)
        // Duplicates come many times a second: publish at most 4 times a second.
        let now = nowNanos()
        if now - scanPublishedAt > 250_000_000 {
            scanPublishedAt = now
            onScan(scanned.values.sorted { $0.rssi > $1.rssi })
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        links[peripheral.identifier]?.didConnect()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        links[peripheral.identifier]?.didDrop(error: error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        links[peripheral.identifier]?.didDrop(error: error)
    }
}

/// The link to one strip. It connects as soon as Bluetooth is ready, reconnects with backoff
/// when the link drops, and sends the Mac's time on each connect, like `ClockSyncer.kt`.
final class StripLink: NSObject, CBPeripheralDelegate, @unchecked Sendable {
    let id: UUID
    let family: LedFamily
    var colorCalibration = ColorCalibration()
    private unowned let controller: LedController
    private(set) var state = ConnectionState.idle {
        didSet { if state != oldValue { controller.publishStates() } }
    }
    private var peripheral: CBPeripheral?
    private var characteristic: CBCharacteristic?
    private var writeType = CBCharacteristicWriteType.withoutResponse
    private var failures = 0
    private var lifecycle = ConnectionLifecycle()
    private var connectedAt: UInt64?
    private var acknowledgement = WriteAcknowledgementToken()
    private static let logger = Logger(subsystem: "com.kernoeb.fff3.mac", category: "Bluetooth")
    private var closed = false
    private var pendingAck: ((WriteOutcome) -> Void)?
    private var writeQueue: WriteQueue!

    init(id: UUID, family: LedFamily, controller: LedController) {
        self.id = id
        self.family = family
        self.controller = controller
        super.init()
        writeQueue = WriteQueue(
            queue: controller.queue,
            onSent: { [latency = controller.linkLatency] in latency.record($0) },
            onWriteStarted: { [wait = controller.queueWait] in wait.record($0) },
            write: { [weak self] frame, done in self?.write(frame, done) ?? done(.failed) }
        )
    }

    func send(_ command: Command) {
        let frames = family.encode(colorCalibration.apply(command))
        if frames.isEmpty { return }
        writeQueue.enqueue(command, frames: frames)
    }

    var isIdle: Bool { writeQueue.isIdle }

    func start() {
        guard !closed else { return }
        connect()
    }

    func retryNow() {
        if case .waitingToRetry = state { connect() }
    }

    func bluetoothGone(_ status: BluetoothStatus) {
        lifecycle.suspend()
        connectedAt = nil
        characteristic = nil
        failPendingAck()
        state = switch status {
        case .permissionMissing: .permissionMissing
        case .unsupported: .unsupported
        default: .bluetoothOff
        }
    }

    func close() {
        closed = true
        lifecycle.close()
        writeQueue.clear()
        failPendingAck()
        if let peripheral { controller.centralManager.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        characteristic = nil
        state = .idle
    }

    private func connect() {
        guard !closed, controller.bluetoothStatus == .ready, let token = lifecycle.begin() else { return }
        guard let found = controller.peripheral(for: id) else {
            _ = lifecycle.disconnected()
            failures += 1
            scheduleRetry()
            return
        }
        peripheral = found
        found.delegate = self
        state = .connecting(attempt: failures + 1)
        Self.logger.info("Connecting strip \(self.id.uuidString.prefix(4), privacy: .public), attempt \(self.failures + 1)")
        controller.centralManager.connect(found)
        controller.queue.asyncAfter(deadline: .now() + BleTuning.connectTimeout + BleTuning.discoveryTimeout) { [weak self] in
            guard let self, self.characteristic == nil else { return }
            self.cancelConnection(generation: token, reason: "Connection or discovery timed out")
        }
    }

    func didConnect() {
        guard !closed, lifecycle.connected() else { return }
        peripheral?.discoverServices([CBUUID(string: family.proto.gatt.service)])
    }

    func didDrop(error: Error? = nil) {
        guard !closed, lifecycle.disconnected() else { return }
        let connectedFor = connectedAt.map { Double(nowNanos() - $0) / 1e9 } ?? 0
        if connectedFor >= 30 { failures = 0 }
        failures += 1
        connectedAt = nil
        characteristic = nil
        failPendingAck()
        let code = (error as NSError?)?.code ?? 0
        let domain = (error as NSError?)?.domain ?? "local cancellation"
        Self.logger.notice("Strip \(self.id.uuidString.prefix(4), privacy: .public) disconnected after \(connectedFor) seconds: \(domain, privacy: .public) code \(code)")
        scheduleRetry()
    }

    private func cancelConnection(generation: Int, reason: String) {
        guard !closed, let peripheral, lifecycle.cancel(generation: generation) else { return }
        characteristic = nil
        failPendingAck()
        state = .connecting(attempt: failures + 1)
        Self.logger.notice("Cancelling strip \(self.id.uuidString.prefix(4), privacy: .public): \(reason, privacy: .public)")
        // CoreBluetooth cancellation is asynchronous. Retry only after its delegate callback.
        controller.centralManager.cancelPeripheralConnection(peripheral)
    }

    private func scheduleRetry() {
        let wait = backoff(failures)
        state = .waitingToRetry(failures: failures, retryInMillis: wait)
        let token = lifecycle.generation
        controller.queue.asyncAfter(deadline: .now() + .milliseconds(wait)) { [weak self] in
            guard let self, token == self.lifecycle.generation, !self.closed else { return }
            self.connect()
        }
    }

    private func backoff(_ failures: Int) -> Int {
        if failures == 0 { return 500 }
        let base = min(BleTuning.reconnectFirstDelayMs << min(failures - 1, 10), BleTuning.reconnectMaxDelayMs)
        return base + Int.random(in: 0...(base / 4))
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard lifecycle.phase == .discovering else { return }
        let gatt = family.proto.gatt
        guard let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: gatt.service) }) else {
            cancelConnection(generation: lifecycle.generation, reason: "LED service discovery failed")
            return
        }
        peripheral.discoverCharacteristics([CBUUID(string: gatt.writeCharacteristic)], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard lifecycle.phase == .discovering else { return }
        let gatt = family.proto.gatt
        guard let found = service.characteristics?.first(where: { $0.uuid == CBUUID(string: gatt.writeCharacteristic) }) else {
            NSLog("fff3: %@ has no %@ in %@", id.uuidString, gatt.writeCharacteristic, gatt.service)
            cancelConnection(generation: lifecycle.generation, reason: "LED characteristic discovery failed")
            return
        }
        guard lifecycle.ready() else { return }
        let canSkipResponse = found.properties.contains(.writeWithoutResponse)
        writeType = gatt.writeWithoutResponse && canSkipResponse ? .withoutResponse : .withResponse
        characteristic = found
        connectedAt = nowNanos()
        state = .connected
        Self.logger.info("Strip \(self.id.uuidString.prefix(4), privacy: .public) ready")
        peripheral.readRSSI()
        send(.clockSync(at: Date()))
        writeQueue.wake()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let token = acknowledgement.pending, acknowledgement.complete(token) else { return }
        let ack = pendingAck
        pendingAck = nil
        ack?(error == nil ? .sent : .failed)
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil else { return }
        Self.logger.info("Strip \(self.id.uuidString.prefix(4), privacy: .public) signal \(RSSI.intValue) dBm")
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        writeQueue.wake()
    }

    private func write(_ frame: [UInt8], _ done: @escaping (WriteOutcome) -> Void) {
        guard let peripheral, let characteristic, state == .connected else {
            done(.waiting)
            return
        }
        let data = Data(frame)
        if writeType == .withoutResponse {
            guard peripheral.canSendWriteWithoutResponse else {
                done(.busy)
                return
            }
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
            logFrame(frame)
            done(.sent)
            return
        }
        let acknowledgementToken = acknowledgement.begin()
        pendingAck = done
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
        logFrame(frame)
        let token = lifecycle.generation
        controller.queue.asyncAfter(deadline: .now() + BleTuning.writeAckTimeout) { [weak self] in
            guard let self, token == self.lifecycle.generation,
                  self.acknowledgement.pending == acknowledgementToken else { return }
            // Reconnect rather than treating an unacknowledged command as delivered.
            self.cancelConnection(generation: token, reason: "Bluetooth write acknowledgement timed out")
        }
    }

    /// FFF3_BLE_LOG=1 prints each frame as it goes to the strip, with the time in milliseconds.
    private func logFrame(_ frame: [UInt8]) {
        guard Self.logFrames else { return }
        let line = String(format: "fff3-ble %.1f %@ %@\n", Double(nowNanos()) / 1e6, String(id.uuidString.prefix(4)), frame.hex)
        FileHandle.standardError.write(line.data(using: .utf8)!)
    }

    private static let logFrames = ProcessInfo.processInfo.environment["FFF3_BLE_LOG"] != nil

    private func failPendingAck() {
        acknowledgement.clear()
        let ack = pendingAck
        pendingAck = nil
        ack?(.waiting)
    }
}
