import Foundation
@testable import HitoWand

@MainActor
final class TestBluetooth: BluetoothTransport {
    var onDiscovery: (([DiscoveredDevice], String) -> Void)?
    var onScanError: ((WebError) -> Void)?
    var onEvent: ((String, JSONValue) -> Void)?
    var calls: [String] = []
    var scanCount = 0
    var granted = false
    var holdReads = false
    private var read: CheckedContinuation<JSONValue, Error>?
    func startScan(options: BluetoothRequestOptions) {
        scanCount += 1
        onDiscovery?([DiscoveredDevice(id: "test-device", name: "Hito test wallet", rssi: -40)], "Choose a device.")
    }
    func stopScan() {}
    func grant(id: String, services: Set<String>) throws -> JSONValue {
        granted = true
        return .object(["id": .string(id), "name": .string("Hito test wallet")])
    }
    func perform(_ method: String, args: JSONObject) async throws -> JSONValue {
        calls.append(method)
        guard granted else { throw WebError("SecurityError", "No device grant.") }
        switch method {
        case "ble.services":
            return .array([.object(["id": .string("test-service"), "device": .string("test-device"),
                                   "uuid": .string("5cc44b16-070a-11ed-b939-0242ac120002"), "isPrimary": .bool(true)])])
        case "ble.characteristics":
            return .array([.object(["id": .string("test-characteristic"), "service": .string("test-service"),
                                   "uuid": .string("5cc44b17-070a-11ed-b939-0242ac120002"),
                                   "properties": .object(["read": .bool(true), "writeWithoutResponse": .bool(true), "notify": .bool(true)])])])
        case "ble.read":
            if holdReads { return try await withCheckedThrowingContinuation { read = $0 } }
            return .string(Data([0, 1, 255]).base64EncodedString())
        case "ble.disconnect": onEvent?("ble.disconnected", .object(["device": .string("test-device")]))
        default: break
        }
        return .null
    }
    func reset() { granted = false; read?.resume(throwing: WebError.aborted); read = nil }
}

@MainActor
final class TestNFC: NFCTransport {
    var onEvent: ((String, JSONValue) -> Void)?
    var onStatus: ((String, Bool) -> Void)?
    var scans: [String] = []
    var cancelled: [String] = []
    var writes: [[NDEFRecord]] = []
    var restarts = 0
    func scan(reader: String, request: String) async throws { scans.append(request); onStatus?("NFC scanning", false) }
    func write(reader: String, request: String, records: [NDEFRecord], overwrite: Bool) async throws { writes.append(records) }
    func cancel(request: String) { cancelled.append(request) }
    func restart() throws { restarts += 1 }
    func reset() { scans.removeAll() }
}
