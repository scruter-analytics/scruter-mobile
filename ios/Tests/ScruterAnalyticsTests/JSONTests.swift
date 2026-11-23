import XCTest
@testable import ScruterAnalytics

final class JSONTests: XCTestCase {
    func testRoundTrip() {
        let v: JSONValue = ["a": 1, "b": "x\"y\n", "c": [true, false, .null], "d": 34.5, "e": 34.0]
        let s = v.encodedString()
        XCTAssertEqual(s, #"{"a":1,"b":"x\"y\n","c":[true,false,null],"d":34.5,"e":34.0}"#)
        XCTAssertEqual(JSONValue.parse(s), v)
    }

    func testUnicodeEscapes() {
        XCTAssertEqual(JSONValue.parse(#""é😀""#), .string("é😀"))
        XCTAssertNil(JSONValue.parse("{\"a\":1,}"))
        XCTAssertNil(JSONValue.parse("[1 2]"))
    }
}
