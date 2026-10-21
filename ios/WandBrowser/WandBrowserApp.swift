import SwiftUI

@main
struct WandBrowserApp: App {
    @StateObject private var browser = BrowserModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            BrowserView(browser: browser)
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
