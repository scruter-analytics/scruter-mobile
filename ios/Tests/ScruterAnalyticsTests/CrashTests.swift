import Foundation
import XCTest

@testable import ScruterAnalytics

final class CrashTests: XCTestCase {
    static func rawReport(session: String, time: Int64) -> String {
        """
        SCRUTER-CRASH 1
        time \(time)
        kind crash
        type EXC_BAD_ACCESS
        code KERN_INVALID_ADDRESS
        sig SIGSEGV
        ctx {"s":"\(session)","scr":"Payment","fg":1,"bc":[{"k":"screen","n":"Payment","t":\(time - 14000)},{"k":"event","n":"Apple Pay opened","t":\(time - 4000)}],"lt":\(time - 125000)}
        thread 1 0
        f 0x104a3c1f8
        f 0x104a3c000
        f 0x1a0001234
        thread 0 1
        f 0x1a0005678
        img 0x104a20000 0x40000 1F2E3D4C-5B6A-4978-8695-A4B3C2D1E0F9 arm64 1 AtelierMona
        img 0x1a0000000 0x100000 0A1B2C3D-4E5F-4061-8293-A4B5C6D7E8F9 arm64e 0 UIKitCore
        img 0x1b0000000 0x100000 0A1B2C3D-4E5F-4061-8293-A4B5C6D7E8FA arm64e 0 Unused
        end

        """
    }

    func testRawReportBecomesACrashItemOnItsSession() throws {
        let h = Harness()
        let e = h.boot()
        e.enterForeground()
        e.screen("Payment")
        let sid = e.current!.id
        e.persistAll()
        // The process crashes; the next launch reads the report.
        let e2 = h.boot()
        let raw = try XCTUnwrap(CrashReport.parseRaw(Data(Self.rawReport(session: sid, time: h.scheduler.now).utf8)))
        e2.crashReported(raw: raw)
        e2.flush()
        let batch = try XCTUnwrap(h.http.batches.last)
        let cr = try XCTUnwrap(batch["cr"]?.arrayValue?.first)
        XCTAssertEqual(cr["s"]?.stringValue, sid)
        XCTAssertEqual(cr["k"], "crash")
        XCTAssertEqual(cr["src"], "native")
        XCTAssertEqual(cr["ex"], ["type": "EXC_BAD_ACCESS", "code": "KERN_INVALID_ADDRESS", "sig": "SIGSEGV"])
        XCTAssertEqual(cr["scr"], "Payment")
        XCTAssertEqual(cr["up"], 125000)
        XCTAssertEqual(cr["bc"]?.arrayValue?.count, 2)
        let threads = try XCTUnwrap(cr["th"]?.arrayValue)
        XCTAssertEqual(threads.count, 2)
        XCTAssertEqual(threads[0]["c"], 1)
        XCTAssertEqual(threads[0]["f"]?.arrayValue?.first, ["a": "0x104a3c1f8", "i": 0, "ia": 1])
        XCTAssertEqual(threads[1]["m"], 1)
        let images = try XCTUnwrap(cr["img"]?.arrayValue)
        XCTAssertEqual(images.map { $0["n"] }, ["AtelierMona", "UIKitCore"], "only the images the frames reference")
        let s = try XCTUnwrap(batch["s"]?.arrayValue?.first { $0["id"]?.stringValue == sid })
        XCTAssertEqual(s["c"]?["cr"], 1, "the crashed session's last state carries cr = 1")
        Harness.export(batch, name: "crash")
    }

    func testTruncatedReportIsIgnored() {
        XCTAssertNil(CrashReport.parseRaw(Data("SCRUTER-CRASH 1\ntime 5\nkind crash\n".utf8)))
        XCTAssertNil(CrashReport.parseRaw(Data()))
    }

    static let metricKitTree = """
        {"callStackPerThread":true,"callStacks":[{"threadAttributed":true,"callStackRootFrames":[{"binaryUUID":"1F2E3D4C-5B6A-4978-8695-A4B3C2D1E0F9","offsetIntoBinaryTextSegment":115192,"sampleCount":1,"binaryName":"AtelierMona","address":4372808184,"subFrames":[{"binaryUUID":"0A1B2C3D-4E5F-4061-8293-A4B5C6D7E8F9","offsetIntoBinaryTextSegment":4660,"sampleCount":1,"binaryName":"UIKitCore","address":6979326516}]}]}]}
        """

