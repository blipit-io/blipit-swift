import XCTest
import Sentry
@testable import BlipitSwift

final class StartupTests: XCTestCase {
    private var now: TimeInterval = 0
    private func clock(_ deadline: TimeInterval = 20) -> StartupClock { StartupClock(deadline: deadline, now: { [unowned self] in self.now }) }

    func testFiresOnceAfterDeadlineWithoutReady() {
        let c = clock()
        c.foreground()
        now = 19.999
        XCTAssertFalse(c.check())
        now = 20
        XCTAssertTrue(c.check())
        now = 60
        XCTAssertFalse(c.check())
        XCTAssertTrue(c.stalled)
    }

    func testDoesNotFireWhenReadyInTime() {
        let c = clock()
        c.foreground()
        now = 5
        XCTAssertEqual(c.markReady(), 5)
        now = 60
        XCTAssertFalse(c.check())
        XCTAssertFalse(c.armed)
        XCTAssertNil(c.markReady())
    }

    func testClockPausesInBackground() {
        let c = clock()
        c.foreground()
        now = 10
        c.background()
        now = 500
        XCTAssertEqual(c.elapsed(), 10)
        XCTAssertFalse(c.check())
        c.foreground()
        now = 509.5
        XCTAssertFalse(c.check())
        XCTAssertEqual(c.remaining(), 0.5, accuracy: 0.0001)
        now = 510
        XCTAssertTrue(c.check())
    }

    func testNotStartedUntilForeground() {
        let c = clock()
        now = 100
        XCTAssertFalse(c.check())
        XCTAssertEqual(c.elapsed(), 0)
    }

    func testDisabledWithZero() {
        let c = clock(0)
        c.foreground()
        now = 1000
        XCTAssertFalse(c.armed)
        XCTAssertFalse(c.check())
    }

    func testLateReadyIsMeasuredWithoutSecondEvent() {
        let c = clock()
        c.foreground()
        now = 20
        XCTAssertTrue(c.check())
        now = 31
        XCTAssertEqual(c.markReady(), 31)
        XCTAssertTrue(c.stalled)
        XCTAssertFalse(c.check())
    }

    func testMessageNamesTheDeadline() {
        XCTAssertEqual(Startup.message(20), "App did not become ready within 20 s")
        XCTAssertEqual(Startup.message(7.5), "App did not become ready within 7.5 s")
    }

    func testStalledStartupSendsOneGroupedWarning() {
        let lock = NSLock()
        var sent: [Event] = []
        let stalled = expectation(description: "stall event")
        XCTAssertTrue(Blipit.start(key: "blipit_pk_test", project: "7", endpoint: "http://127.0.0.1:9", startupDeadline: 1) { options in
            options.beforeSend = { event in
                lock.lock()
                sent.append(event)
                lock.unlock()
                if event.message?.formatted.hasPrefix("App did not become ready") == true { stalled.fulfill() }
                return nil
            }
        })
        Blipit.addBreadcrumb("signed in", category: "startup")
        wait(for: [stalled], timeout: 10)
        Blipit.reportReady()
        Blipit.reportReady()
        Thread.sleep(forTimeInterval: 0.5)
        lock.lock()
        let stalls = sent.filter { $0.message?.formatted.hasPrefix("App did not become ready") == true }
        lock.unlock()
        XCTAssertEqual(stalls.count, 1)
        let event = stalls[0]
        XCTAssertEqual(event.message?.formatted, "App did not become ready within 1 s")
        XCTAssertEqual(event.level, .warning)
        XCTAssertEqual(event.fingerprint, ["blipit-startup-stalled"])
        XCTAssertEqual(event.tags?["startup.stalled"], "true")
        XCTAssertEqual(event.tags?["startup.deadline_ms"], "1000")
        XCTAssertTrue(event.breadcrumbs?.contains { $0.message == "signed in" } == true)
        SentrySDK.close()
    }
}
