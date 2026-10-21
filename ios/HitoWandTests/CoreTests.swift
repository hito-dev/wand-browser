import Foundation
import CoreNFC
import Testing
import WebKit
@testable import HitoWand

struct CoreTests {
    @Test @MainActor func fullscreenAddressFormattingAndIconCandidates() throws {
        let url = try #require(URL(string: "https://EXAMPLE.com:8443/path%20name?q=secret#fragment"))
        let display = BrowserModel.displayAddress(url)
        #expect(display.host == "example.com:8443")
        #expect(display.path == "/path%20name")
        #expect(BrowserModel.displayAddress(URL(string: "https://example.com/")).path.isEmpty)
        let links = BrowserModel.faviconCandidates(["../icon.png", "https://cdn.example/icon.png", "data:image/png;base64,AAAA", "file:///icon.png", "../icon.png"], pageURL: url)
        #expect(links.map(\.absoluteString) == ["https://EXAMPLE.com:8443/icon.png", "https://cdn.example/icon.png", "https://EXAMPLE.com:8443/favicon.ico"])
    }

    @Test @MainActor func parentDomainFaviconFallbackHonorsPublicSuffixes() throws {
        let cases = [
            ("https://app.example.com/page?token=private", "https://example.com/favicon.ico"),
            ("https://app.example.co.uk:8443/page", "https://example.co.uk/favicon.ico"),
            ("https://app.user.github.io/", "https://user.github.io/favicon.ico"),
            ("https://app.www.ck/", "https://www.ck/favicon.ico"),
            ("https://a.b.foo.ck/", "https://b.foo.ck/favicon.ico"),
            ("https://app.xn--e1afmkfd.xn--p1ai/", "https://xn--e1afmkfd.xn--p1ai/favicon.ico")
        ]
        for (source, expected) in cases {
            let url = try #require(URL(string: source))
            #expect(BrowserModel.parentFaviconURL(for: url)?.absoluteString == expected)
            #expect(BrowserModel.faviconCandidates([], pageURL: url).last?.absoluteString == expected)
        }
        for source in ["https://example.com/", "https://example.co.uk/", "https://co.uk/", "https://user.github.io/", "https://127.0.0.1/", "https://[::1]/", "https://localhost/"] {
            #expect(BrowserModel.parentFaviconURL(for: try #require(URL(string: source))) == nil)
        }
    }

