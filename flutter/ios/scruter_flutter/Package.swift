// swift-tools-version: 5.9
// The plugin for apps with Flutter's Swift Package Manager support. SCRUTER_SDK_PATH points at a local checkout of
// scruter-mobile for this repository's CI.
//
// The modules the app takes (docs/CMP-MOBILE.md §3.16, M2) come from the `scruter` key of its pubspec.yaml, as the
// podspec and android/build.gradle read it: Scruter Analytics unless `analytics: false`, Scruter CMP with `cmp: true`.
// The app's pubspec.yaml is the first one above this package (Flutter's link to it in ios/Flutter/ephemeral/Packages),
// else above the directory the build runs in (`flutter build`, `flutter run`). SCRUTER_ANALYTICS and SCRUTER_CMP (`1`
// or `0`) override it for a build that reaches neither.
import Foundation
import PackageDescription

let env = ProcessInfo.processInfo.environment
let local = env["SCRUTER_SDK_PATH"]

/// The `scruter:` block of the app's pubspec.yaml: the first one, not the plugin's own, above this package or the build's
/// directory.
func appModules() -> [String: Bool] {
    let starts = [Context.packageDirectory + "/x", env["PWD"].map { $0 + "/x" }, FileManager.default.currentDirectoryPath + "/x"]
    for start in starts.compactMap({ $0 }) {
        if let found = pubspecModules(above: URL(fileURLWithPath: start)) { return found }
    }
    return [:]
}

func pubspecModules(above start: URL) -> [String: Bool]? {
    var dir = start
    for _ in 0..<12 {
        dir.deleteLastPathComponent()
        guard let text = try? String(contentsOf: dir.appendingPathComponent("pubspec.yaml"), encoding: .utf8) else { continue }
        if text.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "name: scruter_flutter" }) {
            continue
        }
        var out: [String: Bool] = [:]
        var inside = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            if line.hasPrefix("scruter:") {
                inside = true
                // The flow form: `scruter: { cmp: true, analytics: false }`.
                for pair in line.dropFirst(8).trimmingCharacters(in: CharacterSet(charactersIn: " {}")).split(separator: ",") {
                    let kv = pair.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
                    if kv.count == 2 { out[kv[0]] = kv[1] == "true" }
                }
                continue
            }
            guard inside else { continue }
            if let c = line.first, !c.isWhitespace { break }
            let kv = line.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2, !kv[0].isEmpty { out[kv[0]] = kv[1] == "true" }
        }
        return out
    }
    return nil
}

let declared = appModules()
let analytics = env["SCRUTER_ANALYTICS"].map { $0 == "1" } ?? (declared["analytics"] ?? true)
let cmp = env["SCRUTER_CMP"].map { $0 == "1" } ?? (declared["cmp"] ?? false)
let sdkPackage = local.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "scruter-mobile"

var dependencies: [Target.Dependency] = []
var excluded: [String] = []
var conditions: [SwiftSetting] = []
if analytics {
    dependencies.append(.product(name: "ScruterAnalytics", package: sdkPackage))
    conditions.append(.define("SCRUTER_ANALYTICS"))
} else {
    excluded.append("ScruterAnalyticsPlugin.swift")
}
if cmp {
    dependencies.append(.product(name: "ScruterCMP", package: sdkPackage))
    conditions.append(.define("SCRUTER_CMP"))
} else {
    excluded.append("ScruterCMPPlugin.swift")
}

let package = Package(
    name: "scruter_flutter",
    platforms: [.iOS("15.0")],
    products: [.library(name: "scruter-flutter", targets: ["scruter_flutter"])],
    dependencies: [
        local.map { Package.Dependency.package(path: $0) }
            ?? .package(url: "https://github.com/scruter-analytics/scruter-mobile", from: "1.2.0")
    ],
    targets: [
        .target(name: "scruter_flutter", dependencies: dependencies, exclude: excluded, swiftSettings: conditions)
    ]
)
