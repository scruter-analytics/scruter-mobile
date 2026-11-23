// swift-tools-version:5.9
// Scruter Analytics for iOS: privacy-first analytics without IDFA, ATT prompt or identifier that outlives the day.
// Scruter CMP for iOS: the consent banner of Scruter CMP as a native sheet, and the proofs of every choice.
// Two independent products: an app takes one, the other or both. https://scruter.net · MIT licence.
import PackageDescription

let package = Package(
    name: "ScruterAnalytics",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "ScruterAnalytics", targets: ["ScruterAnalytics"]),
        .library(name: "ScruterCMP", targets: ["ScruterCMP"]),
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
        .target(
            name: "ScruterCMP",
            path: "ios/Sources/ScruterCMP",
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(
            name: "ScruterCMPTests",
            dependencies: ["ScruterCMP"],
            path: "ios/Tests/ScruterCMPTests"
        ),
        .testTarget(
            name: "ScruterAnalyticsTests",
            dependencies: ["ScruterAnalytics"],
            path: "ios/Tests/ScruterAnalyticsTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