    @Test @MainActor func faviconDiscoveryResolvesDocumentBaseURL() async throws {
        let view = WKWebView()
        view.loadHTMLString("""
        <base href="https://icons.test/assets/">
        <link rel="stylesheet" href="ignore.css">
        <link rel="shortcut icon" href="small.png">
        <link rel="apple-touch-icon" href="/touch.png">
        """, baseURL: URL(string: "https://page.test/"))
        var links: [String] = []
        for _ in 0..<100 {
            links = await BrowserModel.faviconLinks(in: view)
            if !links.isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(links == ["https://icons.test/assets/small.png", "https://icons.test/touch.png"])
        view.stopLoading()
    }

    @Test @MainActor func faviconImageResponsesAreBoundedAndDecoded() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FaviconTestProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let valid = try await BrowserModel.fetchFavicon(try #require(URL(string: "https://icons.test/valid")), session: session)
        #expect(valid != nil)
        for path in ["missing", "unsupported", "oversized", "streamed-oversized"] {
            let icon = try await BrowserModel.fetchFavicon(try #require(URL(string: "https://icons.test/\(path)")), session: session)
            #expect(icon == nil)
        }
    }

    @Test @MainActor func fullscreenPreferencesAndVisitOverrides() async throws {
        let suite = "wand.fullscreen.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let browser = BrowserModel(dataStore: .nonPersistent(), historyDefaults: defaults)
        let first = try #require(URL(string: "https://EXAMPLE.com:443/first"))
        let second = try #require(URL(string: "https://example.com/second"))
        let other = try #require(URL(string: "https://other.example.com/"))
        browser.enterFullscreen()
        #expect(!browser.isFullscreen)
        browser.showingHome = false
        browser.currentURL = first
        browser.updatePresentation(for: first)
        browser.setAlwaysFullscreen(true)
        #expect(browser.isFullscreen)
        browser.exitFullscreen()
        browser.currentURL = second
        browser.updatePresentation(for: second)
        #expect(!browser.isFullscreen)
        #expect(browser.alwaysFullscreen)
        browser.updatePresentation(for: other)
        browser.updatePresentation(for: second)
        #expect(browser.isFullscreen)
        for value in ["http://example.com/", "https://example.com:8443/", "https://other.example.com/"] {
            let url = try #require(URL(string: value))
            browser.currentURL = url
            browser.updatePresentation(for: url)
            #expect(!browser.isFullscreen)
            #expect(!browser.alwaysFullscreen)
        }
        let restored = BrowserModel(dataStore: .nonPersistent(), historyDefaults: defaults)
        restored.showingHome = false
        restored.currentURL = second
        restored.updatePresentation(for: second)
        #expect(restored.isFullscreen)
        restored.error = "Load failed"
        #expect(!restored.isFullscreen)
        restored.error = nil
        restored.updatePresentation(for: second)
        #expect(!restored.isFullscreen)
        restored.home()
        restored.showingHome = false
        restored.currentURL = second
        restored.updatePresentation(for: second)
        #expect(restored.isFullscreen)
        restored.clearHistory()
        #expect(restored.alwaysFullscreen)
        await restored.clearWebsiteData()
        #expect(!restored.isFullscreen)
        let cleared = BrowserModel(dataStore: .nonPersistent(), historyDefaults: defaults)
        cleared.currentURL = second
        #expect(!cleared.alwaysFullscreen)
    }

    @Test @MainActor func browsingHistoryPersistsDeduplicatesAndClears() throws {
        let suite = "wand.history.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let browser = BrowserModel(historyDefaults: defaults)
        let first = try #require(URL(string: "https://example.com/first"))
        let second = try #require(URL(string: "https://example.com/second"))
        browser.recordVisit(url: first, title: "First")
        browser.recordVisit(url: second, title: "Second")
        browser.recordVisit(url: first, title: "Updated")
        browser.recordVisit(url: try #require(URL(string: "about:blank")), title: "Blank")
        #expect(browser.history.map(\.url) == [first, second])
        let restored = BrowserModel(historyDefaults: defaults)
        #expect(restored.history.first?.title == "Updated")
        for index in 0..<105 {
            restored.recordVisit(url: try #require(URL(string: "https://example.com/\(index)")), title: nil)
        }
        #expect(restored.history.count == 100)
        restored.clearHistory()
        #expect(restored.history.isEmpty)
        #expect(BrowserModel(historyDefaults: defaults).history.isEmpty)
    }

    @Test func originAndDocumentIsolation() throws {
        let origin = SiteOrigin(scheme: "https", host: "wallet.example", port: 0)
        #expect(origin == SiteOrigin(scheme: "HTTPS", host: "WALLET.EXAMPLE", port: 443))
        var session = DocumentSession()
        session.activate(origin: origin)
        let token = session.token
        try session.validate(token: token, origin: origin, mainFrame: true, foreground: true)
        #expect(throws: WebError.self) { try session.validate(token: token, origin: origin, mainFrame: false, foreground: true) }
        #expect(throws: WebError.self) { try session.validate(token: token, origin: origin, mainFrame: true, foreground: false) }
        #expect(throws: WebError.self) { try session.validate(token: token, origin: .init(scheme: "https", host: "other.example", port: 443), mainFrame: true, foreground: true) }
        #expect(throws: WebError.self) { try session.validate(token: token, origin: .init(scheme: "https", host: "wallet.example", port: 8443), mainFrame: true, foreground: true) }
        session.invalidate()
        session.activate(origin: origin)
        #expect(throws: WebError.self) { try session.validate(token: token, origin: origin, mainFrame: true, foreground: true) }
    }

    @Test func filterSemanticsAndServiceScope() throws {
        let uuid = "5cc44b16-070a-11ed-b939-0242ac120002"
        let options = try BluetoothRequestOptions([
            "filters": .array([.object(["namePrefix": .string("Hito"), "services": .array([.number(0x180f)])]),
                               .object(["name": .string("Exact")])]),
            "optionalServices": .array([.string(uuid)])
        ])
        let battery = try BluetoothUUID.canonical(.number(0x180f))
        #expect(options.matches(name: "Hito test", services: [battery]))
        #expect(!options.matches(name: "Hito test", services: []))
        #expect(options.matches(name: "Exact", services: []))
        #expect(!options.matches(name: "Exact extra", services: [battery]))
        #expect(options.allowedServices == [uuid, battery])
        #expect(throws: WebError.self) { try BluetoothRequestOptions(["acceptAllDevices": .bool(true), "filters": .array([])]) }
        #expect(throws: WebError.self) { try BluetoothRequestOptions(["filters": .array([.object(["namePrefix": .string("")])])]) }
        #expect(throws: WebError.self) { try BluetoothRequestOptions(["filters": .array([.object(["manufacturerData": .array([])])])]) }
        #expect(throws: WebError.self) { try BluetoothRequestOptions(["acceptAllDevices": .bool(true), "optionalServices": .array([.number(0x1812)])]) }
    }

    @Test func uuidAndBlocklist() throws {
        #expect(try BluetoothUUID.canonical(.string("180F")) == "0000180f-0000-1000-8000-00805f9b34fb")
        #expect(try BluetoothUUID.canonical(.number(0x180f)) == BluetoothUUID.canonical(.string("0000180F-0000-1000-8000-00805F9B34FB")))
        #expect(throws: WebError.self) { try BluetoothUUID.canonical(.number(-1)) }
        #expect(throws: WebError.self) { try BluetoothUUID.canonical(.number(1.5)) }
        #expect(throws: WebError.self) { try BluetoothUUID.canonical(.string("battery_service")) }
        let privacy = try BluetoothUUID.canonical(.number(0x2a02))
        try GATTBlocklist.check(privacy)
        #expect(throws: WebError.self) { try GATTBlocklist.check(privacy, writing: true) }
        #expect(throws: WebError.self) { try GATTBlocklist.check(BluetoothUUID.canonical(.number(0x2a25))) }
    }

    @Test func ndefRoundTrips() throws {
        let records = [
            NDEFRecord(type: "empty"),
            NDEFRecord(type: "text", id: "greeting", data: Data("Grüße 🌍".utf8), encoding: "utf-8", language: "de"),
            NDEFRecord(type: "text", data: "Hello".data(using: .utf16)!, encoding: "utf-16", language: "en"),
            NDEFRecord(type: "url", data: Data("https://hito.ai/path".utf8)),
            NDEFRecord(type: "absolute-url", data: Data("https://hito.ai/path".utf8)),
            NDEFRecord(type: "mime", id: "binary", data: Data([0, 255, 127]), mediaType: "application/octet-stream"),
            NDEFRecord(type: "hito.ai:wallet", data: Data([1, 2, 3])),
            NDEFRecord(type: "unknown", data: Data([9, 8, 7]))
        ]
        for record in records { #expect(try NDEFRecord.decode(record.payload()) == record) }
        let compressed = NFCNDEFPayload(format: .nfcWellKnown, type: Data("U".utf8), identifier: Data(), payload: Data([4]) + Data("hito.ai".utf8))
        #expect(try NDEFRecord.decode(compressed).data == Data("https://hito.ai".utf8))
    }

    @Test func malformedNdefIsRejected() throws {
        let malformed = NFCNDEFPayload(format: .nfcWellKnown, type: Data("T".utf8), identifier: Data(), payload: Data([63, 0]))
        #expect(throws: WebError.self) { try NDEFRecord.decode(malformed) }
        #expect(throws: WebError.self) { try NDEFRecord(type: "smart-poster").payload() }
        #expect(throws: WebError.self) { try NDEFRecord(type: "empty", data: Data([1])).payload() }
        #expect(throws: WebError.self) { try NDEFRecord(type: "url", data: Data("/relative".utf8)).payload() }
        #expect(throws: WebError.self) { try NDEFRecord(type: "mime", mediaType: "invalid mime").payload() }
        #expect(throws: WebError.self) { try NDEFRecord(type: "text", language: String(repeating: "a", count: 64)).payload() }
        #expect(throws: WebError.self) { try NDEFRecord(type: "unknown", data: Data(repeating: 0, count: 65_537)).payload() }
    }

    @MainActor @Test func repliesCompleteExactlyOnceAndBoundQueue() throws {
        let replies = PendingReplies()
        var count = 0
        try replies.insert("one") { _, _ in count += 1 }
        #expect(throws: WebError.self) { try replies.insert("one") { _, _ in } }
        replies.finish("one", .success(.null))
        replies.finish("one", .failure(.aborted))
        #expect(count == 1)
        for i in 0..<64 { try replies.insert("\(i)") { _, _ in count += 1 } }
        #expect(throws: WebError.self) { try replies.insert("overflow") { _, _ in } }
        replies.cancelAll(); replies.cancelAll()
        #expect(count == 65)
        #expect(replies.count == 0)
    }

    @MainActor @Test func browserURLValidation() {
        #expect(BrowserModel.navigationURL("hito.ai")?.absoluteString == "https://hito.ai")
        #expect(BrowserModel.navigationURL("https://example.com:8443/path")?.port == 8443)
        #expect(BrowserModel.navigationURL("not a website") == nil)
        #expect(BrowserModel.navigationURL("javascript://alert(1)") == nil)
        #expect(BrowserModel.navigationURL("https://USER:PASSWORD@example.com") == nil)
    }
}

private final class FaviconTestProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "icons.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let path = url.lastPathComponent
        let data: Data
        if path.contains("oversized") { data = Data(repeating: 0, count: 1_048_577) }
        else if path == "unsupported" { data = Data("<svg></svg>".utf8) }
        else { data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgaPj/HwAEggJ/59habAAAAABJRU5ErkJggg==")! }
        let headers = path == "streamed-oversized" ? [:] : ["Content-Length": String(data.count)]
        let response = HTTPURLResponse(url: url, statusCode: path == "missing" ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
