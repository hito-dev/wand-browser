import Foundation
import Testing
import WebKit
import UIKit
@testable import HitoWand

/// Uses an actual WKWebView, trusted local TLS, and the production message handler.
/// Only the radio adapters are replaced. Start scripts/serve-fixtures.mjs first.
@MainActor
@Suite(.serialized)
struct WebViewTests {
    var fixtureBase: URL {
        let value = ProcessInfo.processInfo.environment["WAND_FIXTURE_URL"] ?? ""
        return URL(string: value.hasPrefix("https://") ? value : "https://localhost:18443/")!
    }
    func host(_ browser: BrowserModel) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        controller.view = browser.webView
        window.rootViewController = controller
        window.makeKeyAndVisible()
        return window
    }
    func evaluate(_ web: WKWebView, _ script: String, arguments: [String: Any] = [:]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            web.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { result in
                switch result {
                case .success(let value): continuation.resume(returning: value as? String ?? "")
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }
    func open(_ browser: BrowserModel, path: String = "bridge.html") async throws {
        browser.load(URL(string: path, relativeTo: fixtureBase)!.absoluteURL)
        // Cold simulator WebKit processes can take >10 seconds to launch.
        for _ in 0..<600 {
            if let error = browser.error { throw WebError("NetworkError", "HTTPS fixture: \(error). Run prepare-fixtures.sh and serve-fixtures.mjs.") }
            if browser.hardware.document.active, !browser.webView.isLoading { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw WebError("TimeoutError", "HTTPS fixture did not load (URL: \(browser.webView.url?.absoluteString ?? "none"), loading: \(browser.webView.isLoading), active: \(browser.hardware.document.active)).")
    }

    @Test func realFrameOriginChecksAndNavigationTokens() async throws {
        let ble = TestBluetooth()
        let coordinator = HardwareCoordinator(bluetooth: ble, nfc: TestNFC())
        let browser = BrowserModel(hardware: coordinator, dataStore: .nonPersistent())
        let window = try host(browser)
        defer { window.isHidden = true; browser.webView.removeFromSuperview() }
        try await open(browser)
        #expect(try await evaluate(browser.webView, "return typeof navigator.bluetooth + ',' + typeof NDEFReader") == "object,function")
        let token = coordinator.document.token
        let frameResult = try await evaluate(browser.webView, """
            const frame = document.getElementById('child').contentWindow;
            const result = await frame.webkit.messageHandlers.wand.postMessage({
              id: crypto.randomUUID(), token, op: 'ble.requestDevice', args: { acceptAllDevices: true }
            });
            return typeof frame.navigator.bluetooth + ',' + result.error.name;
            """, arguments: ["token": token])
        #expect(frameResult == "undefined,SecurityError")
        #expect(ble.scanCount == 0)
        try await open(browser, path: "second.html")
        #expect(coordinator.document.token != token)
        let stale = try await evaluate(browser.webView, """
            const result = await webkit.messageHandlers.wand.postMessage({
              id: crypto.randomUUID(), token, op: 'ble.requestDevice', args: { acceptAllDevices: true }
            });
            return result.error.name;
            """, arguments: ["token": token])
        #expect(stale == "SecurityError")
        coordinator.invalidate()
    }

    @Test func actualMessageReplyAndNFCPermissionRoundTrip() async throws {
        let ble = TestBluetooth(), nfc = TestNFC()
        let coordinator = HardwareCoordinator(bluetooth: ble, nfc: nfc)
        let browser = BrowserModel(hardware: coordinator, dataStore: .nonPersistent())
        let window = try host(browser)
        defer { window.isHidden = true; browser.webView.removeFromSuperview() }
        try await open(browser)
        let request = Task { try await evaluate(browser.webView, """
            const value = await webkit.messageHandlers.wand.postMessage({
              id: crypto.randomUUID(), token, op: 'ble.requestDevice',
              args: { filters: [{namePrefix:'Hito'}], optionalServices:['5cc44b16-070a-11ed-b939-0242ac120002'] }
            });
            return JSON.stringify(value);
            """, arguments: ["token": coordinator.document.token]) }
        for _ in 0..<100 {
            if coordinator.picker != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(coordinator.picker?.origin == SiteOrigin(url: fixtureBase)?.display)
        coordinator.selectDevice("test-device")
        #expect(try await request.value.contains("Hito test wallet"))
        let scan = Task { try await evaluate(browser.webView, """
            window.reader = new NDEFReader();
            window.messages = [];
            reader.onreading = event => messages.push(new TextDecoder().decode(event.message.records[0].data));
            await reader.scan();
            return 'scanning';
            """) }
        for _ in 0..<100 {
            if coordinator.permission != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(coordinator.permission != nil)
        coordinator.resolvePermission(true)
        #expect(try await scan.value == "scanning")
        let readerID = try await evaluate(browser.webView, "return reader._id")
        nfc.onEvent?("nfc.reading", .object(["reader": .string(readerID), "serialNumber": .string(""),
                                           "records": .array([NDEFRecord(type: "text", data: Data("hello".utf8), encoding: "utf-8", language: "en").json])]))
        #expect(try await evaluate(browser.webView, "return JSON.stringify(messages)") == "[\"hello\"]")
        coordinator.revoke()
        #expect(!coordinator.hasNFCGrant)
        #expect(coordinator.allowedDevices.isEmpty)
        coordinator.invalidate()
    }
}
