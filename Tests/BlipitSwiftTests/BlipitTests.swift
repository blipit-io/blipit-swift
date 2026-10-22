import XCTest
@testable import BlipitSwift

final class BlipitTests: XCTestCase {
    func testConfigureFillsBlipitOptions() {
        let options = Options()
        XCTAssertTrue(Blipit.configure(options, key: " blipit_pk_abc ", project: "7", environment: "test", release: "app@1.0.0", tracesSampleRate: 0.2, endpoint: "http://127.0.0.1:8080/"))
        XCTAssertEqual(options.key, "blipit_pk_abc")
        XCTAssertEqual(options.project, "7")
        XCTAssertEqual(options.environment, "test")
        XCTAssertEqual(options.release, "app@1.0.0")
        XCTAssertEqual(options.tracesSampleRate, 0.2)
        XCTAssertEqual(options.endpoint, "http://127.0.0.1:8080/")
        XCTAssertTrue(options.enabled)
    }

    func testSecurityContextDropsEmptyFields() {
        let context = Blipit.securityContext(kind: "login_failed", actor: "ana@example.com", ip: "10.0.0.1", target: "/login")
        XCTAssertEqual(context, ["kind": "login_failed", "actor": "ana@example.com", "ip": "10.0.0.1", "target": "/login"])
    }

    func testMissingKeyOrProjectStaysOffInsteadOfCrashing() {
        let options = Options()
        XCTAssertFalse(Blipit.configure(options, key: "", project: "7"))
        XCTAssertFalse(options.enabled)
        XCTAssertFalse(Blipit.configure(Options(), key: "blipit_pk_abc", project: " "))
        XCTAssertFalse(Blipit.start(key: "", project: "7"))
    }

    func testCaptureAliasesMatchOtherSdks() {
        let fromAlias: (Error) -> EventId = Blipit.captureException
        let fromMessage: (String, Level) -> EventId = Blipit.captureMessage
        XCTAssertNotNil(fromAlias)
        XCTAssertNotNil(fromMessage)
        XCTAssertEqual(Blipit.captureMessage("before start", level: .warning), .empty)
    }
}