    func testMetricKitDiagnosticIsDeduplicated() throws {
        let h = Harness()
        let e = h.boot()
        e.enterForeground()
        e.screen("Payment")
        let sid = e.current!.id
        e.persistAll()
        let crashTime = h.scheduler.now
        h.advance(seconds: 10)
        let e2 = h.boot()
        e2.crashReported(raw: CrashReport.parseRaw(Data(Self.rawReport(session: sid, time: crashTime).utf8))!)
        let tree = try XCTUnwrap(JSON.parse(Self.metricKitTree))
        let d = CrashReport.Diagnostic(
            kind: "crash", time: crashTime + 1000, callStackTree: tree, exceptionType: 1, exceptionCode: 0, signal: 11,
            reason: nil)
        e2.diagnostic(d, inApp: { $0 == "AtelierMona" })
        XCTAssertEqual(e2.queue.items.filter { $0.kind == .crash }.count, 1, "MetricKit's copy of the same crash is dropped")
    }

    func testMetricKitAloneNamesTheSessionThatDied() throws {
        let h = Harness()
        let e = h.boot()
        e.enterForeground()
        e.screen("Payment")
        let sid = e.current!.id
        e.persistAll()
        let crashTime = h.scheduler.now + 500
        h.advance(seconds: 60)
        let e2 = h.boot()
        e2.enterForeground()
        let tree = try XCTUnwrap(JSON.parse(Self.metricKitTree))
        e2.diagnostic(
            CrashReport.Diagnostic(
                kind: "crash", time: crashTime, callStackTree: tree, exceptionType: 1, exceptionCode: 0, signal: 11,
                reason: "*** -[__NSArrayM objectAtIndex:]: index 3 beyond bounds"),
            inApp: { $0 == "AtelierMona" })
        e2.flush()
        let cr = try XCTUnwrap(h.http.batches.last?["cr"]?.arrayValue?.first)
        XCTAssertEqual(cr["s"]?.stringValue, sid)
        XCTAssertEqual(cr["ex"]?["type"], "EXC_BAD_ACCESS")
        XCTAssertEqual(cr["ex"]?["sig"], "SIGSEGV")
        XCTAssertEqual(cr["img"]?.arrayValue?.first?["la"], "0x104a20000")
        XCTAssertEqual(cr["th"]?.arrayValue?.first?["f"]?.arrayValue?.first?["ia"], 1)
        XCTAssertEqual(cr["bc"]?.arrayValue?.first?["n"], "Payment")
        Harness.export(h.http.batches.last!, name: "metrickit-crash")
    }

    func testCrashesOffInTheConfiguration() {
        let h = Harness()
        h.http.respond = { req in
            req.url.path.hasSuffix("config")
                ? HTTPResponse(status: 200, headers: [:], body: Data(#"{"v":1,"on":1,"e":"e3","cr":0,"ttl":3600}"#.utf8))
                : HTTPResponse(status: 202, headers: [:], body: Data("{}".utf8))
        }
        let e = h.boot()
        e.enterForeground()
        e.reportError(kind: "nonfatal", src: "js", type: "TypeError", reason: "x", frames: [["fn": "f"]], debugIds: [:])
        XCTAssertTrue(e.queue.items.filter { $0.kind == .crash }.isEmpty)
    }

    func testCrossPlatformErrorReport() throws {
        let h = Harness()
        h.device.sdkName = "react_native"
        let e = h.boot()
        e.enterForeground()
        e.screen("Cart")
        e.reportError(
            kind: "crash", src: "js", type: "TypeError", reason: "undefined is not a function",
            frames: [["fn": "addToCart", "fl": "index.bundle", "l": 1, "co": 4242, "ia": 1]], debugIds: ["bun": "abc-123"])
        e.flush()
        let b = try XCTUnwrap(h.http.batches.last)
        XCTAssertTrue(b["sdk"]?.stringValue?.hasPrefix("react_native/") ?? false)
        XCTAssertEqual(b["cr"]?.arrayValue?.first?["bun"], "abc-123")
        Harness.export(b, name: "js-crash")
    }
}
