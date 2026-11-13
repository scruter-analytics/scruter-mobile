#if (canImport(UIKit) && !os(watchOS)) || os(macOS)
import Foundation
#if canImport(UIKit)
import UIKit
#endif

#if canImport(MetricKit)
import MetricKit
#endif

#if canImport(ScruterCrash)
import ScruterCrash
#endif

/// Crash capture on iOS and macOS (docs/MOBILE.md §3.10): ScruterCrash's signal, Mach and exception handlers write a
/// report at the crash; MetricKit's crash and hang diagnostics are the second source, de-duplicated.
enum Crashes {
    static func reportPath(_ store: FileStore) -> String {
        store.url("crash.report").path
    }

    /// The previous process's report, read before the handlers are installed again (engine queue).
    static func collectPending(engine: Engine) {
        let store = engine.env.store
        guard let data = store.read("crash.report"), !data.isEmpty else { return }
        // Emptied at once: a report is read only once.
        store.write("crash.report", Data())
        if let raw = CrashReport.parseRaw(data) {
            engine.crashReported(raw: raw)
        }
    }

    /// A cross-platform layer reported its fatal error: the native abort that follows is the same crash.
    static func muteNativeReports() {
        scruter_crash_mute(5000)
    }

    private static var previousExceptionHandler: (@convention(c) (NSException) -> Void)?

    /// Installs the handlers (main thread: the signal stack is the main thread's). Not under a debugger's Mach ports,
    /// and the previous handlers are chained.
    static func install(path: String) {
        guard scruter_crash_installed() == 0 else { return }
        _ = path.withCString { scruter_crash_install($0, 1) }
        previousExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            let addresses = exception.callStackReturnAddresses.map { UInt($0.uintValue) }
            let reason = exception.reason ?? ""
            exception.name.rawValue.withCString { type in
                reason.withCString { r in
                    addresses.withUnsafeBufferPointer { buf in
                        _ = scruter_crash_write_exception(type, r, buf.baseAddress, buf.count)
                    }
                }
            }
            Crashes.previousExceptionHandler?(exception)
        }
    }
}

#if canImport(MetricKit)
/// MetricKit's diagnostics (iOS 14+, macOS 12+): crashes and hangs ≥ 2 s (`anr`), delivered at a later launch.
final class MetricKitSubscriber: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricKitSubscriber()
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        MXMetricManager.shared.add(shared)
    }

    // Metric payloads are not used, and macOS SDKs before macOS 26 mark `MXMetricPayload` unavailable: the optional
    // requirement is left out there (crash and hang diagnostics below exist on macOS 12+).
    #if !os(macOS)
    func didReceive(_ payloads: [MXMetricPayload]) {}
    #endif

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        var diagnostics: [CrashReport.Diagnostic] = []
        for payload in payloads {
            let time = Int64(payload.timeStampEnd.timeIntervalSince1970 * 1000)
            for c in payload.crashDiagnostics ?? [] {
                guard let tree = JSON.parse(c.callStackTree.jsonRepresentation()) else { continue }
                var reason: String?
                if #available(iOS 17.0, macOS 14.0, *), let r = c.exceptionReason {
                    reason = r.className + ": " + r.composedMessage
                } else {
                    reason = c.terminationReason
                }
                diagnostics.append(
                    CrashReport.Diagnostic(
                        kind: "crash", time: time, callStackTree: tree, exceptionType: c.exceptionType?.intValue,
                        exceptionCode: c.exceptionCode?.intValue, signal: c.signal?.intValue, reason: reason))
            }
            for h in payload.hangDiagnostics ?? [] {
                guard let tree = JSON.parse(h.callStackTree.jsonRepresentation()) else { continue }
                diagnostics.append(
                    CrashReport.Diagnostic(
                        kind: "anr", time: time, callStackTree: tree, exceptionType: nil, exceptionCode: nil, signal: nil,
                        reason: "Hang " + String(Int(h.hangDuration.converted(to: .milliseconds).value)) + " ms"))
            }
        }
        guard !diagnostics.isEmpty else { return }
        let inApp = MetricKitSubscriber.inAppImages()
        Runtime.shared.run { engine in
            for d in diagnostics { engine.diagnostic(d, inApp: { inApp.contains($0) }) }
        }
    }

    /// The app's own binaries: its executable and its embedded frameworks.
    static func inAppImages() -> [String] {
        var names = [String]()
        if let exe = Bundle.main.executableURL?.lastPathComponent { names.append(exe) }
        if let fw = Bundle.main.privateFrameworksURL,
            let items = try? FileManager.default.contentsOfDirectory(atPath: fw.path)
        {
            for i in items { names.append((i as NSString).deletingPathExtension) }
        }
        return names
    }
}
#else
enum MetricKitSubscriber {
    static func install() {}
}
#endif
#endif
