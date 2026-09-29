import XCTest
import Sentry
@testable import BlipitSwift

final class BlipitTests: XCTestCase {
    func testDsnIsBuiltFromKeyAndProject() {
        XCTAssertEqual(Blipit.dsn(key: "blipit_pk_abc", project: "7"), "https://blipit_pk_abc@in.blipit.io/7")
        XCTAssertEqual(Blipit.dsn(key: "k", project: "9", endpoint: "http://127.0.0.1:8080/"), "http://k@127.0.0.1:8080/9")
    }

    func testConfigureSetsDsnAndOptions() {
        let options = Options()
        Blipit.configure(options, key: "blipit_pk_abc", project: "7", environment: "test", release: "app@1.0.0", tracesSampleRate: 0.2)
        XCTAssertEqual(options.dsn, "https://blipit_pk_abc@in.blipit.io/7")
        XCTAssertEqual(options.environment, "test")
        XCTAssertEqual(options.releaseName, "app@1.0.0")
        XCTAssertEqual(options.tracesSampleRate?.doubleValue, 0.2)
        XCTAssertFalse(options.sendDefaultPii)
    }

    func testSecurityContextDropsEmptyFields() {
        let context = Blipit.securityContext(kind: "login_failed", actor: "ana@example.com", ip: "10.0.0.1", target: "/login")
        XCTAssertEqual(context, ["kind": "login_failed", "actor": "ana@example.com", "ip": "10.0.0.1", "target": "/login"])
    }
}
