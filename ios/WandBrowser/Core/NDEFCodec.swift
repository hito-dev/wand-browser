import Foundation
import CoreNFC

/// A transport-neutral record. Data is the Web NFC payload, without RTD headers.
struct NDEFRecord: Equatable, Sendable {
    let type: String
    let id: String
    let data: Data
    let mediaType: String?
    let encoding: String?
    let language: String?

    init(type: String, id: String = "", data: Data = Data(), mediaType: String? = nil,
         encoding: String? = nil, language: String? = nil) {
        self.type = type; self.id = id; self.data = data
        self.mediaType = mediaType; self.encoding = encoding; self.language = language
    }
    init(_ value: JSONValue) throws {
        guard let args = value.object else { throw WebError("TypeError", "Invalid NDEF record.") }
        try args.rejectUnknown(["recordType", "id", "data", "mediaType", "encoding", "lang"])
        for key in ["id", "mediaType", "encoding", "lang"] {
            if let value = args[key], value.string == nil { throw WebError("TypeError", "Invalid \(key).") }
        }
        self.init(type: try args.requiredString("recordType"),
                  id: args["id"]?.string ?? "", data: try args.data("data"),
                  mediaType: args["mediaType"]?.string, encoding: args["encoding"]?.string,
                  language: args["lang"]?.string)
        _ = try payload()
    }
    var json: JSONValue {
        .object([
            "recordType": .string(type), "id": .string(id), "data": .string(data.base64EncodedString()),
            "mediaType": mediaType.map(JSONValue.string) ?? .null,
            "encoding": encoding.map(JSONValue.string) ?? .null,
            "lang": language.map(JSONValue.string) ?? .null
        ])
    }
    func payload() throws -> NFCNDEFPayload {
        guard id.utf8.count <= 255, data.count <= 65_536 else {
            throw WebError("TypeError", "NDEF record is too large.")
        }
        var format: NFCTypeNameFormat
        var typeBytes = Data()
        var bytes = data
        switch type {
        case "empty":
            guard data.isEmpty, id.isEmpty else { throw WebError("TypeError", "Empty records cannot contain data or an ID.") }
            format = .empty
        case "text":
            let encoding = encoding ?? "utf-8"
            let language = language ?? "en"
            guard ["utf-8", "utf-16"].contains(encoding), !language.isEmpty,
                  language.utf8.count <= 63, language.utf8.allSatisfy({ $0 < 128 }) else {
                throw WebError("TypeError", "Invalid NDEF text encoding or language.")
            }
            format = .nfcWellKnown
            typeBytes = Data("T".utf8)
            bytes = Data([UInt8(language.utf8.count) | (encoding == "utf-16" ? 0x80 : 0)])
            bytes.append(Data(language.utf8)); bytes.append(data)
        case "url", "absolute-url":
            guard let url = String(data: data, encoding: .utf8),
                  let components = URLComponents(string: url), components.scheme != nil else {
                throw WebError("SyntaxError", "NDEF URLs must be absolute.")
            }
            if type == "url" {
                format = .nfcWellKnown; typeBytes = Data("U".utf8)
                bytes = Data([0]); bytes.append(data)
            } else {
                format = .absoluteURI; typeBytes = data; bytes = Data()
            }
        case "mime":
            let mime = mediaType ?? "application/octet-stream"
            guard mime.utf8.count <= 255,
                  mime.range(of: #"^[A-Za-z0-9!#$&^_.+-]+/[A-Za-z0-9!#$&^_.+-]+$"#, options: .regularExpression) != nil else {
                throw WebError("SyntaxError", "Invalid MIME type.")
            }
            format = .media; typeBytes = Data(mime.lowercased().utf8)
        case "unknown":
            format = .unknown
        default:
            guard type.utf8.count <= 255,
                  type.range(of: #"^[a-z0-9][a-z0-9.-]*:[a-z0-9][a-z0-9._~!$&'()*+,;=:@%-]*$"#, options: .regularExpression) != nil else {
                throw WebError("NotSupportedError", "This NDEF record type is not supported.")
            }
            format = .nfcExternal; typeBytes = Data(type.utf8)
        }
        guard typeBytes.count <= 255 else { throw WebError("TypeError", "NDEF type is too long.") }
        return NFCNDEFPayload(format: format, type: typeBytes, identifier: Data(id.utf8), payload: bytes)
    }

    static func decode(_ payload: NFCNDEFPayload) throws -> NDEFRecord {
        let id = String(decoding: payload.identifier, as: UTF8.self)
        let type = String(decoding: payload.type, as: UTF8.self)
        switch payload.typeNameFormat {
        case .empty: return NDEFRecord(type: "empty")
        case .media: return NDEFRecord(type: "mime", id: id, data: payload.payload, mediaType: type)
        case .absoluteURI: return NDEFRecord(type: "absolute-url", id: id, data: payload.type)
        case .nfcExternal: return NDEFRecord(type: type.lowercased(), id: id, data: payload.payload)
        case .unknown: return NDEFRecord(type: "unknown", id: id, data: payload.payload)
        case .nfcWellKnown:
            if type == "T", let status = payload.payload.first {
                let length = Int(status & 0x3f)
                guard payload.payload.count >= length + 1,
                      let language = String(data: payload.payload.subdata(in: 1..<(length + 1)), encoding: .ascii) else {
                    throw WebError("NotReadableError", "Malformed NDEF text record.")
                }
                return NDEFRecord(type: "text", id: id, data: payload.payload.dropFirst(length + 1),
                                  encoding: status & 0x80 == 0 ? "utf-8" : "utf-16", language: language)
            }
            if type == "U", let code = payload.payload.first, Int(code) < uriPrefixes.count,
               let suffix = String(data: payload.payload.dropFirst(), encoding: .utf8) {
                return NDEFRecord(type: "url", id: id, data: Data((uriPrefixes[Int(code)] + suffix).utf8))
            }
            throw WebError("NotSupportedError", "Unsupported or malformed NDEF well-known record.")
        default:
            throw WebError("NotSupportedError", "Unsupported NDEF record format.")
        }
    }
    private static let uriPrefixes = [
        "", "http://www.", "https://www.", "http://", "https://", "tel:", "mailto:",
        "ftp://anonymous:anonymous@", "ftp://ftp.", "ftps://", "sftp://", "smb://", "nfs://",
        "ftp://", "dav://", "news:", "telnet://", "imap:", "rtsp://", "urn:", "pop:", "sip:",
        "sips:", "tftp:", "btspp://", "btl2cap://", "btgoep://", "tcpobex://", "irdaobex://",
        "file://", "urn:epc:id:", "urn:epc:tag:", "urn:epc:pat:", "urn:epc:raw:", "urn:epc:", "urn:nfc:"
    ]
}
