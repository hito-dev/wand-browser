import Combine
import SwiftUI
import WebKit
import ImageIO

@MainActor
final class BrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published var address = ""
    @Published var title = "Wand Browser"
    @Published var loading = false
    @Published var progress = 0.0
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var showingHome = true
    @Published var error: String? { didSet { if error != nil { exitFullscreen() } } }
    @Published var currentURL: URL?
    @Published private(set) var favicon: UIImage?
    private var faviconTask: Task<Void, Never>?
    private var faviconGeneration = UUID()
    private let faviconCache = NSCache<NSURL, UIImage>()
    static func displayAddress(_ url: URL?) -> (host: String, path: String) {
        guard let url, let origin = SiteOrigin(url: url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return ("", "") }
        let host = String(origin.display.dropFirst(origin.scheme.count + 3))
        return (host, components.percentEncodedPath == "/" ? "" : components.percentEncodedPath)
    }
    static func faviconCandidates(_ links: [String], pageURL: URL) -> [URL] {
        var seen = Set<URL>()
        let fallback = URL(string: "/favicon.ico", relativeTo: pageURL)?.absoluteURL
        return (links.compactMap { URL(string: $0, relativeTo: pageURL)?.absoluteURL.standardized } + [fallback, parentFaviconURL(for: pageURL)].compactMap { $0 }).filter {
            ["http", "https"].contains($0.scheme?.lowercased() ?? "") && $0.user == nil && $0.password == nil && seen.insert($0).inserted
        }
    }
    static func parentFaviconURL(for url: URL) -> URL? {
        guard let host = url.host?.lowercased(),
              let parent = PublicSuffixRules.shared.registrableDomain(host), parent != host,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        components.host = parent
        components.port = nil
        components.user = nil; components.password = nil
        components.path = "/favicon.ico"
        components.query = nil; components.fragment = nil
        return components.url
    }
    nonisolated static func fetchFavicon(_ url: URL, session: URLSession) async throws -> UIImage? {
        let (bytes, response) = try await session.bytes(from: url)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              response.expectedContentLength <= 1_048_576 else { return nil }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 1_048_576 else { return nil }
            data.append(byte)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 60,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: thumbnail)
    }
    static func faviconLinks(in webView: WKWebView) async -> [String] {
        let script = """
        Array.from(document.querySelectorAll('link[rel]'))
          .filter(link => link.rel.toLowerCase().split(/\\s+/).some(rel => ['icon', 'apple-touch-icon', 'apple-touch-icon-precomposed'].includes(rel)))
          .slice(0, 8).map(link => link.href)
        """
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { result in
                continuation.resume(returning: (try? result.get()) as? [String] ?? [])
            }
        }
    }
    private func resetFavicon() {
        faviconTask?.cancel(); faviconTask = nil
        faviconGeneration = UUID(); favicon = nil
    }
    private func discoverFavicon(for pageURL: URL) {
        let generation = faviconGeneration
        faviconTask?.cancel()
        faviconTask = Task { [weak self] in
            guard let self else { return }
            let links = await Self.faviconLinks(in: webView)
            guard !Task.isCancelled, generation == faviconGeneration else { return }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 5
            configuration.timeoutIntervalForResource = 5
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            for url in Self.faviconCandidates(links, pageURL: pageURL) {
                guard !Task.isCancelled, generation == faviconGeneration else { return }
                if let cached = faviconCache.object(forKey: url as NSURL) { favicon = cached; return }
                do {
                    guard let thumbnail = try await Self.fetchFavicon(url, session: session) else { continue }
                    guard !Task.isCancelled, generation == faviconGeneration else { return }
                    faviconCache.setObject(thumbnail, forKey: url as NSURL, cost: 60 * 60 * 4)
                    favicon = thumbnail
                    return
                } catch { if Task.isCancelled { return } }
            }
        }
    }
    @Published var javaScriptDialog: JavaScriptDialog?
    @Published private(set) var history: [HistoryEntry]
    @Published private(set) var isFullscreen = false {
        didSet { if oldValue != isFullscreen { hardware.fullscreenChanged() } }
    }
    @Published private(set) var websiteFullscreen = false
    @Published private var fullscreenOrigins: Set<String> = []
    // Preserve a manual exit through reloads and same-origin navigation.
    // Re-evaluate the saved preference only after leaving this origin or going Home.
    private var presentationOrigin: String?
    private static let fullscreenKey = "browser.fullscreenOrigins.v1"
    var canEnterFullscreen: Bool { !showingHome && error == nil && currentOrigin != nil }
    private var currentOrigin: String? {
        guard let url = currentURL, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return SiteOrigin(url: url)?.display
    }
    var alwaysFullscreen: Bool { currentOrigin.map { fullscreenOrigins.contains($0) } ?? false }
    func setAlwaysFullscreen(_ enabled: Bool) {
        guard let origin = currentOrigin else { return }
        if enabled { fullscreenOrigins.insert(origin); enterFullscreen() }
        else { fullscreenOrigins.remove(origin) }
        historyDefaults.set(Array(fullscreenOrigins).sorted(), forKey: Self.fullscreenKey)
    }
    func enterFullscreen() {
        guard canEnterFullscreen else { return }
        presentationOrigin = currentOrigin
        isFullscreen = true
    }
    func exitFullscreen() { isFullscreen = false }
    func updatePresentation(for url: URL?) {
        let origin = url.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? SiteOrigin(url: $0)?.display : nil }
        guard origin != presentationOrigin else { return }
        presentationOrigin = origin
        isFullscreen = !showingHome && error == nil && origin.map { fullscreenOrigins.contains($0) } == true
    }
    private let historyDefaults: UserDefaults
    private static let historyKey = "browser.history.v1"
    let hardware: HardwareCoordinator
    let webView: WKWebView
    private var observers: [NSKeyValueObservation] = []

    init(hardware: HardwareCoordinator = HardwareCoordinator(), dataStore: WKWebsiteDataStore = .default(), historyDefaults: UserDefaults = .standard) {
        self.historyDefaults = historyDefaults
        history = historyDefaults.data(forKey: Self.historyKey).flatMap { try? JSONDecoder().decode([HistoryEntry].self, from: $0) } ?? []
        fullscreenOrigins = Set(historyDefaults.stringArray(forKey: Self.fullscreenKey) ?? [])
        self.hardware = hardware
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.preferences.isElementFullscreenEnabled = true
        let controller = configuration.userContentController
        controller.addScriptMessageHandler(hardware, contentWorld: .page, name: "wand")
        if let path = Bundle.main.url(forResource: "HardwareBridge", withExtension: "js"),
           let script = try? String(contentsOf: path, encoding: .utf8) {
            controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        hardware.fullscreenState = { [weak self] in self?.isFullscreen ?? false }
        hardware.setFullscreen = { [weak self] active in
            guard let self, !self.websiteFullscreen else {
                throw WebError("InvalidStateError", "Exit WebKit fullscreen before changing Wand fullscreen.")
            }
            if active {
                guard self.canEnterFullscreen else { throw WebError("InvalidStateError", "No page is available for fullscreen.") }
                self.enterFullscreen()
            } else { self.exitFullscreen() }
        }
        faviconCache.totalCostLimit = 2 * 1024 * 1024
        hardware.webView = webView
        webView.navigationDelegate = self; webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = _isDebugAssertConfiguration()
        observers = [
            webView.observe(\.fullscreenState, options: [.new]) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.websiteFullscreen = web.fullscreenState != .notInFullscreen }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, value in
                MainActor.assumeIsolated { self?.progress = value.newValue ?? 0 }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, value in
                MainActor.assumeIsolated { self?.loading = value.newValue ?? false }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, value in
                MainActor.assumeIsolated { self?.canGoBack = value.newValue ?? false }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, value in
                MainActor.assumeIsolated { self?.canGoForward = value.newValue ?? false }
            },
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.title = self?.webView.title ?? "Wand Browser" }
            },
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self, let url = self.webView.url else { return }
                    self.currentURL = url; self.address = url.absoluteString
                }
            }
        ]
    }
    static func navigationURL(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: candidate),
              ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              let url = components.url else { return nil }
        return url
    }
    func navigate() {
        guard let url = Self.navigationURL(address) else { error = "Enter a website address, such as example.com."; return }
        load(url)
    }
    func load(_ url: URL) {
        error = nil; showingHome = false
        webView.load(URLRequest(url: url))
    }
    func home() {
        resetFavicon()
        exitFullscreen(); presentationOrigin = nil
        webView.stopLoading()
        hardware.navigationStarted()
        showingHome = true; address = ""; currentURL = nil; error = nil
        webView.loadHTMLString("", baseURL: nil)
    }
    func recordVisit(url: URL, title: String?) {
        guard Self.navigationURL(url.absoluteString) != nil else { return }
        let label = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        history.removeAll { $0.url == url }
        history.insert(HistoryEntry(url: url, title: label?.isEmpty == false ? label! : (url.host ?? url.absoluteString), visitedAt: Date()), at: 0)
        history = Array(history.prefix(100))
        if let data = try? JSONEncoder().encode(history) { historyDefaults.set(data, forKey: Self.historyKey) }
    }
    func clearHistory() {
        history = []
        historyDefaults.removeObject(forKey: Self.historyKey)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !showingHome, let url = webView.url else { return }
        recordVisit(url: url, title: webView.title)
        discoverFavicon(for: url)
    }
    func reload() { error = nil; webView.reload() }
    func clearWebsiteData() async {
        faviconCache.removeAllObjects()
        fullscreenOrigins.removeAll()
        historyDefaults.removeObject(forKey: Self.fullscreenKey)
        home()
        let store = webView.configuration.websiteDataStore
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if navigationAction.targetFrame?.isMainFrame == false {
            // Subframes retain WebKit's normal navigation behavior; the native hardware gate rejects them.
            decisionHandler(.allow); return
        }
        if url.absoluteString == "about:blank" { decisionHandler(.allow); return }
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? "") else {
            error = "This link uses a URL scheme Wand Browser does not support."
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        resetFavicon()
        dismissJavaScriptDialog()
        hardware.navigationStarted()
        error = nil
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        currentURL = webView.url
        updatePresentation(for: webView.url)
        hardware.committed(webView.url)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled {
            // Stopping a provisional load leaves the previous document on screen.
            // It gets a fresh visit, never its old hardware grants.
            if !webView.isLoading { hardware.committed(webView.url) }
        } else {
            self.error = error.localizedDescription
            hardware.navigationStarted()
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { self.error = error.localizedDescription }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        hardware.navigationStarted()
        error = "The page stopped responding. Reload to continue."
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url,
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") { load(url) }
        return nil
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        showDialog(.init(origin: frame.securityOrigin.host, message: message, kind: .alert) { _ in completionHandler() })
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        showDialog(.init(origin: frame.securityOrigin.host, message: message, kind: .confirm) { completionHandler($0 != nil) })
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        showDialog(.init(origin: frame.securityOrigin.host, message: prompt, kind: .prompt, text: defaultText ?? "", completion: completionHandler))
    }
    private func showDialog(_ dialog: JavaScriptDialog) {
        guard javaScriptDialog == nil, hardware.picker == nil, hardware.permission == nil else { dialog.complete(nil); return }
        javaScriptDialog = dialog
    }
    func dismissJavaScriptDialog() { javaScriptDialog?.complete(nil); javaScriptDialog = nil }
}

