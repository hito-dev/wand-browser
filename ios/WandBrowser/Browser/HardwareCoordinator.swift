import Combine
import Foundation
import WebKit

struct DevicePickerState: Identifiable {
    let id: String
    let origin: String
    let services: [String]
    var devices: [DiscoveredDevice] = []
    var status = "Looking for nearby devices…"
}

struct SitePermission: Identifiable {
    let id: String
    let origin: String
}

struct SiteDevice: Identifiable {
    let id: String
    let name: String
    var connected = false
}

@MainActor
final class HardwareCoordinator: NSObject, ObservableObject, WKScriptMessageHandlerWithReply {
    @Published var picker: DevicePickerState?
    @Published var permission: SitePermission?
    @Published private(set) var allowedDevices: [SiteDevice] = []
    @Published private(set) var nfcStatus = "NFC idle"
    @Published private(set) var canRestartNFC = false
    @Published private(set) var hasNFCGrant = false
    @Published private(set) var originLabel = "No secure site open"
    @Published var notice: String?

    private(set) var document = DocumentSession()
    private(set) var foreground = true
    weak var webView: WKWebView?
    let bluetooth: any BluetoothTransport
    let nfc: any NFCTransport
    private let replies = PendingReplies()
    private var tasks: [String: Task<Void, Never>] = [:]
    private var selection: (String, BluetoothRequestOptions, CheckedContinuation<JSONValue, Error>)?
    private var approval: (String, CheckedContinuation<Void, Error>)?
    private var committedURL: URL?

    init(bluetooth: any BluetoothTransport = CoreBluetoothTransport(), nfc: any NFCTransport = CoreNFCTransport()) {
        self.bluetooth = bluetooth; self.nfc = nfc
        super.init()
        bluetooth.onDiscovery = { [weak self] devices, status in
            self?.picker?.devices = devices; self?.picker?.status = status
        }
        bluetooth.onScanError = { [weak self] error in self?.picker?.status = error.message }
        bluetooth.onEvent = { [weak self] event, value in
            guard let self else { return }
            if event == "ble.disconnected", let id = value.object?["device"]?.string,
               let index = self.allowedDevices.firstIndex(where: { $0.id == id }) {
                self.allowedDevices[index].connected = false
            }
            self.send(event, value)
        }
        nfc.onEvent = { [weak self] event, value in self?.send(event, value) }
        nfc.onStatus = { [weak self] status, restart in
            self?.nfcStatus = status; self?.canRestartNFC = restart
        }
    }

