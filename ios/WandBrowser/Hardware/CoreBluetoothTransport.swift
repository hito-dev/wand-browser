import Foundation
@preconcurrency import CoreBluetooth

@MainActor
final class CoreBluetoothTransport: NSObject, BluetoothTransport, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    var onDiscovery: (([DiscoveredDevice], String) -> Void)?
    var onScanError: ((WebError) -> Void)?
    var onEvent: ((String, JSONValue) -> Void)?

    private var central: CBCentralManager?
    private var scanOptions: BluetoothRequestOptions?
    private var scanTimeout: Task<Void, Never>?
    private var devices: [String: CBPeripheral] = [:]
    private var discovered: [String: DiscoveredDevice] = [:]
    private var grants: [String: Set<String>] = [:]
    private var services: [String: CBService] = [:]
    private var characteristics: [String: CBCharacteristic] = [:]
    private var operations: [String: [Operation]] = [:]
    private var active: [String: Operation] = [:]
    private var deadlines: [String: Task<Void, Never>] = [:]

    private struct Operation {
        let id = UUID()
        let method: String
        let args: JSONObject
        let continuation: CheckedContinuation<JSONValue, Error>
    }

    func startScan(options: BluetoothRequestOptions) {
        stopScan()
        scanOptions = options
        discovered.removeAll()
        onDiscovery?([], "Waiting for Bluetooth…")
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        } else { updateScan() }
        scanTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self, self.scanOptions != nil else { return }
            self.central?.stopScan()
            self.onDiscovery?(self.candidates, self.candidates.isEmpty ? "No matching devices found. Try scanning again." : "Scan finished. Choose a device or scan again.")
        }
    }
    func stopScan() {
        scanTimeout?.cancel(); scanTimeout = nil
        central?.stopScan(); scanOptions = nil
    }
    private var candidates: [DiscoveredDevice] {
        discovered.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    private func updateScan() {
        guard scanOptions != nil, let central else { return }
        switch central.state {
        case .poweredOn:
            // Name-only filters must see devices that omit their services from advertising.
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            onDiscovery?(candidates, "Looking for nearby devices…")
        case .poweredOff: onScanError?(WebError("NotFoundError", "Bluetooth is turned off. Turn it on in Settings and try again."))
        case .unauthorized: onScanError?(WebError("NotAllowedError", "Bluetooth access is denied. Allow Wand Browser in Settings."))
        case .unsupported: onScanError?(WebError("NotSupportedError", "Bluetooth is unavailable on this device."))
        default: onDiscovery?(candidates, "Waiting for Bluetooth…")
        }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn {
            for id in Array(grants.keys) { disconnected(id) }
        }
        updateScan()
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard let options = scanOptions else { return }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        let uuids = ((advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
                     + (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []))
        let advertised = Set(uuids.compactMap { try? BluetoothUUID.canonical(.string($0.uuidString)) })
        guard options.matches(name: name, services: advertised) else { return }
        let id = deviceID(peripheral) ?? UUID().uuidString
        devices[id] = peripheral
        discovered[id] = DiscoveredDevice(id: id, name: name ?? "Unnamed device", rssi: RSSI.intValue)
        onDiscovery?(candidates, "Choose a device to allow access.")
    }
    func grant(id: String, services: Set<String>) throws -> JSONValue {
        guard let peripheral = devices[id], discovered[id] != nil else {
            throw WebError("NotFoundError", "The selected device is no longer available.")
        }
        grants[id, default: []].formUnion(services)
        peripheral.delegate = self
        return .object(["id": .string(id), "name": .string(discovered[id]?.name ?? peripheral.name ?? "")])
    }
    func perform(_ method: String, args: JSONObject) async throws -> JSONValue {
        let id: String
        if let handle = args["characteristic"]?.string {
            guard let characteristic = characteristics[handle], let peripheral = characteristic.service?.peripheral,
                  let owner = deviceID(peripheral) else { throw WebError("InvalidStateError", "Stale characteristic.") }
            id = owner
            try GATTBlocklist.check(uuid(characteristic.uuid), writing: method.hasPrefix("ble.write"))
        } else if let handle = args["service"]?.string {
            guard let service = services[handle], let peripheral = service.peripheral, let owner = deviceID(peripheral) else {
                throw WebError("InvalidStateError", "Stale service.")
            }
            id = owner
        } else { id = try args.requiredString("device") }
        guard grants[id] != nil, let peripheral = devices[id] else {
            throw WebError("SecurityError", "This document has not selected that device.")
        }
        if method == "ble.disconnect" {
            central?.cancelPeripheralConnection(peripheral)
            disconnected(id)
            return .null
        }
        guard method == "ble.connect" || peripheral.state == .connected else { throw WebError.disconnected }
        guard operations[id, default: []].count < 32 else { throw WebError("QuotaExceededError", "Too many Bluetooth operations.") }
        return try await withCheckedThrowingContinuation { continuation in
            operations[id, default: []].append(Operation(method: method, args: args, continuation: continuation))
            pump(id)
        }
    }
    private func pump(_ id: String) {
        guard active[id] == nil, var queue = operations[id], !queue.isEmpty, let peripheral = devices[id] else { return }
        let op = queue.removeFirst()
        operations[id] = queue; active[id] = op
        deadlines[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.active[id]?.id == op.id else { return }
            // Disconnect on timeout: a late delegate callback cannot complete the next operation.
            self.central?.cancelPeripheralConnection(peripheral)
            self.disconnected(id, error: WebError("NetworkError", "Bluetooth operation timed out. Reconnect to try again."))
        }
        do {
            if op.method != "ble.connect", peripheral.state != .connected { throw WebError.disconnected }
            switch op.method {
            case "ble.connect":
                guard central?.state == .poweredOn else { throw WebError("NetworkError", "Bluetooth is unavailable.") }
                if peripheral.state == .connected { finish(id, .success(.null)) }
                else if peripheral.state == .disconnected { central?.connect(peripheral) }
                else { throw WebError("InvalidStateError", "Wait for the previous connection to close.") }
            case "ble.services":
                let allowed = grants[id] ?? []
                let requested = try op.args["uuid"].map { try BluetoothUUID.canonical($0) }
                if let requested, !allowed.contains(requested) { throw WebError("SecurityError", "This service was not requested in requestDevice().") }
                let requestedServices = requested.map { [$0] } ?? Array(allowed).sorted()
                guard !requestedServices.isEmpty else { throw WebError("SecurityError", "No services were granted to this site.") }
                peripheral.discoverServices(requestedServices.map { CBUUID(string: $0) })
            case "ble.characteristics":
                guard let service = services[try op.args.requiredString("service")] else { throw WebError("InvalidStateError", "Stale service.") }
                let requested = try op.args["uuid"].map { try BluetoothUUID.canonical($0) }
                if let requested { try GATTBlocklist.check(requested) }
                peripheral.discoverCharacteristics(requested.map { [CBUUID(string: $0)] }, for: service)
            case "ble.read", "ble.write", "ble.writeWithResponse", "ble.writeWithoutResponse", "ble.startNotifications", "ble.stopNotifications":
                guard let characteristic = characteristics[try op.args.requiredString("characteristic")] else { throw WebError("InvalidStateError", "Stale characteristic.") }
                switch op.method {
                case "ble.read":
                    guard characteristic.properties.contains(.read) else { throw WebError("NotSupportedError", "This characteristic is not readable.") }
                    peripheral.readValue(for: characteristic)
                case "ble.startNotifications", "ble.stopNotifications":
                    guard characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) else {
                        throw WebError("NotSupportedError", "This characteristic does not support notifications.")
                    }
                    peripheral.setNotifyValue(op.method == "ble.startNotifications", for: characteristic)
                default:
                    let bytes = try op.args.data("data", maximum: 512)
                    let response = op.method == "ble.writeWithResponse" || (op.method == "ble.write" && characteristic.properties.contains(.write))
                    let type: CBCharacteristicWriteType = response ? .withResponse : .withoutResponse
                    guard characteristic.properties.contains(response ? .write : .writeWithoutResponse) else {
                        throw WebError("NotSupportedError", "This characteristic does not support the requested write mode.")
                    }
                    let limit = peripheral.maximumWriteValueLength(for: type)
                    guard bytes.count <= limit else {
                        throw WebError("InvalidModificationError", "The \(bytes.count)-byte write exceeds this connection's \(limit)-byte limit. Reduce the application's packet size.")
                    }
                    if !response && !peripheral.canSendWriteWithoutResponse { return }
                    peripheral.writeValue(bytes, for: characteristic, type: type)
                    if !response { finish(id, .success(.null)) }
                }
            default: throw WebError("NotSupportedError", "Unknown Bluetooth operation.")
            }
        } catch { finish(id, .failure(WebError.wrapping(error))) }
    }
    private func finish(_ id: String, _ result: Result<JSONValue, WebError>) {
        guard let op = active.removeValue(forKey: id) else { return }
        deadlines.removeValue(forKey: id)?.cancel()
        op.continuation.resume(with: result.mapError { $0 as Error })
        pump(id)
    }
    private func disconnected(_ id: String, error: WebError = .disconnected) {
        let pending = operations.removeValue(forKey: id) ?? []
        let current = active.removeValue(forKey: id)
        deadlines.removeValue(forKey: id)?.cancel()
        current?.continuation.resume(throwing: error)
        pending.forEach { $0.continuation.resume(throwing: error) }
        let peripheral = devices[id]
        services = services.filter { $0.value.peripheral !== peripheral }
        characteristics = characteristics.filter { $0.value.service?.peripheral !== peripheral }
        onEvent?("ble.disconnected", .object(["device": .string(id)]))
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let id = deviceID(peripheral), active[id]?.method == "ble.connect" else {
            central.cancelPeripheralConnection(peripheral); return
        }
        finish(id, .success(.null))
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard let id = deviceID(peripheral) else { return }
        disconnected(id, error: error.map(WebError.wrapping) ?? .disconnected)
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard let id = deviceID(peripheral) else { return }
        disconnected(id)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let id = deviceID(peripheral), let op = active[id], op.method == "ble.services" else { return }
        if let error { finish(id, .failure(WebError.wrapping(error))); return }
        let requested = try? op.args["uuid"].map { try BluetoothUUID.canonical($0) }
        let values = (peripheral.services ?? []).filter {
            $0.isPrimary && (grants[id]?.contains(uuid($0.uuid)) ?? false) && (requested == nil || uuid($0.uuid) == requested)
        }.map { service -> JSONValue in
            let handle = services.first { $0.value === service }?.key ?? UUID().uuidString
            services[handle] = service
            return .object(["id": .string(handle), "uuid": .string(uuid(service.uuid)), "device": .string(id), "isPrimary": .bool(service.isPrimary)])
        }
        finish(id, .success(.array(values)))
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let id = deviceID(peripheral), let op = active[id], op.method == "ble.characteristics",
              let serviceID = op.args["service"]?.string, services[serviceID] === service else { return }
        if let error { finish(id, .failure(WebError.wrapping(error))); return }
        let requested = try? op.args["uuid"].map { try BluetoothUUID.canonical($0) }
        let values = (service.characteristics ?? []).filter {
            !GATTBlocklist.excluded.contains(uuid($0.uuid)) && (requested == nil || uuid($0.uuid) == requested)
        }.map { characteristic -> JSONValue in
            let handle = characteristics.first { $0.value === characteristic }?.key ?? UUID().uuidString
            characteristics[handle] = characteristic
            let p = characteristic.properties
            return .object(["id": .string(handle), "uuid": .string(uuid(characteristic.uuid)), "service": .string(serviceID),
                            "properties": .object(["read": .bool(p.contains(.read)), "write": .bool(p.contains(.write)),
                                                  "writeWithoutResponse": .bool(p.contains(.writeWithoutResponse)),
                                                  "notify": .bool(p.contains(.notify)), "indicate": .bool(p.contains(.indicate)),
                                                  "broadcast": .bool(p.contains(.broadcast)), "authenticatedSignedWrites": .bool(p.contains(.authenticatedSignedWrites)),
                                                  "reliableWrite": .bool(false), "writableAuxiliaries": .bool(false)])])
        }
        finish(id, .success(.array(values)))
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let id = deviceID(peripheral), let handle = characteristics.first(where: { $0.value === characteristic })?.key else { return }
        let value = JSONValue.string((characteristic.value ?? Data()).base64EncodedString())
        let completesRead = active[id]?.method == "ble.read" && active[id]?.args["characteristic"]?.string == handle
        if completesRead {
            finish(id, error.map { .failure(WebError.wrapping($0)) } ?? .success(value))
        }
        // readValue() updates the JavaScript value and fires its own event.
        if error == nil, characteristic.isNotifying, !completesRead {
            onEvent?("ble.value", .object(["characteristic": .string(handle), "value": value]))
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let id = deviceID(peripheral), let op = active[id],
              ["ble.write", "ble.writeWithResponse"].contains(op.method),
              characteristics[op.args["characteristic"]?.string ?? ""] === characteristic else { return }
        finish(id, error.map { .failure(WebError.wrapping($0)) } ?? .success(.null))
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard let id = deviceID(peripheral), let op = active[id],
              ["ble.startNotifications", "ble.stopNotifications"].contains(op.method),
              characteristics[op.args["characteristic"]?.string ?? ""] === characteristic else { return }
        finish(id, error.map { .failure(WebError.wrapping($0)) } ?? .success(.null))
    }
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard let id = deviceID(peripheral), let op = active[id],
              ["ble.write", "ble.writeWithoutResponse"].contains(op.method),
              let characteristic = characteristics[op.args["characteristic"]?.string ?? ""],
              op.method == "ble.writeWithoutResponse" || !characteristic.properties.contains(.write),
              peripheral.canSendWriteWithoutResponse else { return }
        do {
            let bytes = try op.args.data("data", maximum: 512)
            peripheral.writeValue(bytes, for: characteristic, type: .withoutResponse)
            finish(id, .success(.null))
        } catch { finish(id, .failure(WebError.wrapping(error))) }
    }
    func reset() {
        stopScan()
        for (id, peripheral) in devices {
            if peripheral.state != .disconnected { central?.cancelPeripheralConnection(peripheral) }
            disconnected(id, error: .aborted)
            peripheral.delegate = nil
        }
        devices.removeAll(); discovered.removeAll(); grants.removeAll()
        services.removeAll(); characteristics.removeAll()
    }
    private func deviceID(_ peripheral: CBPeripheral) -> String? {
        devices.first { $0.value === peripheral }?.key
    }
    private func uuid(_ value: CBUUID) -> String {
        (try? BluetoothUUID.canonical(.string(value.uuidString))) ?? value.uuidString.lowercased()
    }
}
