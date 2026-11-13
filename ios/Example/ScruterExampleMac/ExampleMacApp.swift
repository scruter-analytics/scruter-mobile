import AppKit
import ScruterAnalytics
import SwiftUI

/// The example app of the SDK on a native Mac: a SwiftUI window named with `.scruterScreen`, an AppKit window whose
/// content view controller is counted on its own (`Reports`), and a custom event.
///
/// `ios/scripts/macos-run.sh` launches it against a local fake server (`SCRUTER_EXAMPLE_ENDPOINT`) with
/// `SCRUTER_EXAMPLE_AUTORUN=1`: it then comes to the front, opens the AppKit window, sends the event and quits, and the
/// script checks the batch sent at quit.
@main
struct ScruterExampleMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        let endpoint = ProcessInfo.processInfo.environment["SCRUTER_EXAMPLE_ENDPOINT"].flatMap(URL.init(string:))
        #if DEBUG
        Scruter.start(appId: "EXMPL01", debug: true, endpoint: endpoint, apiEndpoint: endpoint)
        #else
        Scruter.start(appId: "EXMPL01", endpoint: endpoint, apiEndpoint: endpoint)
        #endif
    }

    var body: some Scene {
        WindowGroup("Scruter Example") {
            HomeView()
                .scruterScreen("Mac Home")
        }
    }
}

struct HomeView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Atelier Mona").font(.title)
            Button("Export the orders") { Scruter.track("export", props: ["format": "csv"]) }
                .scruterId("export")
            Button("Open the reports") { ReportsWindow.open() }
        }
        .padding(40)
        .frame(minWidth: 320, minHeight: 200)
    }
}

/// An AppKit screen: counted as `Reports` when its window becomes key (its type name without `ViewController`).
final class ReportsViewController: NSViewController {
    override func loadView() {
        let label = NSTextField(labelWithString: "Reports")
        label.font = .systemFont(ofSize: 20)
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 160))
        label.frame = NSRect(x: 20, y: 70, width: 280, height: 30)
        v.addSubview(label)
        view = v
    }
}

enum ReportsWindow {
    private static var window: NSWindow?

    static func open() {
        let w = window ?? NSWindow(contentViewController: ReportsViewController())
        w.title = "Reports"
        window = w
        w.makeKeyAndOrderFront(nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["SCRUTER_EXAMPLE_AUTORUN"] == "1" else { return }
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { ReportsWindow.open() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { Scruter.track("export", props: ["format": "csv"]) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { NSApp.terminate(nil) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
