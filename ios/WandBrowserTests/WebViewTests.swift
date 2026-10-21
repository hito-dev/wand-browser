import Foundation
import Testing
import WebKit
import UIKit
@testable import WandBrowser

/// Uses an actual WKWebView, hosted HTTPS fixtures, and the production message handler.
/// Only the radio adapters are replaced. No local server or certificates are needed.
@MainActor
@Suite(.serialized)
struct WebViewTests {
    var fixtureBase: URL {
        get throws {
            let value = ProcessInfo.processInfo.environment["WAND_FIXTURE_URL"] ?? "https://hito-dev.github.io/wand-browser/fixtures/"
            guard let url = URL(string: value), url.scheme == "https", let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
                throw WebError("TypeError", "WAND_FIXTURE_URL must be an HTTPS directory URL without credentials, query, or fragment.")
            }
            return URL(string: value.hasSuffix("/") ? value : value + "/")!
        }
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
        let url = URL(string: path, relativeTo: try fixtureBase)!.absoluteURL
        browser.load(url)
        // Cold simulator WebKit processes can take >10 seconds to launch.
        for _ in 0..<600 {
            if let error = browser.error {
                throw WebError("NetworkError", "Could not load HTTPS fixture \(url): \(error). Check your internet connection and Pages deployment, or set WAND_FIXTURE_URL to another HTTPS fixture host.")
            }
            if browser.hardware.document.active, !browser.webView.isLoading { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw WebError("TimeoutError", "HTTPS fixture \(url) did not load. Check your internet connection and Pages deployment, or set WAND_FIXTURE_URL to another HTTPS fixture host.")
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

    @Test func wandFullscreenRoundTripAndNativeStateSync() async throws {
        let browser = BrowserModel(hardware: HardwareCoordinator(bluetooth: TestBluetooth(), nfc: TestNFC()), dataStore: .nonPersistent())
        let window = try host(browser)
        defer { window.isHidden = true; browser.webView.removeFromSuperview() }
        try await open(browser)
        #expect(try await evaluate(browser.webView, "return String(window.wand.fullscreen.active)") == "false")
        // Exercise the production adapter directly; public gesture validation is
        // covered in JavaScript tests and native controls are covered in UI tests.
        let token = browser.hardware.document.token
        let entered = try await evaluate(browser.webView, """
            window.fullscreenChanges = [];
            wand.fullscreen.addEventListener('change', () => fullscreenChanges.push(wand.fullscreen.active));
            const result = await webkit.messageHandlers.wand.postMessage({
              id: crypto.randomUUID(), token, op: 'fullscreen.request', args: {}
            });
            return String(result.ok.active);
            """, arguments: ["token": token])
        #expect(entered == "true")
        #expect(browser.isFullscreen)
        #expect(!browser.alwaysFullscreen)
        #expect(try await evaluate(browser.webView, "return String(wand.fullscreen.active) + ',' + String(document.fullscreenElement === null)") == "true,true")
        browser.exitFullscreen()
        #expect(try await evaluate(browser.webView, "return String(wand.fullscreen.active)") == "false")
        browser.enterFullscreen()
        browser.hardware.setForeground(false)
        browser.hardware.setForeground(true)
        #expect(try await evaluate(browser.webView, "return String(wand.fullscreen.active)") == "true")
        #expect(try await evaluate(browser.webView, "await wand.fullscreen.exit(); return JSON.stringify(fullscreenChanges)") == "[true,false,true,false]")
        #expect(!browser.isFullscreen)
        try await open(browser, path: "second.html")
        #expect(try await evaluate(browser.webView, "return String(wand.fullscreen.active)") == "false")
        browser.enterFullscreen()
        try await open(browser)
        #expect(try await evaluate(browser.webView, "return String(wand.fullscreen.active)") == "true")
        browser.exitFullscreen()
        browser.hardware.invalidate()
    }

    @Test func fixtureConsoleLayoutKeyboardBoundsAndLogging() async throws {
        let browser = BrowserModel(hardware: HardwareCoordinator(bluetooth: TestBluetooth(), nfc: TestNFC()), dataStore: .nonPersistent())
        let window = try host(browser)
        defer { window.isHidden = true; browser.webView.removeFromSuperview() }
        try await open(browser)
        let result = try await evaluate(browser.webView, """
            const pane = document.querySelector('#console');
            const divider = document.querySelector('#console-divider');
            const height = () => document.body.getBoundingClientRect().height;
            const consoleHeight = () => pane.getBoundingClientRect().height;
            const close = (actual, expected, label) => {
              if (Math.abs(actual - expected) > 2) throw new Error(`${label}: ${actual} != ${expected}`);
            };
            const key = key => divider.dispatchEvent(new KeyboardEvent('keydown', { key, bubbles: true, cancelable: true }));
            if (document.querySelector('#wand-fullscreen, #sdk, #command, #packet')) throw new Error('Removed controls remain');
            if (!document.documentElement.requestFullscreen) throw new Error('Standard fullscreen missing');
            close(consoleHeight(), height() * .2, 'default console size');
            key('ArrowUp');
            close(consoleHeight(), height() * .25, 'arrow up');
            key('ArrowDown');
            close(consoleHeight(), height() * .2, 'arrow down');
            key('Home');
            close(consoleHeight(), 80, 'minimum console');
            key('End');
            close(height() - consoleHeight(), 80, 'minimum controls');
            close(Number(divider.getAttribute('aria-valuenow')), consoleHeight() / height() * 100, 'accessible size');
            const ratio = consoleHeight() / height();
            document.documentElement.style.setProperty('--viewport-height', '120px');
            resizeConsole();
            close(consoleHeight(), 60, 'tiny viewport');
            window.dispatchEvent(new Event('resize'));
            close(consoleHeight() / height() * 100, ratio * 100, 'restored viewport ratio');
            key('Home'); key('ArrowUp');
            for (let i = 0; i < 80; i++) log(`Console line ${i}`);
            const output = document.querySelector('#log');
            close(output.scrollHeight - output.clientHeight - output.scrollTop, 0, 'follow new logs');
            output.scrollTop = 0;
            log('Keep reading earlier logs');
            close(output.scrollTop, 0, 'preserve scroll position');
            key('ArrowUp');
            close(output.scrollTop, 0, 'preserve scroll while resizing');
            output.scrollTop = output.scrollHeight;
            key('ArrowDown');
            close(output.scrollHeight - output.clientHeight - output.scrollTop, 0, 'follow while resizing');
            return 'ok';
            """)
        #expect(result == "ok")
        try await open(browser)
        #expect(try await evaluate(browser.webView, "return document.querySelector('#console-divider').getAttribute('aria-valuenow')") == "20")
        browser.hardware.invalidate()
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
        #expect(coordinator.picker?.origin == SiteOrigin(url: try fixtureBase)?.display)
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
