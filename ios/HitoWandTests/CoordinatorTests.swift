import Foundation
import Testing
@testable import HitoWand

@MainActor
struct CoordinatorTests {
    let origin = SiteOrigin(scheme: "https", host: "wallet.example", port: 443)
    func body(_ coordinator: HardwareCoordinator, op: String, args: JSONObject = [:], id: String = UUID().uuidString) -> Any {
        ["id": id, "token": coordinator.document.token, "op": op, "args": args.mapValues(\.foundation)]
    }
    func ticks() async { for _ in 0..<20 { await Task.yield() } }

    @Test func directMessagesCannotBypassOriginAndFrameChecks() async {
        let ble = TestBluetooth(), nfc = TestNFC()
        let coordinator = HardwareCoordinator(bluetooth: ble, nfc: nfc)
        coordinator.committed(URL(string: "https://wallet.example"))
        var denied = 0
        let callback: PendingReplies.Reply = { value, _ in
            if ((value as? [String: Any])?["error"] as? [String: Any])?["name"] as? String == "SecurityError" { denied += 1 }
        }
        let request = body(coordinator, op: "ble.requestDevice", args: ["acceptAllDevices": .bool(true)])
        coordinator.receive(request, origin: origin, mainFrame: false, reply: callback)
        coordinator.receive(request, origin: .init(scheme: "https", host: "attacker.example", port: 443), mainFrame: true, reply: callback)
        coordinator.receive(request, origin: .init(scheme: "http", host: "wallet.example", port: 80), mainFrame: true, reply: callback)
        coordinator.setForeground(false)
        coordinator.receive(request, origin: origin, mainFrame: true, reply: callback)
        coordinator.setForeground(true)
        coordinator.receive(request, origin: origin, mainFrame: true, reply: callback)
        await ticks()
        #expect(denied == 5)
        #expect(ble.scanCount == 0)
    }

    @Test func navigationCancelsPickerAndCannotGrantTheNextDocument() async {
        let ble = TestBluetooth()
        let coordinator = HardwareCoordinator(bluetooth: ble, nfc: TestNFC())
        coordinator.committed(URL(string: "https://wallet.example"))
        var replies = 0
        coordinator.receive(body(coordinator, op: "ble.requestDevice", args: ["acceptAllDevices": .bool(true)]),
                            origin: origin, mainFrame: true) { _, _ in replies += 1 }
        await ticks()
        #expect(coordinator.picker != nil)
        coordinator.navigationStarted()
        coordinator.committed(URL(string: "https://wallet.example"))
        coordinator.selectDevice("test-device")
        await ticks()
        #expect(replies == 1)
        #expect(coordinator.picker == nil)
        #expect(coordinator.allowedDevices.isEmpty)
        #expect(!ble.granted)
    }

    @Test func revocationCancelsPendingGATTExactlyOnce() async {
        let ble = TestBluetooth()
        ble.granted = true; ble.holdReads = true
        let coordinator = HardwareCoordinator(bluetooth: ble, nfc: TestNFC())
        coordinator.committed(URL(string: "https://wallet.example"))
        var replies = 0, errorName = ""
        coordinator.receive(body(coordinator, op: "ble.read", args: ["characteristic": .string("test-characteristic")]),
                            origin: origin, mainFrame: true) { value, _ in
            replies += 1
            errorName = ((value as? [String: Any])?["error"] as? [String: Any])?["name"] as? String ?? ""
        }
        await ticks()
        coordinator.revoke()
        await ticks()
        #expect(replies == 1)
        #expect(errorName == "AbortError")
        #expect(!ble.granted)
    }

    @Test func abortDuringNFCPermissionDoesNotStartHardware() async {
        let nfc = TestNFC()
        let coordinator = HardwareCoordinator(bluetooth: TestBluetooth(), nfc: nfc)
        coordinator.committed(URL(string: "https://wallet.example"))
        let id = UUID().uuidString
        var replies = 0
        coordinator.receive(body(coordinator, op: "nfc.scan", args: ["reader": .string("reader")], id: id),
                            origin: origin, mainFrame: true) { _, _ in replies += 1 }
        await ticks()
        #expect(coordinator.permission != nil)
        coordinator.receive(body(coordinator, op: "cancel", args: ["target": .string(id)]),
                            origin: origin, mainFrame: true) { _, _ in }
        coordinator.resolvePermission(true)
        await ticks()
        #expect(replies == 1)
        #expect(nfc.scans.isEmpty)
        #expect(!coordinator.hasNFCGrant)
    }

    @Test func nfcPermissionIsVisitScopedAndScanCanBeRestarted() async {
        let nfc = TestNFC()
        let coordinator = HardwareCoordinator(bluetooth: TestBluetooth(), nfc: nfc)
        coordinator.committed(URL(string: "https://wallet.example"))
        coordinator.receive(body(coordinator, op: "nfc.scan", args: ["reader": .string("reader")]),
                            origin: origin, mainFrame: true) { _, _ in }
        await ticks()
        coordinator.resolvePermission(true)
        await ticks()
        #expect(nfc.scans.count == 1)
        #expect(coordinator.hasNFCGrant)
        nfc.onStatus?("NFC scan ended", true)
        coordinator.restartNFC()
        #expect(nfc.restarts == 1)
        coordinator.setForeground(false)
        #expect(!coordinator.hasNFCGrant)
        coordinator.restartNFC()
        #expect(nfc.restarts == 1)
    }

    @Test func reusedRequestIDCannotReceiveAnotherDocumentsCompletion() async {
        let ble = TestBluetooth(), nfc = TestNFC()
        ble.granted = true; ble.holdReads = true
        let coordinator = HardwareCoordinator(bluetooth: ble, nfc: nfc)
        coordinator.committed(URL(string: "https://wallet.example"))
        let id = UUID().uuidString
        var oldReplies = 0, newReplies = 0
        coordinator.receive(body(coordinator, op: "ble.read", args: ["characteristic": .string("test-characteristic")], id: id),
                            origin: origin, mainFrame: true) { _, _ in oldReplies += 1 }
        await ticks()
        coordinator.revoke()
        coordinator.receive(body(coordinator, op: "nfc.scan", args: ["reader": .string("reader")], id: id),
                            origin: origin, mainFrame: true) { _, _ in newReplies += 1 }
        await ticks()
        #expect(oldReplies == 1)
        #expect(newReplies == 0)
        #expect(coordinator.permission != nil)
        coordinator.resolvePermission(true)
        await ticks()
        #expect(newReplies == 1)
    }
}
