import Combine
import SwiftUI
import WebKit

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
    @Published var javaScriptDialog: JavaScriptDialog?
    @Published private(set) var history: [HistoryEntry]
    @Published private(set) var isFullscreen = false
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
    }
    func reload() { error = nil; webView.reload() }
    func clearWebsiteData() async {
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
        dismissJavaScriptDialog()
        hardware.navigationStarted()
        error = nil
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        hardware.committed(webView.url)
        currentURL = webView.url
        updatePresentation(for: webView.url)
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
