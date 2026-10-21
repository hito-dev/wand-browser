import SwiftUI
import WebKit

struct BrowserView: View {
    @ObservedObject var browser: BrowserModel
    @ObservedObject var hardware: HardwareCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @State private var exitVisible = true
    @State private var revealID = UUID()
    @State private var accessibleExit = UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
    @State private var siteControls = false
    @State private var share = false
    @State private var confirmClearHistory = false
    @State private var addressFocused = false

    init(browser: BrowserModel) { self.browser = browser; self.hardware = browser.hardware }
    var body: some View {
        VStack(spacing: 0) {
            if !browser.isFullscreen {
                HStack(spacing: 10) {
                    Button { siteControls = true } label: {
                        Image(systemName: browser.currentURL?.scheme == "http" ? "lock.open" : "slider.horizontal.3")
                            .frame(width: 36, height: 44)
                    }
                    .accessibilityLabel("Site controls")
                    .accessibilityIdentifier("site-controls")
                    AddressField(text: $browser.address, isFocused: $addressFocused) {
                        addressFocused = false
                        browser.navigate()
                    }.frame(height: 44)
                    Button {
                        addressFocused = false
                        if browser.loading { browser.webView.stopLoading() }
                        else if browser.showingHome { browser.navigate() }
                        else { browser.reload() }
                    } label: {
                        Image(systemName: browser.loading ? "xmark" : browser.showingHome ? "arrow.right" : "arrow.clockwise")
                            .frame(width: 36, height: 44)
                    }.accessibilityLabel(browser.loading ? "Stop loading" : browser.showingHome ? "Go" : "Reload")
                }
                .padding(.horizontal, 12).background(.bar)
                if browser.loading { ProgressView(value: browser.progress).progressViewStyle(.linear).accessibilityLabel("Page loading") }
                Divider()
            }
            ZStack {
                WebView(webView: browser.webView, revealEnabled: browser.isFullscreen && !browser.websiteFullscreen, reveal: revealExit).opacity(browser.showingHome ? 0 : 1)
                if browser.showingHome { home }
                if let error = browser.error {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                        Text("Couldn’t open this page").font(.title2.bold())
                        Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Try again") { browser.navigate() }.buttonStyle(.borderedProminent)
                        Button("Dismiss") { browser.error = nil }
                    }
                    .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)
                }
            }
            if !browser.isFullscreen {
                Divider()
                HStack {
                    Button { browser.webView.goBack() } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                        .disabled(!browser.canGoBack).accessibilityLabel("Back")
                    Spacer()
                    Button { browser.webView.goForward() } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                        .disabled(!browser.canGoForward).accessibilityLabel("Forward")
                    Spacer()
                    Button { browser.home() } label: { Image(systemName: "house").frame(width: 44, height: 44) }.accessibilityLabel("Home")
                    Spacer()
                    Button { share = true } label: { Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44) }
                        .disabled(browser.currentURL?.scheme?.hasPrefix("http") != true).accessibilityLabel("Share page")
                }.padding(.horizontal, 16).background(.bar)
            }
        }
        .overlay(alignment: .topTrailing) {
            if browser.isFullscreen && !browser.websiteFullscreen && exitVisible {
                VStack(alignment: .trailing, spacing: 8) {
                    Button { browser.exitFullscreen() } label: {
                        Label("Exit fullscreen", systemImage: "arrow.down.right.and.arrow.up.left")
                            .padding(.horizontal, 12).frame(minHeight: 44)
                    }
                    .buttonStyle(.plain).background(.regularMaterial, in: Capsule())
                    .accessibilityIdentifier("exit-fullscreen")
                    Text("Tap with two fingers to show browser controls.")
                        .font(.caption).padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .frame(maxWidth: 250)
                        .allowsHitTesting(false)
                }.padding(12)
            }
        }
        .task(id: revealID) {
            guard browser.isFullscreen, !accessibleExit else { return }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { exitVisible = false }
        }
        .onChange(of: browser.isFullscreen) { _, _ in addressFocused = false; revealExit() }
        .onChange(of: browser.websiteFullscreen) { _, _ in revealExit() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { revealExit() } }
        .onChange(of: siteControls) { _, visible in if !visible { revealExit() } }
        .onChange(of: share) { _, visible in if !visible { revealExit() } }
        .onChange(of: hardware.picker == nil) { _, dismissed in if dismissed { revealExit() } }
        .onChange(of: hardware.permission == nil) { _, dismissed in if dismissed { revealExit() } }
        .onChange(of: hardware.notice == nil) { _, dismissed in if dismissed { revealExit() } }
        .onChange(of: browser.javaScriptDialog == nil) { _, dismissed in if dismissed { revealExit() } }
        .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.voiceOverStatusDidChangeNotification)) { _ in updateAccessibleExit() }
        .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.switchControlStatusDidChangeNotification)) { _ in updateAccessibleExit() }
        .confirmationDialog("Clear browsing history?", isPresented: $confirmClearHistory, titleVisibility: .visible) {
            Button("Clear history", role: .destructive) { browser.clearHistory() }
        } message: { Text("Removes visited pages from this device. Cookies and website data are kept.") }
        .sheet(isPresented: $siteControls) { SiteControls(browser: browser, hardware: hardware) }
        .sheet(item: $hardware.picker, onDismiss: { hardware.cancelSelection() }) { picker in
            DevicePicker(hardware: hardware, initial: picker).interactiveDismissDisabled()
        }
        .sheet(isPresented: $share) {
            if let url = browser.currentURL { ShareSheet(items: [url]) }
        }
        .sheet(item: $browser.javaScriptDialog, onDismiss: { browser.dismissJavaScriptDialog() }) { dialog in
            JavaScriptDialogView(dialog: dialog) { browser.javaScriptDialog = nil }
                .presentationDetents([.medium]).interactiveDismissDisabled()
        }
        .alert("Allow NFC access?", isPresented: Binding(get: { hardware.permission != nil }, set: { if !$0 { hardware.resolvePermission(false) } })) {
            Button("Don’t Allow", role: .cancel) { hardware.resolvePermission(false) }
            Button("Allow") { hardware.resolvePermission(true) }
        } message: {
            Text("\(hardware.permission?.origin ?? "This site") wants to read and write nearby NFC tags. Access lasts for this visit.")
        }
        .alert("Hardware", isPresented: Binding(get: { hardware.notice != nil }, set: { if !$0 { hardware.notice = nil } })) {
            Button("OK") { hardware.notice = nil }
        } message: { Text(hardware.notice ?? "") }
    }
    private func revealExit() { exitVisible = true; revealID = UUID() }
    private func updateAccessibleExit() {
        accessibleExit = UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
        revealExit()
    }
    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Image(systemName: "wand.and.stars").font(.system(size: 48, weight: .light)).foregroundStyle(.tint).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Wand Browser").font(.largeTitle.bold())
                    Text("The web, connected.").font(.title2).foregroundStyle(.secondary)
                }
                Text("Open a website to connect with nearby Bluetooth devices and NFC tags. You choose which sites get access.")
                    .font(.body).foregroundStyle(.secondary)
                Button { addressFocused = true } label: { Label("Open a website", systemImage: "globe").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                if !browser.history.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Recent pages").font(.title2.bold())
                            Spacer()
                            Button("Clear") { confirmClearHistory = true }
                                .accessibilityLabel("Clear browsing history")
                        }
                        LazyVStack(spacing: 0) {
                            ForEach(browser.history) { entry in
                                Button { addressFocused = false; browser.load(entry.url) } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "clock").foregroundStyle(.secondary)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(entry.title).font(.body).foregroundStyle(.primary).lineLimit(1)
                                            Text(entry.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        Spacer(minLength: 0)
                                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                    }
                                    .padding(.vertical, 12).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                if entry.id != browser.history.last?.id { Divider() }
                            }
                        }
                    }.accessibilityIdentifier("recent-pages")
                }
                VStack(alignment: .leading, spacing: 16) {
                    Label("Bluetooth device selection", systemImage: "antenna.radiowaves.left.and.right")
                    Label("Read and write NFC tags", systemImage: "wave.3.right")
                    Label("Permissions for this visit", systemImage: "hand.raised")
                }.font(.subheadline).foregroundStyle(.secondary)
            }.padding(28).frame(maxWidth: 520, alignment: .leading).frame(maxWidth: .infinity).padding(.top, 48)
        }.background(.background).accessibilityIdentifier("home-screen")
    }
}