    func navigationStarted() {
        committedURL = nil
        invalidate()
    }
    func committed(_ url: URL?) {
        committedURL = url
        activate()
    }
    private func activate() {
        guard foreground, let url = committedURL, let origin = SiteOrigin(url: url), origin.scheme == "https" else {
            originLabel = committedURL.flatMap(SiteOrigin.init(url:))?.display ?? "No secure site open"
            return
        }
        document.activate(origin: origin)
        originLabel = origin.display
        webView?.callAsyncJavaScript("window.__hitoWand?.initialize(token)", arguments: ["token": document.token],
                                    in: nil, in: .page, completionHandler: nil)
    }
    func setForeground(_ active: Bool) {
        guard foreground != active else { return }
        foreground = active
        if active { activate() } else { invalidate() }
    }
    func revoke() {
        invalidate()
        activate()
    }
    func invalidate() {
        send("reset", .null)
        document.invalidate()
        tasks.values.forEach { $0.cancel() }; tasks.removeAll()
        replies.cancelAll()
        cancelSelection()
        resolvePermission(false)
        bluetooth.reset(); nfc.reset()
        allowedDevices.removeAll(); hasNFCGrant = false
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        let frame = message.frameInfo
        let origin = SiteOrigin(scheme: frame.securityOrigin.protocol, host: frame.securityOrigin.host, port: frame.securityOrigin.port)
        receive(message.body, origin: origin, mainFrame: frame.isMainFrame, reply: replyHandler)
    }
    // Shared by WKWebView and tests: adapter injection never bypasses origin policy.
    func receive(_ body: Any, origin: SiteOrigin, mainFrame: Bool, reply: @escaping PendingReplies.Reply) {
        do {
            let request = try BridgeRequest.parse(body)
            try document.validate(token: request.token, origin: origin, mainFrame: mainFrame, foreground: foreground)
            if request.op == "cancel" {
                let target = try request.args.requiredString("target")
                cancel(target)
                reply(["ok": NSNull()], nil)
                return
            }
            // IDs are website-controlled. Include the native document capability so a
            // late task cannot complete a new document's request with a reused ID.
            let key = request.token + ":" + request.id
            try replies.insert(key, reply: reply)
            tasks[key] = Task { [weak self] in
                guard let self else { return }
                do {
                    try Task.checkCancellation()
                    let value = try await self.execute(request)
                    try Task.checkCancellation()
                    guard self.document.token == request.token else { throw WebError.aborted }
                    self.replies.finish(key, .success(value))
                } catch { self.replies.finish(key, .failure(WebError.wrapping(error))) }
                self.tasks.removeValue(forKey: key)
            }
        } catch {
            reply(["error": WebError.wrapping(error).json.foundation], nil)
        }
    }
    private func execute(_ request: BridgeRequest) async throws -> JSONValue {
        switch request.op {
        case "ble.requestDevice":
            guard selection == nil, approval == nil else { throw WebError("InvalidStateError", "A hardware prompt is already open.") }
            let options = try BluetoothRequestOptions(request.args)
            return try await withCheckedThrowingContinuation { continuation in
                selection = (request.id, options, continuation)
                picker = DevicePickerState(id: request.id, origin: originLabel, services: options.allowedServices.sorted())
                bluetooth.startScan(options: options)
            }
        case "ble.connect", "ble.disconnect", "ble.services", "ble.characteristics", "ble.read",
             "ble.write", "ble.writeWithResponse", "ble.writeWithoutResponse", "ble.startNotifications", "ble.stopNotifications":
            let result = try await bluetooth.perform(request.op, args: request.args)
            if request.op == "ble.connect", let id = request.args["device"]?.string,
               let index = allowedDevices.firstIndex(where: { $0.id == id }) {
                allowedDevices[index].connected = true
            }
            return result
        case "nfc.scan":
            try request.args.rejectUnknown(["reader"])
            let reader = try request.args.requiredString("reader")
            try await approveNFC(request.id)
            try Task.checkCancellation()
            try await nfc.scan(reader: reader, request: request.id)
            return .null
        case "nfc.write":
            try request.args.rejectUnknown(["reader", "records", "overwrite"])
            let reader = try request.args.requiredString("reader")
            guard let values = request.args["records"]?.array, !values.isEmpty, values.count <= 64,
                  let overwrite = request.args["overwrite"]?.bool else { throw WebError("TypeError", "Invalid NFC write.") }
            let records = try values.map(NDEFRecord.init)
            try await approveNFC(request.id)
            try Task.checkCancellation()
            try await nfc.write(reader: reader, request: request.id, records: records, overwrite: overwrite)
            return .null
        default: throw WebError("NotSupportedError", "Unsupported hardware operation.")
        }
    }
    func selectDevice(_ id: String) {
        guard let (_, options, continuation) = selection else { return }
        do {
            let value = try bluetooth.grant(id: id, services: options.allowedServices)
            selection = nil; picker = nil; bluetooth.stopScan()
            if !allowedDevices.contains(where: { $0.id == id }) {
                allowedDevices.append(SiteDevice(id: id, name: value.object?["name"]?.string ?? "Device"))
            }
            continuation.resume(returning: value)
        } catch {
            picker?.status = error.localizedDescription
        }
    }
    func retryScan() {
        guard let (_, options, _) = selection else { return }
        bluetooth.startScan(options: options)
    }
    func cancelSelection() {
        guard let (_, _, continuation) = selection else { picker = nil; return }
        selection = nil; picker = nil; bluetooth.stopScan()
        continuation.resume(throwing: WebError("NotFoundError", "No Bluetooth device was selected."))
    }
    private func approveNFC(_ id: String) async throws {
        if hasNFCGrant { return }
        guard selection == nil, approval == nil else { throw WebError("InvalidStateError", "A hardware prompt is already open.") }
        try await withCheckedThrowingContinuation { continuation in
            approval = (id, continuation)
            permission = SitePermission(id: id, origin: originLabel)
        }
    }
    func resolvePermission(_ allow: Bool) {
        guard let (_, continuation) = approval else { permission = nil; return }
        approval = nil; permission = nil
        if allow { hasNFCGrant = true; continuation.resume() }
        else { continuation.resume(throwing: WebError("NotAllowedError", "NFC permission was not granted.")) }
    }
    private func cancel(_ id: String) {
        let key = document.token + ":" + id
        tasks[key]?.cancel()
        replies.finish(key, .failure(.aborted))
        if selection?.0 == id { cancelSelection() }
        if approval?.0 == id { resolvePermission(false) }
        nfc.cancel(request: id)
    }
    func disconnect(_ id: String) {
        Task {
            do { _ = try await bluetooth.perform("ble.disconnect", args: ["device": .string(id)]) }
            catch { notice = error.localizedDescription }
        }
    }
    func restartNFC() {
        guard foreground, document.active, hasNFCGrant else { return }
        do { try nfc.restart() } catch { notice = error.localizedDescription }
    }
    private func send(_ event: String, _ value: JSONValue) {
        guard document.active else { return }
        webView?.callAsyncJavaScript("window.__hitoWand?.receive(token, event, value)",
                                    arguments: ["token": document.token, "event": event, "value": value.foundation],
                                    in: nil, in: .page, completionHandler: nil)
    }
}
