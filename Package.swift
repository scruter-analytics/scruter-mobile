// swift-tools-version:5.9
// Scruter Analytics for iOS: privacy-first analytics without IDFA, ATT prompt or identifier that outlives the day.
// https://scruter.net · MIT licence.
import PackageDescription

let package = Package(
    name: "ScruterAnalytics",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "ScruterAnalytics", targets: ["ScruterAnalytics"])
    ],
    targets: [
        .target(
            name: "ScruterCrash",
            path: "ios/Sources/ScruterCrash"
        ),
        .target(
            name: "ScruterAnalytics",
            dependencies: ["ScruterCrash"],
            path: "ios/Sources/ScruterAnalytics",
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(
            name: "ScruterAnalyticsTests",
            dependencies: ["ScruterAnalytics"],
            path: "ios/Tests/ScruterAnalyticsTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
