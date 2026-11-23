import ScruterCMP
import SwiftUI

/// The SwiftUI example of Scruter CMP: the start line, the app's settings entry, SDKs gated on the answer, ATT after
/// the CMP.
@main
struct CMPExampleApp: App {
    init() {
        // The snapshot tests run inside this app and drive the module themselves.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        Launch.prepare()
        #if DEBUG
        ScruterCMP.debug = true
        #endif
        // Your app's code in Scruter CMP.
        ScruterCMP.start(appId: "EXMPL02", endpoint: Launch.endpoint)
        Partners.shared.wire()
    }

    var body: some Scene {
        WindowGroup { RootView() }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            NavigationView { ShopView() }
                .navigationViewStyle(.stack)
                .tabItem { Label("Shop", systemImage: "bag") }
            NavigationView { SettingsView() }
                .navigationViewStyle(.stack)
                .tabItem { Label("Settings", systemImage: "gear") }
        }
    }
}

struct ShopView: View {
    @ObservedObject private var partners = Partners.shared

    var body: some View {
        List {
            Section("Bowls turned in the workshop") {
                ForEach(["Moon bowl", "Mist cup", "Dune plate", "Salt vase"], id: \.self) { Text($0) }
            }
            Section("Partners") {
                LabeledRow(title: "Analytics", value: partners.analyticsStarted ? "on" : "off", id: "analytics")
                LabeledRow(title: "Ads", value: partners.personalisedAds ? "personalised" : "non-personalised", id: "ads")
                LabeledRow(title: "Attribution", value: partners.attributionStarted ? "on" : "off", id: "attribution")
                LabeledRow(title: "Tracking (ATT)", value: partners.trackingStatus, id: "att")
                LabeledRow(title: "analytics_storage", value: partners.consentMode["analytics_storage"] ?? "denied", id: "gcm")
                LabeledRow(title: "IAB TCF", value: partners.tcf, id: "tcf")
                LabeledRow(title: "Legitimate interests", value: partners.tcfVendorLi, id: "tcf-vli")
            }
        }
        .navigationTitle("Atelier")
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in
            partners.refreshTcf()
        }
    }
}

struct LabeledRow: View {
    let title: String
    let value: String
    let id: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundColor(.secondary).accessibilityIdentifier("partner-" + id)
        }
    }
}

/// The app's settings: the entry that opens the preferences comes first (CMP.md, « The settings entry »).
struct SettingsView: View {
    @ObservedObject private var partners = Partners.shared

    var body: some View {
        List {
            Section("Privacy") {
                Button("Privacy choices") { ScruterCMP.showPreferences() }
                    .accessibilityIdentifier("privacy-choices")
                if let id = partners.consentId {
                    Text(id).font(.footnote.monospaced()).foregroundColor(.secondary).accessibilityIdentifier("consent-id")
                }
            }
            #if DEBUG
            Section("Debug") {
                // Forgets the choice and its IAB keys: the sheet shows again (debug builds only).
                Button("Forget my choice") { ScruterCMP.debugReset() }
                    .accessibilityIdentifier("debug-reset")
            }
            #endif
        }
        .navigationTitle("Settings")
    }
}