private struct WebView: UIViewRepresentable {
    let webView: WKWebView
    let revealEnabled: Bool
    let reveal: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(reveal: reveal) }
    func makeUIView(context: Context) -> WKWebView {
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped))
        tap.numberOfTouchesRequired = 2
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.delegate = context.coordinator
        tap.isEnabled = revealEnabled
        context.coordinator.tap = tap
        webView.addGestureRecognizer(tap)
        return webView
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.reveal = reveal
        context.coordinator.tap?.isEnabled = revealEnabled
    }
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        if let tap = coordinator.tap { uiView.removeGestureRecognizer(tap) }
    }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var reveal: () -> Void
        weak var tap: UITapGestureRecognizer?
        init(reveal: @escaping () -> Void) { self.reveal = reveal }
        @objc func tapped() { reveal() }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    }
}

private struct DevicePicker: View {
    @ObservedObject var hardware: HardwareCoordinator
    let initial: DevicePickerState
    private var picker: DevicePickerState { hardware.picker ?? initial }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(picker.origin).font(.headline).textSelection(.enabled)
                    Text("Choose a Bluetooth device to share with this site for the current visit.").foregroundStyle(.secondary)
                }
                Section("Nearby devices") {
                    ForEach(picker.devices) { device in
                        Button { hardware.selectDevice(device.id) } label: {
                            HStack { Label(device.name, systemImage: "antenna.radiowaves.left.and.right"); Spacer(); Image(systemName: "chevron.right") }
                        }.accessibilityLabel("Connect to \(device.name)")
                    }
                    Text(picker.status).foregroundStyle(.secondary)
                    Button("Scan again") { hardware.retryScan() }
                }
                if !picker.services.isEmpty {
                    Section("Requested services") {
                        ForEach(picker.services, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
                    }
                }
            }
            .navigationTitle("Choose a device").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { hardware.cancelSelection() } } }
        }
    }
}

