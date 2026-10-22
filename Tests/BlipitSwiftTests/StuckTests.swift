import XCTest
@testable import BlipitSwift

final class StuckTests: XCTestCase {
    let limits = StuckLimits(startupMs: 20_000, flowMs: 60_000)

    func testFlowIsStuckOnlyAfterItsTimeOnScreen() {
        let watch = FlowWatch()
        watch.setForeground(true, now: 0)
        watch.start("sign-in", now: 0)
        watch.step("sign-in", "google-picker")
        XCTAssertTrue(watch.due(now: 59_999, limits: limits).isEmpty)
        XCTAssertEqual(watch.due(now: 60_000, limits: limits), [StuckFlow(name: "sign-in", step: "google-picker", waitedMs: 60_000)])
        XCTAssertTrue(watch.due(now: 120_000, limits: limits).isEmpty, "a stuck flow is reported once")
    }

    func testTimeInTheBackgroundDoesNotCount() {
        let watch = FlowWatch()
        watch.start(FlowWatch.startup, now: 0)
        XCTAssertTrue(watch.due(now: 100_000, limits: limits).isEmpty)
        watch.setForeground(true, now: 100_000)
        watch.setForeground(false, now: 110_000)
        watch.setForeground(true, now: 500_000)
        XCTAssertTrue(watch.due(now: 509_999, limits: limits).isEmpty)
        XCTAssertEqual(watch.due(now: 510_000, limits: limits).first?.waitedMs, 20_000)
    }

    func testEndedFlowsAndMissingLimitsStayQuiet() {
        let watch = FlowWatch()
        watch.setForeground(true, now: 0)
        watch.start("pay", now: 0)
        XCTAssertTrue(watch.due(now: 1_000_000, limits: nil).isEmpty)
        XCTAssertTrue(watch.end("pay"))
        XCTAssertFalse(watch.end("pay"))
        XCTAssertFalse(watch.step("pay", "sheet"))
        XCTAssertTrue(watch.due(now: 1_000_000, limits: limits).isEmpty)
    }

    func testLimitsAndEventShape() throws {
        XCTAssertEqual(StuckLimits.from(["startup_ms": 20_000, "flow_ms": 60_000, "exit_reasons": ["low_memory"]]), limits)
        XCTAssertNil(StuckLimits.from(["flow_ms": 1]))
        let body = StuckEvent.build(stuck: ["kind": "flow", "flow": "sign-in", "waited_ms": 61_000], trail: [["category": "custom", "message": "flow sign-in started"]], release: "app@1.0", environment: nil, os: "26.0", model: "iPhone17,1", at: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(body["message"] as? String, "stuck: flow sign-in")
        XCTAssertEqual(body["timestamp"] as? String, "1970-01-01T00:00:00.000Z")
        XCTAssertEqual(body["platform"] as? String, "other")
        XCTAssertNotNil((body["event_id"] as? String)?.range(of: "^[0-9a-f]{32}$", options: .regularExpression))
        XCTAssertEqual((body["sdk"] as? [String: String])?["name"], "blipit-swift")
        XCTAssertNil(body["environment"])
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: body))
        XCTAssertEqual(StuckEvent.name("  a \n b ", max: 64), "a b")
        XCTAssertNil(StuckEvent.name("  ", max: 64))
    }
}
