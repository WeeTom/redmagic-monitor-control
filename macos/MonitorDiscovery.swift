import CoreBluetooth
import Foundation

/// One bounded, read-only search. Call start/cancel on the main thread.
/// Constructing this object does not start Bluetooth or request permission.
final class MonitorDiscovery: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    struct Candidate: Identifiable, Equatable {
        let id: UUID
        let name: String
        let address: Data

        var addressString: String { address.map { String(format: "%02X", $0) }.joined(separator: ":") }
        var addressSuffix: String { address.suffix(2).map { String(format: "%02X", $0) }.joined() }
    }

    struct Scan {
        /// Every entry passed GATT checks, including matching the six identity bytes
        /// against the address in the GM001J name. No settings have been read or written.
        let candidates: [Candidate]
        /// Includes GM001J observations which could not be verified. A single verified
        /// item is not sufficient for automatic selection if other units were observed.
        let observedCount: Int
    }

    private struct Probe {
        let peripheral: CBPeripheral
        let candidate: Candidate
        var identity: CBCharacteristic?
        var controlVerified = false
        var reading = false
        var timeout: DispatchWorkItem?
    }

    private var completion: ((Result<Scan, Error>) -> Void)?
    private var central: CBCentralManager?
    private var scanning = false
    private var collectionEnded = false
    private var deadline: DispatchWorkItem?
    private var seen = Set<UUID>()
    private var addresses = [UUID: Data]()
    private var pending = [Probe]()
    private var probes = [UUID: Probe]()
    private var verified = [UUID: Candidate]()

    /// Decodes the 12 hex digits from this model's local name, not CoreBluetooth's
    /// peripheral UUID. macOS does not expose the radio address directly.
    static func address(in name: String) -> Data? {
        guard let hex = addressDigits(in: name), hex.count == 12 else { return nil }
        var bytes = Data()
        for offset in stride(from: 0, to: 12, by: 2) {
            guard let byte = UInt8(hex.dropFirst(offset).prefix(2), radix: 16) else { return nil }
            bytes.append(byte)
        }
        guard !bytes.allSatisfy({ $0 == 0 }), !bytes.allSatisfy({ $0 == 255 }) else { return nil }
        return bytes
    }

    private static func addressDigits(in name: String) -> Substring? {
        let prefix = GM001JGATT.model
        guard name.utf8.allSatisfy({ $0 < 128 }), name.uppercased().hasPrefix(prefix) else { return nil }
        let suffix = name.dropFirst(prefix.count)
        guard suffix.count <= 12, suffix.allSatisfy({ $0.isHexDigit }) else { return nil }
        return suffix
    }

    func start(completion: @escaping (Result<Scan, Error>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        cancel()
        self.completion = completion
        if CBManager.authorization == .denied || CBManager.authorization == .restricted {
            fail("请在系统设置 → 隐私与安全性 → 蓝牙中允许本应用")
            return
        }
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])
        scheduleDeadline(seconds: 45) { [weak self] in
            self?.fail("蓝牙连接尚未就绪")
        }
    }

    /// Drops the pending completion and releases this central's connections only.
    func cancel() {
        dispatchPrecondition(condition: .onQueue(.main))
        completion = nil
        deadline?.cancel()
        deadline = nil
        if central?.isScanning == true { central?.stopScan() }
        central?.delegate = nil
        for probe in probes.values {
            release(probe)
        }
        central = nil
        scanning = false
        collectionEnded = false
        probes.removeAll()
        pending.removeAll()
        seen.removeAll()
        addresses.removeAll()
        verified.removeAll()
    }

    deinit {
        deadline?.cancel()
        for probe in probes.values {
            probe.timeout?.cancel()
            if probe.peripheral.delegate === self { probe.peripheral.delegate = nil }
        }
        // Dropping the dedicated central releases its scans and connection requests.
    }

    private func release(_ probe: Probe) {
        probe.timeout?.cancel()
        if probe.peripheral.delegate === self { probe.peripheral.delegate = nil }
        if central?.state == .poweredOn { central?.cancelPeripheralConnection(probe.peripheral) }
    }

    private func fail(_ key: String) {
        let callback = completion
        cancel()
        callback?(.failure(DisplayError(tr(key))))
    }

    private func finish() {
        let callback = completion
        // A shortcut identifies a monitor by its verified address. Do not offer an
        // address shared by distinct peripheral identifiers as a selectable target.
        let counts = Dictionary(grouping: addresses, by: { $0.value }).mapValues(\.count)
        let candidates = verified.values.filter { counts[$0.address] == 1 }
            .sorted { $0.address.lexicographicallyPrecedes($1.address) }
        let result = Scan(candidates: candidates, observedCount: seen.count)
        cancel()
        callback?(.success(result))
    }

    private func scheduleDeadline(seconds: Int, _ action: @escaping () -> Void) {
        deadline?.cancel()
        let work = DispatchWorkItem(block: action)
        deadline = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds), execute: work)
    }

    func centralManagerDidUpdateState(_ manager: CBCentralManager) {
        guard manager === central else { return }
        switch manager.state {
        case .poweredOn:
            guard !scanning else { return }
            scanning = true
            // GM001J devices connected to another client may no longer advertise.
            for peripheral in manager.retrieveConnectedPeripherals(withServices: [GM001JGATT.control]) {
                let name = peripheral.name ?? ""
                if GM001JGATT.model.hasPrefix(name.uppercased()) {
                    // A connected device may withhold its full advertising name. Count
                    // the known service as unresolved rather than silently auto-picking a peer.
                    seen.insert(peripheral.identifier)
                }
                observe(peripheral, name: name)
            }
            // Name filtering also finds units whose current advertisement omits the service.
            manager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            scheduleDeadline(seconds: 6) { [weak self] in
                guard let self else { return }
                self.central?.stopScan()
                self.collectionEnded = true
                if self.probes.isEmpty && self.pending.isEmpty { self.finish() }
                else { self.scheduleDeadline(seconds: 8) { [weak self] in self?.finish() } }
            }
        case .unauthorized:
            // Some versions report this transiently while the system prompt is open.
            if CBManager.authorization != .notDetermined {
                fail("请在系统设置 → 隐私与安全性 → 蓝牙中允许本应用")
            }
        case .unsupported:
            fail("当前 Mac 无法使用低功耗蓝牙")
        case .poweredOff:
            fail("Mac 蓝牙已关闭，请开启后刷新")
        case .unknown, .resetting:
            if scanning { fail("蓝牙连接尚未就绪") }
        @unknown default:
            fail("蓝牙连接尚未就绪")
        }
    }

    func centralManager(_ manager: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        guard manager === central, !collectionEnded else { return }
        observe(peripheral, name: advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name)
    }

    private func observe(_ peripheral: CBPeripheral, name: String?) {
        guard let name, Self.addressDigits(in: name) != nil else { return }
        let id = peripheral.identifier
        // Even a shortened model name can signal another unit. It must not become
        // eligible until both the complete name and matching GATT identity are known.
        seen.insert(id)
        guard let address = Self.address(in: name) else { return }
        if let old = addresses[id] {
            if old != address {
                verified.removeValue(forKey: id)
                addresses[id] = Data() // Conflicting identity for this identifier.
            }
            return
        }
        addresses[id] = address
        let candidate = Candidate(id: id, name: name, address: address)
        pending.append(Probe(peripheral: peripheral, candidate: candidate))
        startPendingProbes()
    }

    private func startPendingProbes() {
        while probes.count < 4, !pending.isEmpty, let central {
            var probe = pending.removeFirst()
            let id = probe.candidate.id
            let timeout = DispatchWorkItem { [weak self] in self?.endProbe(id) }
            probe.timeout = timeout
            probes[id] = probe
            probe.peripheral.delegate = self
            central.connect(probe.peripheral)
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
        }
    }

    private func endProbe(_ id: UUID) {
        guard let probe = probes.removeValue(forKey: id) else { return }
        release(probe)
        startPendingProbes()
        if collectionEnded && probes.isEmpty && pending.isEmpty { finish() }
    }

    func centralManager(_ manager: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard manager === central else { return }
        guard probes[peripheral.identifier]?.peripheral === peripheral else {
            manager.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverServices([GM001JGATT.control, GM001JGATT.identification])
    }

    func centralManager(_ manager: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if manager === central { endProbe(peripheral.identifier) }
    }

    func centralManager(_ manager: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if manager === central { endProbe(peripheral.identifier) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let id = peripheral.identifier
        guard probes[id]?.peripheral === peripheral else { return }
        let services = peripheral.services ?? []
        guard error == nil, let control = services.first(where: { $0.uuid == GM001JGATT.control }),
              let identification = services.first(where: { $0.uuid == GM001JGATT.identification }) else {
            endProbe(id)
            return
        }
        peripheral.discoverCharacteristics([GM001JGATT.transmit, GM001JGATT.receive], for: control)
        peripheral.discoverCharacteristics([GM001JGATT.address], for: identification)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let id = peripheral.identifier
        guard var probe = probes[id], probe.peripheral === peripheral else { return }
        let characteristics = service.characteristics ?? []
        guard error == nil else { endProbe(id); return }
        if service.uuid == GM001JGATT.control {
            guard characteristics.contains(where: { $0.uuid == GM001JGATT.transmit && $0.properties.contains(.writeWithoutResponse) }),
                  characteristics.contains(where: { $0.uuid == GM001JGATT.receive && $0.properties.contains(.notify) }) else {
                endProbe(id)
                return
            }
            probe.controlVerified = true
        } else if service.uuid == GM001JGATT.identification {
            guard let identity = characteristics.first(where: { $0.uuid == GM001JGATT.address && $0.properties.contains(.read) }) else {
                endProbe(id)
                return
            }
            probe.identity = identity
        }
        if probe.controlVerified, let identity = probe.identity, !probe.reading {
            probe.reading = true
            probes[id] = probe
            peripheral.readValue(for: identity)
        } else {
            probes[id] = probe
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let id = peripheral.identifier
        guard let probe = probes[id], probe.peripheral === peripheral, probe.reading,
              characteristic === probe.identity else { return }
        if error == nil, let bytes = characteristic.value,
           bytes == probe.candidate.address, bytes == addresses[id] {
            verified[id] = probe.candidate
        }
        endProbe(id)
    }
}
