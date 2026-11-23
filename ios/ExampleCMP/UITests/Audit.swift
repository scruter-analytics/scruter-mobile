import XCTest

enum Audit {
    /// `performAccessibilityAudit`, tried again when the simulator is too slow to finish it in time (code -56).
    @available(iOS 17.0, *)
    static func run(_ a: XCUIApplication, _ handler: @escaping (XCUIAccessibilityAuditIssue) -> Bool) throws {
        for attempt in 1...3 {
            do {
                try a.performAccessibilityAudit(for: .all, handler)
                return
            } catch let e as NSError where e.code == -56 && attempt < 3 {
                continue
            }
        }
    }
}
