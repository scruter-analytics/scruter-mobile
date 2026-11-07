// swift-tools-version: 5.9
// The plugin for apps with Flutter's Swift Package Manager support. SCRUTER_SDK_PATH points at a local checkout of
// scruter-mobile for this repository's CI.
import Foundation
import PackageDescription

let local = ProcessInfo.processInfo.environment["SCRUTER_SDK_PATH"]

let package = Package(
    name: "scruter_flutter",
    platforms: [.iOS("15.0")],
    products: [.library(name: "scruter-flutter", targets: ["scruter_flutter"])],
    dependencies: [
        local.map { Package.Dependency.package(path: $0) }
            ?? .package(url: "https://github.com/scruter-analytics/scruter-mobile", from: "1.0.1")
    ],
    targets: [
        .target(
            name: "scruter_flutter",
            dependencies: [.product(name: "ScruterAnalytics", package: local.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "scruter-mobile")])
    ]
)
