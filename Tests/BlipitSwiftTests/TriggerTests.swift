import XCTest
@testable import BlipitSwift

final class TriggerTests: XCTestCase {
    func testOneShakeOpensOneReporter() {
        var gate = TriggerGate()
        XCTAssertTrue(gate.allow(now: 10, busy: false))
        XCTAssertFalse(gate.allow(now: 10.4, busy: false))
        XCTAssertFalse(gate.allow(now: 11.4, busy: false))
        XCTAssertTrue(gate.allow(now: 11.6, busy: false))
    }

    func testNoTriggerWhileAReporterIsOpen() {
        var gate = TriggerGate()
        XCTAssertFalse(gate.allow(now: 50, busy: true))
        XCTAssertTrue(gate.allow(now: 50.1, busy: false), "a refused trigger does not start the quiet time")
    }

    func testScreenshotPromptReportOpensOnce() {
        var state = PromptState()
        XCTAssertTrue(state.show(.screenshot, now: 0, reporterOpen: false))
        XCTAssertFalse(state.show(.screenshot, now: 1, reporterOpen: false), "one prompt at a time")
        XCTAssertEqual(state.choose(report: true), .screenshot)
        XCTAssertNil(state.kind)
        XCTAssertNil(state.choose(report: true))
    }

    func testNotNowAndTimeoutCloseWithoutReporting() {
        var state = PromptState()
        XCTAssertTrue(state.show(.screenshot, now: 0, reporterOpen: false))
        XCTAssertNil(state.choose(report: false))
        XCTAssertTrue(state.show(.screenshot, now: 10, reporterOpen: false))
        XCTAssertFalse(state.expire(now: 15.9))
        XCTAssertTrue(state.expire(now: 16))
        XCTAssertNil(state.kind)
    }

    func testOldTimerDoesNotCloseANewerPrompt() {
        var state = PromptState()
        XCTAssertTrue(state.show(.screenshot, now: 0, reporterOpen: false))
        _ = state.choose(report: false)
        XCTAssertTrue(state.show(.crash, now: 5, reporterOpen: false))
        XCTAssertFalse(state.expire(now: 6), "the first prompt's 6 s timer fires here")
        XCTAssertFalse(state.expire(now: 19.9))
        XCTAssertTrue(state.expire(now: 20), "the crash prompt waits 15 s")
    }

    func testNoPromptOverAnOpenReporter() {
        var state = PromptState()
        XCTAssertFalse(state.show(.screenshot, now: 0, reporterOpen: true))
        XCTAssertNil(state.kind)
    }

    func testShelfKeepsThreeEarlierDistinctScreensNewestFirst() {
        var shelf = ScreenShelf<Int>()
        for (i, name) in ["Home", "Cart", "Home", "Search", "Profile", "Orders"].enumerated() { shelf.add(name, i) }
        XCTAssertEqual(shelf.entries.map(\.name), ["Orders", "Profile", "Search", "Home"])
        XCTAssertEqual(shelf.earlier(than: "Orders"), [4, 3, 2])
        XCTAssertEqual(shelf.earlier(than: "Search"), [5, 4, 2])
        XCTAssertEqual(shelf.earlier(than: nil).count, 3)
    }

    func testShelfClearsAfterThreeMinutesAway() {
        var shelf = ScreenShelf<Int>()
        shelf.add("Home", 1)
        shelf.foreground(after: 179)
        XCTAssertEqual(shelf.entries.count, 1)
        shelf.foreground(after: 180)
        XCTAssertTrue(shelf.entries.isEmpty)
        shelf.add("Home", 1)
        shelf.clear()
        XCTAssertTrue(shelf.earlier(than: nil).isEmpty)
    }

    func testReportButtonSettingParsing() {
        XCTAssertTrue(ReportSettings.button(["report_button": true]))
        XCTAssertFalse(ReportSettings.button(["report_button": false]))
        XCTAssertFalse(ReportSettings.button(["report_button": "yes"]))
        XCTAssertFalse(ReportSettings.button([String: Any]()))
        XCTAssertFalse(ReportSettings.button(nil))
        XCTAssertFalse(ReportSettings.button([1, 2]))
    }

    func testCrashIdIsLinkedOnlyWhenValid() {
        let id = "0123456789abcdef0123456789ABCDEF"
        let body = ReportPayload.feedback(title: "", message: "it closed", email: nil, context: [:], shapes: [], imageSize: nil, screenshots: 0, recordings: 0, locale: "en", eventId: id)
        XCTAssertEqual(body["event_id"] as? String, id.lowercased())
        let bad = ReportPayload.feedback(title: "", message: "x", email: nil, context: [:], shapes: [], imageSize: nil, screenshots: 0, recordings: 0, locale: "en", eventId: "nope")
        XCTAssertNil(bad["event_id"])
        let none = ReportPayload.feedback(title: "", message: "x", email: nil, context: [:], shapes: [], imageSize: nil, screenshots: 0, recordings: 0, locale: "en")
        XCTAssertNil(none["event_id"])
    }

    func testButtonSettingsSendTheUserAndReadTheAnswer() {
        let client = ReportClient(endpoint: "https://in.example", key: "pk", session: StubProtocol.session())
        let done = expectation(description: "settings")
        var shown: Bool?
        client.buttonSettings(userId: "42", email: "ana@example.com") { shown = $0; done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(shown, false)
        let sent = StubProtocol.log.first { $0.path == "/api/v1/feedback/settings" }
        XCTAssertEqual(sent?.headers["X-Blipit-User-Id"], "42")
        XCTAssertEqual(sent?.headers["X-Blipit-User-Email"], "ana@example.com")
        XCTAssertEqual(sent?.headers["X-Blipit-Key"], "pk")
    }

    func testTriggerNamesMatchTheOtherSdks() {
        XCTAssertEqual([ReportTrigger.shake, .screenshot, .twoFinger, .crash].map(\.rawValue), ["shake", "screenshot", "two_finger", "crash"])
    }
}
