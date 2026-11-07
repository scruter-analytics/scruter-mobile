import XCTest
@testable import ScruterAnalytics

final class JSONTests: XCTestCase {
    func testRoundTrip() {
        let v: JSON = ["a": 1, "b": "x\"y\n", "c": [true, false, .null], "d": 34.5, "e": 34.0]
        let s = v.encodedString()
        XCTAssertEqual(s, #"{"a":1,"b":"x\"y\n","c":[true,false,null],"d":34.5,"e":34.0}"#)
        XCTAssertEqual(JSON.parse(s), v)
    }

    func testUnicodeEscapes() {
        XCTAssertEqual(JSON.parse(#""é😀""#), .string("é😀"))
        XCTAssertNil(JSON.parse("{\"a\":1,}"))
        XCTAssertNil(JSON.parse("[1 2]"))
    }
}