@MainActor
final class JavaScriptDialog: Identifiable {
    enum Kind { case alert, confirm, prompt }
    let id = UUID()
    let origin: String
    let message: String
    let kind: Kind
    var text: String
    private var completion: ((String?) -> Void)?
    init(origin: String, message: String, kind: Kind, text: String = "", completion: @escaping (String?) -> Void) {
        self.origin = origin; self.message = message; self.kind = kind; self.text = text; self.completion = completion
    }
    func complete(_ value: String?) { let callback = completion; completion = nil; callback?(value) }
}

struct HistoryEntry: Codable, Identifiable {
    var id: URL { url }
    let url: URL
    let title: String
    let visitedAt: Date
}

// Bundled PSL includes private suffixes, so hosted sites never borrow another tenant's icon.
private struct PublicSuffixRules: Sendable {
    let exact: Set<String>
    let wildcard: Set<String>
    let exceptions: Set<String>
    static let shared: PublicSuffixRules = {
        let text = Bundle.main.url(forResource: "public_suffix_list", withExtension: "dat")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        var exact = Set<String>(), wildcard = Set<String>(), exceptions = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            let rule = String(line).trimmingCharacters(in: .whitespaces)
            guard !rule.isEmpty, !rule.hasPrefix("//") else { continue }
            let prefix = rule.hasPrefix("!") ? "!" : rule.hasPrefix("*.") ? "*." : ""
            guard let canonical = URL(string: "https://" + rule.dropFirst(prefix.count))?.host?.lowercased() else { continue }
            if prefix == "!" { exceptions.insert(canonical) }
            else if prefix == "*." { wildcard.insert(canonical) }
            else { exact.insert(canonical) }
        }
        return PublicSuffixRules(exact: exact, wildcard: wildcard, exceptions: exceptions)
    }()
    func registrableDomain(_ host: String) -> String? {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let labels = host.split(separator: ".").map(String.init)
        guard !exact.isEmpty, !host.contains(":"), labels.count > 1,
              !labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        var suffixCount = 1
        for index in labels.indices {
            let suffix = labels[index...].joined(separator: ".")
            if exceptions.contains(suffix) { suffixCount = labels.count - index - 1; break }
            if exact.contains(suffix) { suffixCount = max(suffixCount, labels.count - index) }
            if index > 0, wildcard.contains(suffix) { suffixCount = max(suffixCount, labels.count - index + 1) }
        }
        guard labels.count > suffixCount else { return nil }
        return labels.suffix(suffixCount + 1).joined(separator: ".")
    }
}
