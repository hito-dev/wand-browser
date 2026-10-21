import Foundation

enum BluetoothUUID {
    static func canonical(_ value: JSONValue) throws -> String {
        if let number = value.number, number.isFinite, number >= 0,
           number <= Double(UInt32.max), number.rounded() == number {
            return String(format: "%08x-0000-1000-8000-00805f9b34fb", UInt32(number))
        }
        guard let string = value.string else { throw WebError("TypeError", "Invalid Bluetooth UUID.") }
        if string.count == 4 || string.count == 8, let number = UInt32(string, radix: 16) {
            return String(format: "%08x-0000-1000-8000-00805f9b34fb", number)
        }
        guard let uuid = UUID(uuidString: string) else {
            throw WebError("NotSupportedError", "Use a numeric or canonical UUID; symbolic names are not supported.")
        }
        return uuid.uuidString.lowercased()
    }
}

enum GATTBlocklist {
    // WebBluetoothCG/registries/gatt_blocklist.txt, retrieved 2026-10-20.
    // Data entries only: https://github.com/WebBluetoothCG/registries/blob/master/gatt_blocklist.txt
    static let excluded: Set<String> = [
        "00001812-0000-1000-8000-00805f9b34fb",
        "00001530-1212-efde-1523-785feabcd123",
        "f000ffc0-0451-4000-b000-000000000000",
        "00060000-0000-1000-8000-00805f9b34fb",
        "0000fffd-0000-1000-8000-00805f9b34fb",
        "0000fff9-0000-1000-8000-00805f9b34fb",
        "0000fde2-0000-1000-8000-00805f9b34fb",
        "00002a03-0000-1000-8000-00805f9b34fb",
        "00002a25-0000-1000-8000-00805f9b34fb"
    ]
    static let excludedWrites: Set<String> = [
        "00002a02-0000-1000-8000-00805f9b34fb",
        "00002902-0000-1000-8000-00805f9b34fb",
        "00002903-0000-1000-8000-00805f9b34fb"
    ]
    static func check(_ uuid: String, writing: Bool = false) throws {
        guard !excluded.contains(uuid), !(writing && excludedWrites.contains(uuid)) else {
            throw WebError("SecurityError", "Access to this Bluetooth UUID is blocked.")
        }
    }
}

struct BluetoothFilter: Sendable {
    let name: String?
    let prefix: String?
    let services: Set<String>
    func matches(name: String?, advertisedServices: Set<String>) -> Bool {
        if let expected = self.name, name != expected { return false }
        if let prefix, !(name?.hasPrefix(prefix) ?? false) { return false }
        return services.isSubset(of: advertisedServices)
    }
}

struct BluetoothRequestOptions: Sendable {
    let filters: [BluetoothFilter]
    let acceptAll: Bool
    let allowedServices: Set<String>

    init(_ args: JSONObject) throws {
        try args.rejectUnknown(["filters", "optionalServices", "acceptAllDevices"])
        if let all = args["acceptAllDevices"], all.bool == nil {
            throw WebError("TypeError", "acceptAllDevices must be a boolean.")
        }
        acceptAll = args["acceptAllDevices"]?.bool ?? false
        let input = args["filters"]?.array
        guard acceptAll ? args["filters"] == nil : !(input?.isEmpty ?? true) else {
            throw WebError("TypeError", "Supply nonempty filters or acceptAllDevices, exclusively.")
        }
        guard (input?.count ?? 0) <= 32 else { throw WebError("TypeError", "Too many filters.") }
        filters = try (input ?? []).map { value in
            guard let filter = value.object else { throw WebError("TypeError", "Invalid device filter.") }
            try filter.rejectUnknown(["name", "namePrefix", "services"])
            guard !filter.isEmpty else { throw WebError("TypeError", "Device filters cannot be empty.") }
            let name = try filter["name"].map { value -> String in
                guard let name = value.string, name.utf8.count <= 248 else { throw WebError("TypeError", "Invalid name.") }
                return name
            }
            let prefix = try filter["namePrefix"].map { value -> String in
                guard let prefix = value.string, !prefix.isEmpty, prefix.utf8.count <= 248 else { throw WebError("TypeError", "Invalid name prefix.") }
                return prefix
            }
            let services = try Self.services(filter["services"])
            if filter["services"] != nil, services.isEmpty { throw WebError("TypeError", "Service filters cannot be empty.") }
            return BluetoothFilter(name: name, prefix: prefix, services: services)
        }
        allowedServices = try filters.reduce(into: Self.services(args["optionalServices"])) { result, filter in
            result.formUnion(filter.services)
        }
    }
    private static func services(_ value: JSONValue?) throws -> Set<String> {
        guard let value else { return [] }
        guard let list = value.array, list.count <= 64 else { throw WebError("TypeError", "Invalid service list.") }
        return try Set(list.map {
            let uuid = try BluetoothUUID.canonical($0)
            try GATTBlocklist.check(uuid)
            return uuid
        })
    }
    func matches(name: String?, services: Set<String>) -> Bool {
        acceptAll || filters.contains { $0.matches(name: name, advertisedServices: services) }
    }
}

struct DiscoveredDevice: Identifiable, Sendable {
    let id: String
    let name: String
    let rssi: Int
}

@MainActor
protocol BluetoothTransport: AnyObject {
    var onDiscovery: (([DiscoveredDevice], String) -> Void)? { get set }
    var onScanError: ((WebError) -> Void)? { get set }
    var onEvent: ((String, JSONValue) -> Void)? { get set }
    func startScan(options: BluetoothRequestOptions)
    func stopScan()
    func grant(id: String, services: Set<String>) throws -> JSONValue
    func perform(_ method: String, args: JSONObject) async throws -> JSONValue
    func reset()
}

@MainActor
protocol NFCTransport: AnyObject {
    var onEvent: ((String, JSONValue) -> Void)? { get set }
    var onStatus: ((String, Bool) -> Void)? { get set }
    func scan(reader: String, request: String) async throws
    func write(reader: String, request: String, records: [NDEFRecord], overwrite: Bool) async throws
    func cancel(request: String)
    func restart() throws
    func reset()
}
