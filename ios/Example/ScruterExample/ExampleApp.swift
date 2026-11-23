import ScruterAnalytics
import SwiftUI

/// The example app of the Scruter iOS SDK: SwiftUI screens (named with `.scruterScreen`) and UIKit screens (named
/// automatically), a list, a form and a masked view.
@main
struct ScruterExampleApp: App {
    init() {
        // The tests start the SDK themselves, against a fake server.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            #if DEBUG
            Scruter.start(appId: "EXMPL01", debug: true)
            #else
            Scruter.start(appId: "EXMPL01")
            #endif
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .onOpenURL { Scruter.handle(url: $0) }
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            NavigationView { ShopView() }
                .navigationViewStyle(.stack)
                .tabItem { Label("SwiftUI", systemImage: "bag") }
            UIKitShop()
                .ignoresSafeArea()
                .tabItem { Label("UIKit", systemImage: "square.grid.2x2") }
            NavigationView { SettingsView() }
                .navigationViewStyle(.stack)
                .tabItem { Label("Settings", systemImage: "gear") }
        }
    }
}

struct Product: Identifiable, Hashable {
    let id: Int
    let name: String
    let price: Double

    static let all = (1...30).map { Product(id: $0, name: "Ceramic bowl \($0)", price: 12 + Double($0)) }
}

/// A SwiftUI list.
struct ShopView: View {
    var body: some View {
        List(Product.all) { p in
            NavigationLink(destination: ProductView(product: p)) {
                HStack {
                    Text(p.name)
                    Spacer()
                    Text(String(format: "%.2f €", p.price)).foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("Shop")
        .scruterScreen("Shop")
    }
}

/// A SwiftUI screen with a scroll view, a button with a Scruter identifier and a masked view.
struct ProductView: View {
    let product: Product
    @State private var message = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.3)).frame(height: 320)
                Text(product.name).font(.title)
                Text(String(format: "%.2f €", product.price))
                Button("Add to cart") {
                    Scruter.track("Add to cart", props: ["product": product.name], revenue: product.price, currency: "EUR")
                }
                .buttonStyle(.borderedProminent)
                .scruterId("addToCart", label: "Add to cart")
                Text("Gift message").font(.headline)
                TextField("Your message", text: $message).textFieldStyle(.roundedBorder)
                VStack(alignment: .leading) {
                    Text("Delivery address")
                    Text("12 Potter Street, London")
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .scruterMask()
                ForEach(0..<12) { i in
                    Text("Review \(i + 1): lovely glaze, sturdy, the right size for soup.").padding(.vertical, 4)
                }
            }
            .padding()
        }
        .navigationTitle("Product")
        .scruterScreen("Product")
    }
}

/// The app's "Audience measurement" setting, wired to `Scruter.optOut()` / `optIn()`.
struct SettingsView: View {
    @State private var measured = !Scruter.isOptedOut

    var body: some View {
        Form {
            Toggle("Audience measurement", isOn: $measured)
                .onChange(of: measured) { on in on ? Scruter.optIn() : Scruter.optOut() }
            Section(footer: Text("Anonymous: no identifier that lasts beyond the day, no tracking.")) {
                Button("Send now") { Scruter.flush() }
            }
        }
        .navigationTitle("Settings")
        .scruterScreen("Settings")
    }
}

/// The UIKit part, in a navigation controller (automatic screen names).
struct UIKitShop: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UINavigationController {
        UINavigationController(rootViewController: CatalogViewController())
    }

    func updateUIViewController(_ vc: UINavigationController, context: Context) {}
}
