import SwiftUI
import Combine
import WebKit

@main
struct WandBrowserApp: App {
    @StateObject private var session = BrowserSession()
    private var browser: BrowserModel { session.browser }
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 0) {
                ProfileControls(session: session, browser: browser)
                BrowserView(browser: browser).id(ObjectIdentifier(browser)).disabled(session.switching)
            }
                .onChange(of: phase) { _, next in
                    // System permission/NFC sheets can make the scene inactive.
                    // Only genuine backgrounding ends a visit.
                    if next == .background {
                        browser.dismissJavaScriptDialog()
                        browser.hardware.setForeground(false)
                    } else if next == .active { browser.hardware.setForeground(true) }
                }
        }
    }
}

@MainActor
final class BrowserSession: ObservableObject {
    @Published var browser = BrowserModel()
    @Published var profiles: [SiteProfile] = []
    @Published var error: String?
    @Published var switching = false
    private var registry: SiteProfileRegistry?
    init() {
        do { registry = try SiteProfileRegistry(); profiles = registry!.profiles }
        catch { self.error = error.localizedDescription }
        configureProfileAPI()
    }
    private func configureProfileAPI() {
        let current = browser
        current.hardware.profileState = { [weak current] in
            .object(["policy": .string(SiteProfile.policy),
                     "active": .bool(current?.profile != nil),
                     "origin": current?.profile.map { .string($0.origin) } ?? .null,
                     "strictEmbeddedIsolation": .bool(false), "attestation": .bool(false)])
        }
        current.hardware.cancelProfile = { [weak current] in current?.dismissJavaScriptDialog() }
        current.hardware.requestProfile = { [weak self, weak current] in
            guard let self, let current, self.browser === current, !self.switching,
                  let url = current.currentURL, let origin = SiteOrigin(url: url), origin.scheme == "https" else {
                throw WebError.aborted
            }
            if current.profile != nil { return current.hardware.profileState!() }
            guard current.javaScriptDialog == nil else {
                throw WebError("InvalidStateError", "Another dialog is open.")
            }
            let token = current.hardware.document.token
            let approved: Bool = await withCheckedContinuation { continuation in
                current.javaScriptDialog = JavaScriptDialog(origin: origin.display,
                    message: "Open \(origin.display) in a site profile? This uses separate storage and a fresh login, and locks top-level browsing to this origin. Embedded content follows normal WebKit rules.",
                    kind: .confirm) { continuation.resume(returning: $0 != nil) }
            }
            guard current.hardware.document.token == token, self.browser === current,
                  current.hardware.foreground else { throw WebError.aborted }
            guard approved else { throw WebError("NotAllowedError", "Profile request denied.") }
            await self.create(url)
            // Replacing the document invalidates its bridge request; read state in the new page.
            throw WebError.aborted
        }
    }
    func open(_ profile: SiteProfile?, url: URL? = nil) async {
        guard !switching else { return }
        if let profile {
            guard registry?.profiles.contains(where: { $0.id == profile.id && !$0.deletionPending }) == true else { return }
        }
        switching = true
        defer { switching = false }
        let defaults: UserDefaults
        if let profile {
            guard let scoped = UserDefaults(suiteName: "browser.profile." + profile.id.uuidString) else {
                error = "Could not open profile preferences."; return
            }
            defaults = scoped
        } else { defaults = .standard }
        await browser.retire()
        browser = BrowserModel(historyDefaults: defaults, profile: profile)
        configureProfileAPI()
        if let url = url ?? profile.flatMap({ URL(string: $0.origin) }) { browser.load(url) }
    }
    func create(_ url: URL) async {
        do {
            guard !switching, let registry else { return }
            let profile = try registry.createOrReopen(url)
            profiles = registry.profiles
            await open(profile, url: url)
        } catch { self.error = error.localizedDescription }
    }
    func delete(_ profile: SiteProfile) async {
        guard !switching, let registry else { return }
        do {
            try registry.markForDeletion(profile.id)
            profiles = registry.profiles
            if browser.profile?.id == profile.id { await open(nil) }
            switching = true
            defer { switching = false }
            try await WKWebsiteDataStore.remove(forIdentifier: profile.id)
            UserDefaults.standard.removePersistentDomain(forName: "browser.profile." + profile.id.uuidString)
            try registry.finishDeletion(profile.id)
            profiles = registry.profiles
        } catch { self.error = error.localizedDescription }
    }
}

private struct ProfileControls: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject var browser: BrowserModel
    @State private var requestedURL: URL?
    @State private var deleting: SiteProfile?
    var body: some View {
        HStack {
            Menu {
                Button("Ordinary browsing") { Task { await session.open(nil) } }
                ForEach(session.profiles) { profile in
                    if profile.deletionPending {
                        Button("Retry deletion: " + profile.origin) { Task { await session.delete(profile) } }
                    } else {
                        Button(profile.origin) { Task { await session.open(profile) } }
                    }
                }
                if let url = browser.currentURL, url.scheme == "https", browser.profile == nil {
                    Button("Open in site profile") { requestedURL = url }
                }
                if let profile = browser.profile {
                    Button("Delete profile", role: .destructive) { deleting = profile }
                }
            } label: {
                Label(browser.profile?.origin ?? "Ordinary browsing", systemImage: "person.crop.rectangle")
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(8).background(.bar).disabled(session.switching)
        .confirmationDialog("Create a site profile?", isPresented: Binding(get: { requestedURL != nil }, set: { if !$0 { requestedURL = nil } })) {
            Button("Create profile") {
                if let url = requestedURL { Task { await session.create(url) } }
                requestedURL = nil
            }
        } message: {
            Text("\(requestedURL.flatMap(SiteOrigin.init(url:))?.display ?? "This site") will use separate storage and a fresh login. Top-level browsing stays on this exact HTTPS origin. Embedded content follows normal WebKit rules.")
        }
        .confirmationDialog("Delete this profile and all its website data?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let profile = deleting { Task { await session.delete(profile) } }
                deleting = nil
            }
        }
        .confirmationDialog("Open outside this profile?", isPresented: Binding(get: { browser.externalDestination != nil }, set: { if !$0 { browser.externalDestination = nil } })) {
            Button("Open in ordinary browsing") {
                if let url = browser.externalDestination { Task { await session.open(nil, url: url) } }
                browser.externalDestination = nil
            }
        } message: { Text(browser.externalDestination?.absoluteString ?? "") }
        .alert("Profile error", isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })) {
            Button("OK") { session.error = nil }
        } message: { Text(session.error ?? "") }
    }
}
