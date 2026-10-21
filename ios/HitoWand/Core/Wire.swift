import Foundation

enum JSONValue: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String)
    case array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(Double.self) { self = .number(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try value.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .string(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .object(let v): try value.encode(v)
        }
    }

    var foundation: Any {
        switch self {
        case .null: NSNull()
        case .bool(let v): v
        case .number(let v): v
        case .string(let v): v
        case .array(let v): v.map(\.foundation)
        case .object(let v): v.mapValues(\.foundation)
        }
    }
    var string: String? { if case .string(let v) = self { v } else { nil } }
    var array: [JSONValue]? { if case .array(let v) = self { v } else { nil } }
    var object: [String: JSONValue]? { if case .object(let v) = self { v } else { nil } }
    var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
    var number: Double? { if case .number(let v) = self { v } else { nil } }
}

typealias JSONObject = [String: JSONValue]

extension Dictionary where Key == String, Value == JSONValue {
    func requiredString(_ key: String) throws -> String {
        guard let value = self[key]?.string, !value.isEmpty, value.utf8.count <= 4096 else {
            throw WebError("TypeError", "Missing or invalid \(key).")
        }
        return value
    }
    func data(_ key: String, maximum: Int = 131_072) throws -> Data {
        guard let text = self[key]?.string, text.count <= maximum * 2,
              let bytes = Data(base64Encoded: text), bytes.count <= maximum else {
            throw WebError("TypeError", "Invalid or oversized binary data.")
        }
        return bytes
    }
    func rejectUnknown(_ supported: Set<String>) throws {
        if !Set(keys).isSubset(of: supported) {
            throw WebError("NotSupportedError", "This request contains unsupported options.")
        }
    }
}

struct WebError: Error, Equatable, Sendable, LocalizedError {
    let name: String
    let message: String
    init(_ name: String, _ message: String) { self.name = name; self.message = message }
    var errorDescription: String? { message }
    var json: JSONValue { .object(["name": .string(name), "message": .string(message)]) }
    static let aborted = WebError("AbortError", "The operation was cancelled.")
    static let disconnected = WebError("NetworkError", "The Bluetooth device is disconnected.")
    static func wrapping(_ error: Error) -> WebError {
        if let error = error as? WebError { return error }
        if error is CancellationError { return .aborted }
        return WebError("NetworkError", error.localizedDescription)
    }
}

struct BridgeRequest: Decodable, Sendable {
    let id: String
    let token: String
    let op: String
    let args: JSONObject

    static func parse(_ body: Any) throws -> BridgeRequest {
        guard JSONSerialization.isValidJSONObject(body) else {
            throw WebError("TypeError", "Expected a request object.")
        }
        let data = try JSONSerialization.data(withJSONObject: body)
        guard data.count <= 262_144 else { throw WebError("QuotaExceededError", "Request too large.") }
        let request: BridgeRequest
        do { request = try JSONDecoder().decode(BridgeRequest.self, from: data) }
        catch { throw WebError("TypeError", "Invalid request envelope.") }
        guard UUID(uuidString: request.id) != nil, UUID(uuidString: request.token) != nil,
              request.op.count <= 64 else { throw WebError("TypeError", "Invalid request envelope.") }
        return request
    }
}

struct SiteOrigin: Equatable, Sendable {
    let scheme: String
    let host: String
    let port: Int
    init(scheme: String, host: String, port: Int) {
        self.scheme = scheme.lowercased()
        self.host = host.lowercased()
        self.port = port == 0 ? (scheme.lowercased() == "https" ? 443 : 80) : port
    }
    init?(url: URL) {
        guard let scheme = url.scheme, let host = url.host, !host.isEmpty else { return nil }
        self.init(scheme: scheme, host: host, port: url.port ?? 0)
    }
    var display: String {
        let displayHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "\(scheme)://\(displayHost)" + (port == 443 && scheme == "https" || port == 80 && scheme == "http" ? "" : ":\(port)")
    }
}

/// A capability for one committed document. Never accept a website's claimed origin.
struct DocumentSession {
    private(set) var token = UUID().uuidString
    private(set) var origin: SiteOrigin?
    private(set) var active = false

    mutating func activate(origin: SiteOrigin) {
        token = UUID().uuidString
        self.origin = origin
        active = origin.scheme == "https"
    }
    mutating func invalidate() { token = UUID().uuidString; origin = nil; active = false }
    func validate(token: String, origin: SiteOrigin, mainFrame: Bool, foreground: Bool) throws {
        guard mainFrame, foreground, active, origin.scheme == "https",
              self.origin == origin, self.token == token else {
            throw WebError("SecurityError", "Hardware access requires the current foreground HTTPS document.")
        }
    }
}

@MainActor
final class PendingReplies {
    typealias Reply = (Any?, String?) -> Void
    private var replies: [String: Reply] = [:]
    var count: Int { replies.count }
    func insert(_ id: String, reply: @escaping Reply) throws {
        guard replies[id] == nil else { throw WebError("InvalidStateError", "Duplicate request.") }
        guard replies.count < 64 else { throw WebError("QuotaExceededError", "Too many pending requests.") }
        replies[id] = reply
    }
    func finish(_ id: String, _ result: Result<JSONValue, WebError>) {
        guard let reply = replies.removeValue(forKey: id) else { return }
        switch result {
        case .success(let value): reply(["ok": value.foundation], nil)
        case .failure(let error): reply(["error": error.json.foundation], nil)
        }
    }
    func cancelAll() {
        for id in Array(replies.keys) { finish(id, .failure(.aborted)) }
    }
}
