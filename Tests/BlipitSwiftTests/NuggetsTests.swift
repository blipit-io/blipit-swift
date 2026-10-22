import XCTest
import BlipitNuggets
@testable import BlipitSwift

final class ScriptedProtocol: URLProtocol {
    enum Reply {
        case status(Int, [String: String], String)
        case offline
    }

    static var replies: [Reply] = []
    static var sent: [(path: String, headers: [String: String], body: [String: Any])] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        ScriptedProtocol.lock.lock()
        let reply = ScriptedProtocol.replies.isEmpty ? .status(202, [:], "{}") : ScriptedProtocol.replies.removeFirst()
        ScriptedProtocol.sent.append((request.url!.path, request.allHTTPHeaderFields ?? [:], (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]))
        ScriptedProtocol.lock.unlock()
        switch reply {
        case .offline:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        case let .status(code, headers, json):
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: headers.merging(["Content-Type": "application/json"]) { a, _ in a })!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(json.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    static func reset(_ replies: [Reply] = []) {
        lock.lock()
        self.replies = replies
        sent = []
        lock.unlock()
    }

    static var requests: [(path: String, headers: [String: String], body: [String: Any])] {
        lock.lock(); defer { lock.unlock() }
        return sent
    }
}

struct Boom: Error, CustomStringConvertible {
    let code: Int
    var description: String { "boom \(code)" }
}

final class NuggetsTests: XCTestCase {
    var dirs: [URL] = []
    var made: [Nuggets] = []

    override func tearDown() {
        for nuggets in made { nuggets.io.sync { nuggets.transport.stopped = true } }
        for dir in dirs { try? FileManager.default.removeItem(at: dir) }
        made = []
        dirs = []
        Nuggets.shared = nil
        Sessions.shared = nil
    }

    func folder() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("blipit-nuggets-\(UUID().uuidString)")
        dirs.append(dir)
        return dir
    }