private struct SiteControls: View {
    @ObservedObject var browser: BrowserModel
    @ObservedObject var hardware: HardwareCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClear = false
    @State private var showPrivacy = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(hardware.originLabel).textSelection(.enabled)
                    if browser.currentURL?.scheme == "http" {
                        Label("This page is not secure. Hardware access is disabled.", systemImage: "lock.open").foregroundStyle(.secondary)
                    } else {
                        Text("Hardware permissions end when you leave, reload, or background this page.").foregroundStyle(.secondary)
                    }
                }
                if browser.canEnterFullscreen {
                    Section("Display") {
                        Button("Enter fullscreen") { browser.enterFullscreen(); dismiss() }
                            .accessibilityIdentifier("enter-fullscreen")
                        Toggle("Always open this site fullscreen", isOn: Binding(
                            get: { browser.alwaysFullscreen },
                            set: { enabled in browser.setAlwaysFullscreen(enabled); if enabled { dismiss() } }
                        )).accessibilityIdentifier("always-fullscreen")
                    }
                }
                Section("Bluetooth") {
                    if hardware.allowedDevices.isEmpty { Text("No devices allowed").foregroundStyle(.secondary) }
                    ForEach(hardware.allowedDevices) { device in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(device.name)
                                Text(device.connected ? "Connected" : "Allowed, disconnected").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if device.connected { Button("Disconnect") { hardware.disconnect(device.id) } }
                        }
                    }
                }
                Section("NFC") {
                    Text(hardware.nfcStatus)
                    if hardware.canRestartNFC { Button("Scan again") { dismiss(); hardware.restartNFC() } }
                }
                Section {
                    Button("Revoke hardware access", role: .destructive) { hardware.revoke() }
                        .disabled(hardware.allowedDevices.isEmpty && !hardware.hasNFCGrant)
                    Button("Clear website data", role: .destructive) { confirmClear = true }
                }
                Section {
                    Button("Privacy policy") { showPrivacy = true }
                        .accessibilityIdentifier("privacy-policy")
                    Text("Wand Browser \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Site controls").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showPrivacy) {
                NavigationStack {
                    PrivacyPolicyView()
                        .navigationTitle("Privacy policy")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showPrivacy = false } } }
                }
            }
            .confirmationDialog("Clear cookies and website data? You’ll be signed out of websites.", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear website data", role: .destructive) { dismiss(); Task { await browser.clearWebsiteData() } }
            }
        }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct JavaScriptDialogView: View {
    let dialog: JavaScriptDialog
    let dismiss: () -> Void
    @State private var text = ""
    var body: some View {
        NavigationStack {
            Form {
                Text(dialog.origin).font(.headline)
                Text(dialog.message)
                if dialog.kind == .prompt { TextField("Response", text: $text) }
                Button("OK") { dialog.complete(text); dismiss() }
                if dialog.kind != .alert { Button("Cancel", role: .cancel) { dialog.complete(nil); dismiss() } }
            }.navigationTitle("Website message").navigationBarTitleDisplayMode(.inline)
                .onAppear { text = dialog.text }
        }
    }
}

// A separate, offline web view with no hardware bridge or shared website storage.
private struct PrivacyPolicyView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.accessibilityIdentifier = "privacy-policy-content"
        if let url = Bundle.main.url(forResource: "PrivacyPolicy", withExtension: "html") {
            view.loadFileURL(url, allowingReadAccessTo: url)
        }
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
}

// UIKit owns the selection so replacing the address cannot retain String.Index
// ranges from an older value (SwiftUI TextSelection can trap on iOS 18).
private struct AddressField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = "Enter website address"
        field.accessibilityIdentifier = "address-field"
        field.textContentType = .URL
        field.keyboardType = .URL
        field.returnKeyType = .go
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        return field
    }
    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
        if isFocused && !field.isFirstResponder { field.becomeFirstResponder() }
        else if !isFocused && field.isFirstResponder { field.resignFirstResponder() }
    }
    @MainActor final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: AddressField
        init(_ parent: AddressField) { self.parent = parent }
        @objc func changed(_ field: UITextField) { parent.text = field.text ?? "" }
        func textFieldDidBeginEditing(_ field: UITextField) {
            if !parent.isFocused { parent.isFocused = true }
            // The tap's default caret placement completes before selecting all.
            DispatchQueue.main.async { [weak field] in
                guard let field, field.isFirstResponder else { return }
                field.selectAll(nil)
            }
        }
        func textFieldDidEndEditing(_ field: UITextField) {
            if parent.isFocused { parent.isFocused = false }
        }
        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            parent.isFocused = false
            field.resignFirstResponder()
            parent.onSubmit()
            return true
        }
    }
}