    func make(_ dir: URL? = nil, sampler: @escaping () -> Double = { 0 }, change: ((Options) -> Void)? = nil) -> Nuggets {
        let options = Options()
        options.key = "blipit_pk_test"
        options.endpoint = "https://in.example"
        options.release = "app@1.2.3"
        options.environment = "test"
        options.directory = dir ?? folder()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptedProtocol.self]
        options.urlSession = URLSession(configuration: config)
        change?(options)
        let nuggets = Nuggets(options: options, sampler: sampler)
        made.append(nuggets)
        return nuggets
    }

    func drain(_ nuggets: Nuggets) {
        let done = expectation(description: "flushed")
        nuggets.io.async { nuggets.transport.flush { done.fulfill() } }
        wait(for: [done], timeout: 10)
    }

    func queued(_ nuggets: Nuggets) -> [[String: Any]] {
        nuggets.io.sync { nuggets.transport.pending().compactMap(Json.read) }
    }

    static var schema: [String: Any] = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../schema/src/event-v1.json").standardized
        return Json.read(url) ?? [:]
    }()

    func keys(_ path: [String]) -> Set<String> {
        var node: Any? = NuggetsTests.schema
        for step in path { node = (node as? [String: Any])?[step] }
        return Set(((node as? [String: Any])?["properties"] as? [String: Any])?.keys ?? [:].keys)
    }

    func assertMatchesSchema(_ event: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(keys([]).isEmpty, "schema not found", file: file, line: line)
        XCTAssertTrue(Set(event.keys).isSubset(of: keys([])), "\(Set(event.keys).subtracting(keys([])))", file: file, line: line)
        for key in ["event_id", "timestamp", "platform", "sdk"] { XCTAssertNotNil(event[key], key, file: file, line: line) }
        XCTAssertNotNil((event["event_id"] as? String)?.range(of: "^[0-9a-f]{32}$", options: .regularExpression), file: file, line: line)
        XCTAssertNotNil(event["message"] ?? event["exception"] ?? event["security"], file: file, line: line)
        XCTAssertTrue(["fatal", "error", "warning", "info", "debug"].contains(event["level"] as? String ?? ""), file: file, line: line)
        XCTAssertEqual(Set((event["sdk"] as? [String: Any])?.keys ?? [:].keys), keys(["properties", "sdk"]), file: file, line: line)
        if let exception = event["exception"] as? [String: Any] {
            XCTAssertTrue(Set(exception.keys).isSubset(of: keys(["properties", "exception"])), file: file, line: line)
            let frameKeys = keys(["properties", "exception", "properties", "stacktrace", "properties", "frames", "items"])
            for frame in (exception["stacktrace"] as? [String: Any])?["frames"] as? [[String: Any]] ?? [] {
                XCTAssertTrue(Set(frame.keys).isSubset(of: frameKeys), "\(frame)", file: file, line: line)
                XCTAssertNotNil(frame["filename"] as? String, file: file, line: line)
            }
        }
        let crumbKeys = keys(["properties", "breadcrumbs", "items"])
        let categories = ((((NuggetsTests.schema["properties"] as? [String: Any])?["breadcrumbs"] as? [String: Any])?["items"] as? [String: Any])?["properties"] as? [String: Any])?["category"] as? [String: Any]
        for crumb in event["breadcrumbs"] as? [[String: Any]] ?? [] {
            XCTAssertTrue(Set(crumb.keys).isSubset(of: crumbKeys), file: file, line: line)
            XCTAssertTrue((categories?["enum"] as? [String])?.contains(crumb["category"] as? String ?? "") ?? false, file: file, line: line)
        }
        if let contexts = event["contexts"] as? [String: Any] {
            XCTAssertTrue(Set(contexts.keys).isSubset(of: keys(["properties", "contexts"])), file: file, line: line)
            XCTAssertTrue(Set((contexts["device"] as? [String: Any])?.keys ?? [:].keys).isSubset(of: ["model", "screen"]), file: file, line: line)
        }
        XCTAssertTrue(JSONSerialization.isValidJSONObject(event), file: file, line: line)
    }

    func testEventsUseBlipitsOwnFormatAndEndpoint() throws {
        ScriptedProtocol.reset()
        let nuggets = make()
        nuggets.scope.setUser(["id": "42"])
        nuggets.scope.setTag("region", "eu")
        nuggets.scope.add("opened checkout", category: "ui")
        Nuggets.shared = nuggets
        XCTAssertFalse(Blipit.captureException(Boom(code: 7)).isEmpty)
        XCTAssertFalse(nuggets.capture(message: "cache miss", level: .warning).isEmpty)
        drain(nuggets)
        let sent = ScriptedProtocol.requests
        XCTAssertEqual(sent.map(\.path), ["/api/v1/events", "/api/v1/events"])
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[0].headers["X-Blipit-Key"], "blipit_pk_test")
        let error = sent[0].body
        assertMatchesSchema(error)
        assertMatchesSchema(sent[1].body)
        XCTAssertEqual(error["platform"] as? String, "other")
        XCTAssertEqual(error["sdk"] as? [String: String], ["name": "blipit-swift", "version": Blipit.version])
        XCTAssertEqual(error["release"] as? String, "app@1.2.3")
        XCTAssertEqual(error["environment"] as? String, "test")
        XCTAssertEqual(error["user"] as? [String: String], ["id": "42"])
        XCTAssertEqual(error["tags"] as? [String: String], ["region": "eu"])
        let exception = try XCTUnwrap(error["exception"] as? [String: Any])
        XCTAssertEqual(exception["type"] as? String, "BlipitSwiftTests.Boom")
        XCTAssertEqual(exception["value"] as? String, "boom 7")
        XCTAssertEqual(exception["handled"] as? Bool, true)
        let frames = try XCTUnwrap((exception["stacktrace"] as? [String: Any])?["frames"] as? [[String: Any]])
        XCTAssertTrue((frames.last?["function"] as? String ?? "").contains("testEventsUseBlipitsOwnFormatAndEndpoint"), "\(frames.last ?? [:])")
        XCTAssertFalse(frames.contains { ($0["function"] as? String ?? "").contains("BlipitSwift.") })
        let crumb = try XCTUnwrap((error["breadcrumbs"] as? [[String: Any]])?.first)
        XCTAssertEqual(crumb["category"] as? String, "custom")
        XCTAssertEqual((crumb["data"] as? [String: String])?["category"], "ui")
        XCTAssertEqual(sent[1].body["message"] as? String, "cache miss")
        XCTAssertEqual(sent[1].body["level"] as? String, "warning")
        let contexts = try XCTUnwrap(error["contexts"] as? [String: Any])
        XCTAssertEqual((contexts["os"] as? [String: String])?["name"], DeviceInfo.osName)
        XCTAssertTrue(queued(nuggets).isEmpty)
    }

    func testNSErrorUsesDomainAndCode() {
        let (type, value) = Nuggets.exception(NSError(domain: "Payments", code: 402, userInfo: [NSLocalizedDescriptionKey: "card declined"]))
        XCTAssertEqual(type, "Payments 402")
        XCTAssertEqual(value, "card declined")
    }

    func testOfflineEventsWaitOnDiskForTheNextLaunch() {
        ScriptedProtocol.reset([.offline])
        let dir = folder()
        let first = make(dir)
        first.capture(message: "offline", level: .info)
        drain(first)
        XCTAssertEqual(queued(first).count, 1)
        first.io.sync { first.transport.stopped = true }
        ScriptedProtocol.reset()
        let second = make(dir)
        drain(second)
        XCTAssertEqual(ScriptedProtocol.requests.first?.body["message"] as? String, "offline")
        XCTAssertTrue(queued(second).isEmpty)
    }

    func testServerErrorsAreRetriedAndClientErrorsDropped() {
        ScriptedProtocol.reset([.status(503, [:], "{}"), .status(400, [:], #"{"error":"bad"}"#)])
        let nuggets = make()
        nuggets.capture(message: "one", level: .info)
        drain(nuggets)
        XCTAssertEqual(queued(nuggets).count, 1)
        nuggets.io.sync { nuggets.transport.failures = 0 }
        drain(nuggets)
        XCTAssertTrue(queued(nuggets).isEmpty)
    }

    func testRateLimitHonoursRetryAfterAcrossLaunches() {
        ScriptedProtocol.reset([.status(429, ["Retry-After": "120"], #"{"retry_after":120}"#)])
        let dir = folder()
        let nuggets = make(dir)
        nuggets.capture(message: "busy", level: .info)
        drain(nuggets)
        let until = nuggets.io.sync { nuggets.transport.blockedUntil.timeIntervalSinceNow }
        XCTAssertGreaterThan(until, 100)
        XCTAssertLessThanOrEqual(until, 120)
        nuggets.capture(message: "second", level: .info)
        drain(nuggets)
        XCTAssertEqual(ScriptedProtocol.requests.count, 1)
        XCTAssertEqual(queued(nuggets).count, 2)
        nuggets.io.sync { nuggets.transport.stopped = true }
        let relaunched = make(dir)
        drain(relaunched)
        XCTAssertEqual(ScriptedProtocol.requests.count, 1)
        XCTAssertGreaterThan(relaunched.io.sync { relaunched.transport.blockedUntil.timeIntervalSinceNow }, 100)
    }

    func testRetryAfterReadsSecondsDatesAndBody() {
        let url = URL(string: "https://in.example")!
        let seconds = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "30"])!
        XCTAssertEqual(Transport.retryAfter(seconds, nil), 30)
        let body = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: [:])!
        XCTAssertEqual(Transport.retryAfter(body, Data(#"{"retry_after":7}"#.utf8)), 7)
        XCTAssertEqual(Transport.retryAfter(body, nil), 60)
    }

    func testInvalidKeyStopsSendingForThisRun() {
        ScriptedProtocol.reset([.status(401, [:], #"{"error":"invalid"}"#)])
        let nuggets = make()
        nuggets.capture(message: "a", level: .info)
        drain(nuggets)
        XCTAssertFalse(nuggets.active)
        XCTAssertTrue(nuggets.capture(message: "b", level: .info).isEmpty)
    }

    func testBreadcrumbsKeepTheNewestAndMapLevels() throws {
        let scope = Scope()
        scope.max = 3
        for n in 1...5 { scope.add("crumb \(n)", category: n == 5 ? "navigation" : "custom", level: n == 4 ? .fatal : .info) }
        let crumbs = try XCTUnwrap(scope.snapshot()["breadcrumbs"] as? [[String: Any]])
        XCTAssertEqual(crumbs.map { $0["message"] as? String }, ["crumb 3", "crumb 4", "crumb 5"])
        XCTAssertEqual(crumbs[1]["level"] as? String, "error")
        XCTAssertEqual(crumbs[2]["category"] as? String, "navigation")
        for n in 0..<40 { scope.setTag("tag\(n)", "v") }
        XCTAssertEqual((scope.snapshot()["tags"] as? [String: String])?.count, 32)
    }

    func testSamplingDropsErrorsButNeverCrashes() {
        ScriptedProtocol.reset()
        let nuggets = make(sampler: { 0.9 }, change: { $0.sampleRate = 0.5 })
        XCTAssertTrue(nuggets.capture(message: "sampled out", level: .error).isEmpty)
        XCTAssertFalse(nuggets.send(nuggets.event(["message": "fatal", "level": "fatal"])).isEmpty)
    }

    func testBeforeSendCanChangeOrDropEvents() {
        ScriptedProtocol.reset()
        let nuggets = make(change: { options in
            options.beforeSend = { event in
                if event["message"] as? String == "drop me" { return nil }
                var event = event
                event["fingerprint"] = ["custom"]
                return event
            }
        })
        XCTAssertTrue(nuggets.capture(message: "drop me", level: .info).isEmpty)
        nuggets.capture(message: "keep me", level: .info)
        drain(nuggets)
        XCTAssertEqual(ScriptedProtocol.requests.map { $0.body["fingerprint"] as? [String] }, [["custom"]])
    }

    func testConsentDeniedClearsTheQueueAndPersists() {
        ScriptedProtocol.reset([.offline])
        let dir = folder()
        let nuggets = make(dir)
        nuggets.capture(message: "queued", level: .info)
        drain(nuggets)
        nuggets.setConsent(false)
        XCTAssertTrue(queued(nuggets).isEmpty)
        XCTAssertTrue(nuggets.capture(message: "after", level: .info).isEmpty)
        let relaunched = make(dir)
        XCTAssertFalse(relaunched.consent)
        relaunched.setConsent(true)
        XCTAssertTrue(relaunched.io.sync { relaunched.consent })
        XCTAssertTrue(make(dir).consent)
    }

    func testSessionsReportStartErrorsAndPreviousCrash() {
        ScriptedProtocol.reset()
        let nuggets = make()
        Nuggets.shared = nuggets
        let sessions = Sessions(nuggets)
        Sessions.shared = sessions
        sessions.begin()
        _ = nuggets.capture(error: Boom(code: 1))
        nuggets.io.sync {}
        sessions.end()
        drain(nuggets)
        let bodies = ScriptedProtocol.requests.filter { $0.path == "/api/v1/sessions" }.map(\.body)
        XCTAssertEqual(bodies.map { $0["status"] as? String }, ["ok", "errored", "exited"])
        XCTAssertEqual(Set(bodies.compactMap { $0["sid"] as? String }).count, 1)
        XCTAssertEqual(bodies.first?["release"] as? String, "app@1.2.3")
        ScriptedProtocol.reset()
        Sessions.close(["session": ["sid": "abcdef0123456789", "started": "2026-10-22T00:00:00.000Z", "errors": 2], "release": "app@1.0.0"], as: "crashed", nuggets: nuggets)
        drain(nuggets)
        XCTAssertEqual(ScriptedProtocol.requests.first?.body["status"] as? String, "crashed")
        XCTAssertEqual(ScriptedProtocol.requests.first?.body["release"] as? String, "app@1.0.0")
    }

    func crashInChild(_ path: String, mach: Bool, how: Int32) -> Int32 {
        typealias Fork = @convention(c) () -> pid_t
        let fork = unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "fork"), to: Fork.self)
        let pid = fork()
        if pid == 0 {
            bn_install(path, mach ? 1 : 0)
            bn_crash(how)
            _exit(0)
        }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        return status & 0x7f
    }

    func testSignalCrashFileRoundTripsIntoAFatalEvent() throws {
        let dir = folder()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("crash.txt").path
        XCTAssertEqual(crashInChild(path, mach: false, how: 0), SIGSEGV)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let report = try XCTUnwrap(CrashReport.parse(text))
        XCTAssertEqual(report.kind, "signal")
        XCTAssertEqual(report.signal, SIGSEGV)
        XCTAssertEqual(report.address, 0x10)
        XCTAssertFalse(report.frames.isEmpty)
        XCTAssertFalse(report.images.isEmpty)
        Json.write(["release": "app@0.9.0", "environment": "staging", "breadcrumbs": [["timestamp": Clock.stamp(), "category": "navigation", "message": "screen Cart"]]], dir.appendingPathComponent("scope.json"))
        ScriptedProtocol.reset([.offline])
        let nuggets = make(dir)
        nuggets.recover()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        drain(nuggets)
        let event = try XCTUnwrap(queued(nuggets).first?["body"] as? [String: Any])
        assertMatchesSchema(event)
        XCTAssertEqual(event["level"] as? String, "fatal")
        XCTAssertEqual(event["release"] as? String, "app@0.9.0")
        XCTAssertEqual(event["environment"] as? String, "staging")
        XCTAssertEqual((event["breadcrumbs"] as? [[String: Any]])?.first?["message"] as? String, "screen Cart")
        let exception = try XCTUnwrap(event["exception"] as? [String: Any])
        XCTAssertEqual(exception["type"] as? String, "SIGSEGV")
        XCTAssertEqual(exception["handled"] as? Bool, false)
        XCTAssertTrue((exception["value"] as? String ?? "").contains("0x10"))
        let frames = try XCTUnwrap((exception["stacktrace"] as? [String: Any])?["frames"] as? [[String: Any]])
        XCTAssertEqual(frames.last?["function"] as? String, "bn_crash")
        XCTAssertEqual((event["tags"] as? [String: String])?["mechanism"], "signal")
    }

    func testAbortAndTrapAreCaught() throws {
        let dir = folder()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("crash.txt").path
        XCTAssertEqual(crashInChild(path, mach: false, how: 1), SIGABRT)
        XCTAssertEqual(CrashReport.parse(try String(contentsOfFile: path, encoding: .utf8))?.exception.type, "SIGABRT")
        let trap = crashInChild(path, mach: false, how: 2)
        XCTAssertTrue(trap == SIGTRAP || trap == SIGILL)
        XCTAssertTrue(["SIGTRAP", "SIGILL"].contains(CrashReport.parse(try String(contentsOfFile: path, encoding: .utf8))?.exception.type ?? ""))
    }

    func testMachExceptionIsCaughtBeforeTheSignal() throws {
        let dir = folder()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("crash.txt").path
        XCTAssertEqual(crashInChild(path, mach: true, how: 0), SIGSEGV)
        let report = try XCTUnwrap(CrashReport.parse(try String(contentsOfFile: path, encoding: .utf8)))
        XCTAssertEqual(report.kind, "mach")
        XCTAssertEqual(report.exception.type, "EXC_BAD_ACCESS")
        XCTAssertEqual(report.address, 0x10)
        XCTAssertFalse(report.frames.isEmpty)
    }

    func testExceptionReportParses() throws {
        let text = "blipit-nuggets 1\ntime 1760000000\nkind exception\nsignal 6\ncode 0\naddr 0x0\nmach 0 0 0\nname NSInvalidArgumentException\nreason -[NSNull length]: unrecognized selector\nframe 0x1000\nend\n"
        let report = try XCTUnwrap(CrashReport.parse(text))
        XCTAssertEqual(report.exception.type, "NSInvalidArgumentException")
        XCTAssertEqual(report.exception.value, "-[NSNull length]: unrecognized selector")
        XCTAssertEqual(report.time, Date(timeIntervalSince1970: 1_760_000_000))
        XCTAssertNil(CrashReport.parse("blipit-nuggets 1\nkind signal\n"))
    }

    func previousRun(clean: Bool, foreground: Bool, hang: [String: Any]? = nil) -> [String: Any] {
        var run: [String: Any] = ["release": "app@1.2.3", "environment": "test", "build": DeviceInfo.build, "os": DeviceInfo.osVersion, "boot": bn_boot_time(), "debugger": false, "crashes": true, "foreground": foreground, "clean": clean, "at": Clock.ms(), "session": ["sid": "0123456789abcdef", "started": Clock.stamp(), "errors": 0]]
        if let hang { run["hang"] = hang }
        return run
    }

    func testWatchdogTerminationIsReportedOnlyWhenKilledOnScreen() throws {
        Nuggets.watchdogSupported = true
        defer { Nuggets.watchdogSupported = false }
        ScriptedProtocol.reset()
        let dir = folder()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Json.write(previousRun(clean: false, foreground: true), dir.appendingPathComponent("run.json"))
        let killed = make(dir)
        killed.recover()
        drain(killed)
        let event = try XCTUnwrap(ScriptedProtocol.requests.first { $0.path == "/api/v1/events" }?.body)
        assertMatchesSchema(event)
        XCTAssertEqual((event["exception"] as? [String: Any])?["type"] as? String, "WatchdogTermination")
        XCTAssertEqual(event["level"] as? String, "fatal")
        XCTAssertEqual(ScriptedProtocol.requests.first { $0.path == "/api/v1/sessions" }?.body["status"] as? String, "abnormal")

        for run in [previousRun(clean: true, foreground: true), previousRun(clean: false, foreground: false)] {
            ScriptedProtocol.reset()
            Json.write(run, dir.appendingPathComponent("run.json"))
            let fine = make(dir)
            fine.recover()
            drain(fine)
            XCTAssertFalse(ScriptedProtocol.requests.contains { $0.path == "/api/v1/events" })
        }
        var updated = previousRun(clean: false, foreground: true)
        updated["build"] = "other"
        XCTAssertFalse(make(dir).killedInForeground(updated))
    }

    func testKilledWhileHangingCarriesTheHangStack() throws {
        Nuggets.watchdogSupported = true
        defer { Nuggets.watchdogSupported = false }
        ScriptedProtocol.reset()
        let dir = folder()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let frames: [[String: Any]] = [["filename": "MyApp", "function": "MyApp.load()", "in_app": true]]
        Json.write(previousRun(clean: false, foreground: true, hang: ["frames": frames, "native_frames": ["MyApp 0x10"], "since": Clock.ms() - 5000]), dir.appendingPathComponent("run.json"))
        let nuggets = make(dir)
        nuggets.recover()
        drain(nuggets)
        let event = try XCTUnwrap(ScriptedProtocol.requests.first { $0.path == "/api/v1/events" }?.body)
        let exception = try XCTUnwrap(event["exception"] as? [String: Any])
        XCTAssertTrue((exception["value"] as? String ?? "").contains("main thread was blocked"))
        XCTAssertEqual(((exception["stacktrace"] as? [String: Any])?["frames"] as? [[String: Any]])?.first?["function"] as? String, "MyApp.load()")
    }

    func testMainThreadHangIsReportedWithItsStack() throws {
        ScriptedProtocol.reset()
        let nuggets = make()
        bn_mark_main_thread()
        let watch = HangWatch(nuggets, threshold: 0.3)
        watch.start()
        Thread.sleep(forTimeInterval: 0.2)
        Thread.sleep(forTimeInterval: 1.2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let found = expectation(description: "hang queued")
        DispatchQueue.global().async {
            for _ in 0..<50 {
                if ScriptedProtocol.requests.contains(where: { ($0.body["exception"] as? [String: Any])?["type"] as? String == "AppHang" }) { break }
                nuggets.transport.flush()
                Thread.sleep(forTimeInterval: 0.1)
            }
            found.fulfill()
        }
        wait(for: [found], timeout: 10)
        nuggets.io.sync { nuggets.transport.stopped = true }
        let event = try XCTUnwrap(ScriptedProtocol.requests.first { ($0.body["exception"] as? [String: Any])?["type"] as? String == "AppHang" }?.body)
        assertMatchesSchema(event)
        let frames = (event["exception"] as? [String: Any]).flatMap { ($0["stacktrace"] as? [String: Any])?["frames"] as? [[String: Any]] } ?? []
        XCTAssertTrue(frames.contains { ($0["function"] as? String ?? "").contains("testMainThreadHangIsReportedWithItsStack") }, "\(frames.map { $0["function"] ?? "" })")
    }

    func testNetworkRequestsLeaveScrubbedBreadcrumbs() throws {
        ScriptedProtocol.reset()
        let nuggets = make()
        Nuggets.shared = nuggets
        Network.install(host: "in.example")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptedProtocol.self]
        let session = URLSession(configuration: config)
        let done = expectation(description: "request")
        session.dataTask(with: URL(string: "https://api.example.com/items?token=secret")!) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 5)
        let deadline = Date().addingTimeInterval(2)
        var crumb: [String: Any]?
        while crumb == nil && Date() < deadline {
            crumb = (nuggets.scope.snapshot()["breadcrumbs"] as? [[String: Any]])?.first { $0["category"] as? String == "http" }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let found = try XCTUnwrap(crumb)
        XCTAssertEqual(found["message"] as? String, "GET https://api.example.com/items 202")
        XCTAssertEqual((found["data"] as? [String: Any])?["status_code"] as? Int, 202)
        XCTAssertFalse("\(found)".contains("secret"))
    }

    func testTracesGoOutAsOtlpJson() throws {
        ScriptedProtocol.reset()
        let nuggets = make(change: { $0.tracesSampleRate = 1 })
        let tracer = Tracer(nuggets, rate: 1)
        tracer.record("CartViewController load", kind: 1, start: Date().addingTimeInterval(-0.3), end: Date(), attributes: ["ui.screen": "CartViewController"])
        tracer.flush()
        drain(nuggets)
        let sent = try XCTUnwrap(ScriptedProtocol.requests.first)
        XCTAssertEqual(sent.path, "/v1/traces")
        let spans = ((((sent.body["resourceSpans"] as? [[String: Any]])?.first?["scopeSpans"] as? [[String: Any]])?.first)?["spans"] as? [[String: Any]])
        XCTAssertEqual(spans?.first?["name"] as? String, "CartViewController load")
        XCTAssertNotNil((spans?.first?["traceId"] as? String)?.range(of: "^[0-9a-f]{32}$", options: .regularExpression))
    }

    func testPrivacyManifestDeclaresWhatTheSdkUses() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Sources/BlipitSwift/PrivacyInfo.xcprivacy").standardized
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual((plist["NSPrivacyTrackingDomains"] as? [String])?.isEmpty, true)
        let apis = plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? []
        XCTAssertEqual(apis.first { $0["NSPrivacyAccessedAPIType"] as? String == "NSPrivacyAccessedAPICategorySystemBootTime" }?["NSPrivacyAccessedAPITypeReasons"] as? [String], ["35F9.1"])
        let types = (plist["NSPrivacyCollectedDataTypes"] as? [[String: Any]] ?? []).compactMap { $0["NSPrivacyCollectedDataType"] as? String }
        XCTAssertTrue(types.contains("NSPrivacyCollectedDataTypeCrashData"))
    }
}
