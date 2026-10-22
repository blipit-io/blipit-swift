import Foundation
#if canImport(BlipitNuggets)
import BlipitNuggets
#endif

struct CrashReport {
    var time: Date?
    var kind = ""
    var signal: Int32 = 0
    var code: Int64 = 0
    var address: UInt = 0
    var mach: Int64 = 0
    var machCode: Int64 = 0
    var machSubcode: Int64 = 0
    var name: String?
    var reason: String?
    var frames: [UInt] = []
    var images: [Image] = []

    static let signalNames: [Int32: String] = [SIGABRT: "SIGABRT", SIGBUS: "SIGBUS", SIGFPE: "SIGFPE", SIGILL: "SIGILL", SIGSEGV: "SIGSEGV", SIGTRAP: "SIGTRAP", SIGSYS: "SIGSYS"]
    static let machNames: [Int64: String] = [1: "EXC_BAD_ACCESS", 2: "EXC_BAD_INSTRUCTION", 3: "EXC_ARITHMETIC", 6: "EXC_BREAKPOINT"]

    static func hex(_ text: Substring) -> UInt? {
        UInt(text.hasPrefix("0x") ? text.dropFirst(2) : text, radix: 16)
    }

    static func parse(_ text: String) -> CrashReport? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.first == "blipit-nuggets 1", lines.contains("end") else { return nil }
        var report = CrashReport()
        for line in lines {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let value = parts[1]
            switch parts[0] {
            case "time": report.time = Double(value).map { Date(timeIntervalSince1970: $0) }
            case "kind": report.kind = String(value)
            case "signal": report.signal = Int32(value) ?? 0
            case "code": report.code = Int64(value) ?? 0
            case "addr": report.address = hex(value) ?? 0
            case "mach":
                let codes = value.split(separator: " ").map { Int64($0) ?? 0 }
                if codes.count == 3 { (report.mach, report.machCode, report.machSubcode) = (codes[0], codes[1], codes[2]) }
            case "name": report.name = String(value)
            case "reason": report.reason = String(value)
            case "frame": if let address = hex(value) { report.frames.append(address) }
            case "image":
                let fields = value.split(separator: " ", maxSplits: 3)
                if fields.count == 4, let base = hex(fields[0]), let size = hex(fields[1]) {
                    report.images.append(Image(base: base, size: size, uuid: String(fields[2]), path: String(fields[3])))
                }
            default: break
            }
        }
        return report.kind.isEmpty ? nil : report
    }

    var exception: (type: String, value: String) {
        let at = address == 0 ? "" : " at 0x" + String(address, radix: 16)
        switch kind {
        case "exception":
            return (name ?? "NSException", reason ?? "")
        case "mach":
            let type = CrashReport.machNames[mach] ?? "EXC_\(mach)"
            if mach == 6 || mach == 2 {
                return (type, "\(type): the app stopped on a trap, usually a Swift runtime check such as a force unwrap of nil, an array index out of range or fatalError" + at)
            }
            return (type, "\(type) (code \(machCode), subcode 0x\(String(UInt64(bitPattern: machSubcode), radix: 16)))" + at)
        default:
            let type = CrashReport.signalNames[signal] ?? "SIG\(signal)"
            return (type, "Signal \(type) (\(signal)), code \(code)" + at)
        }
    }

    func event(_ nuggets: Nuggets, scope: [String: Any]?) -> [String: Any] {
        let (type, value) = exception
        let symbolicated = Symbols.frames(frames, images: images)
        var exception: [String: Any] = ["type": Json.cut(type, 256), "value": Json.cut(value, 4096), "handled": false]
        if !symbolicated.frames.isEmpty { exception["stacktrace"] = ["frames": symbolicated.frames] }
        var event = nuggets.event(["exception": exception, "level": "fatal"], scope: scope ?? [:], at: time ?? Date())
        var extra = event["extra"] as? [String: Any] ?? [:]
        extra["crash"] = ["mechanism": kind, "native_frames": symbolicated.raw, "debug_images": symbolicated.used]
        event["extra"] = extra
        var tags = event["tags"] as? [String: String] ?? [:]
        if tags.count < 32 { tags["mechanism"] = kind }
        event["tags"] = tags
        return event
    }
}

final class Sessions {
    static var shared: Sessions?
    let nuggets: Nuggets
    var sid: String?
    var started = ""
    var errors = 0
    var status = "ok"
    var backgroundAt: Date?

    init(_ nuggets: Nuggets) { self.nuggets = nuggets }

    static func body(sid: String, status: String, errors: Int, started: String, release: String, environment: String, user: String?) -> [String: Any] {
        var body: [String: Any] = ["sid": sid, "status": status, "errors": errors, "started": started, "release": release, "environment": environment]
        if let user { body["did"] = user }
        return body
    }

    func post(_ status: String) {
        guard let sid, let release = nuggets.release, nuggets.active else { return }
        let user = nuggets.scope.user.flatMap { $0["id"] ?? $0["email"] }
        nuggets.transport.enqueue("/api/v1/sessions", Sessions.body(sid: sid, status: status, errors: errors, started: started, release: release, environment: nuggets.options.environment, user: user))
    }

    func remember() {
        let state: [String: Any]? = sid.map { ["sid": $0, "started": started, "errors": errors, "status": status] }
        nuggets.updateRun { $0["session"] = state }
    }

    func begin() {
        nuggets.io.async {
            self.sid = Clock.id()
            self.started = Clock.stamp()
            self.errors = 0
            self.status = "ok"
            self.post("ok")
            self.remember()
        }
    }

    func end() {
        nuggets.io.async {
            guard self.sid != nil else { return }
            self.post("exited")
            self.sid = nil
            self.remember()
        }
    }

    func markError(crashed: Bool) {
        nuggets.io.async {
            guard self.sid != nil else { return }
            self.errors += 1
            if self.status == "ok" {
                self.status = "errored"
                self.post("errored")
            }
            self.remember()
        }
    }

    func background() {
        nuggets.io.async { self.backgroundAt = Date() }
    }

    func foreground() {
        nuggets.io.async {
            guard let at = self.backgroundAt else { return }
            self.backgroundAt = nil
            if Date().timeIntervalSince(at) >= 30 || self.sid == nil {
                if self.sid != nil { self.post("exited") }
                self.sid = Clock.id()
                self.started = Clock.stamp()
                self.errors = 0
                self.status = "ok"
                self.post("ok")
                self.remember()
            }
        }
    }

    static func close(_ previous: [String: Any]?, as status: String, nuggets: Nuggets) {
        guard let session = previous?["session"] as? [String: Any], let sid = session["sid"] as? String, let release = previous?["release"] as? String ?? nuggets.release else { return }
        let body = Sessions.body(sid: sid, status: status, errors: session["errors"] as? Int ?? 0, started: session["started"] as? String ?? Clock.stamp(), release: release, environment: previous?["environment"] as? String ?? nuggets.options.environment, user: nil)
        nuggets.transport.enqueue("/api/v1/sessions", body)
    }
}

final class HangWatch {
    let nuggets: Nuggets
    let threshold: TimeInterval
    private let lock = NSLock()
    private var answered = true
    private var visible = true

    init(_ nuggets: Nuggets, threshold: TimeInterval) {
        self.nuggets = nuggets
        self.threshold = max(0.25, threshold)
    }

    var foreground: Bool {
        get { lock.lock(); defer { lock.unlock() }; return visible }
        set { lock.lock(); visible = newValue; lock.unlock() }
    }

    private var replied: Bool {
        get { lock.lock(); defer { lock.unlock() }; return answered }
        set { lock.lock(); answered = newValue; lock.unlock() }
    }

    func start() {
        let thread = Thread { [weak self] in self?.loop() }
        thread.name = "io.blipit.nuggets.hang"
        thread.qualityOfService = .utility
        thread.start()
    }

    static func seconds(since start: DispatchTime) -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }

    private func loop() {
        while true {
            guard foreground, nuggets.active else {
                Thread.sleep(forTimeInterval: 1)
                continue
            }
            let began = DispatchTime.now()
            replied = false
            DispatchQueue.main.async { self.replied = true }
            Thread.sleep(forTimeInterval: threshold)
            if replied || HangWatch.seconds(since: began) > threshold + 1 { continue }
            var buffer = [UInt](repeating: 0, count: 128)
            let count = Int(bn_main_backtrace(&buffer, 128))
            let symbolicated = Symbols.frames(Array(buffer.prefix(count)), images: Image.loaded())
            nuggets.updateRun { $0["hang"] = ["frames": symbolicated.frames, "native_frames": symbolicated.raw, "since": Clock.ms()] }
            while !replied && foreground { Thread.sleep(forTimeInterval: 0.1) }
            let waited = HangWatch.seconds(since: began)
            nuggets.updateRun { $0["hang"] = nil }
            guard replied else { continue }
            nuggets.send(HangWatch.event(nuggets, frames: symbolicated.frames, raw: symbolicated.raw, waited: waited, fatal: false, scope: nil))
        }
    }

    static func event(_ nuggets: Nuggets, frames: [[String: Any]], raw: [String], waited: TimeInterval?, fatal: Bool, scope: [String: Any]?, at: Date = Date()) -> [String: Any] {
        let value: String
        if fatal {
            value = "The system ended the app while its main thread was blocked" + (waited.map { " for at least \(String(format: "%.1f", $0)) s" } ?? "") + " (watchdog)"
        } else {
            value = "The main thread was blocked for \(String(format: "%.1f", waited ?? 0)) s"
        }
        var exception: [String: Any] = ["type": fatal ? "WatchdogTermination" : "AppHang", "value": value, "handled": !fatal]
        if !frames.isEmpty { exception["stacktrace"] = ["frames": frames] }
        var event = nuggets.event(["exception": exception, "level": fatal ? "fatal" : "error"], scope: scope, at: at)
        var extra = event["extra"] as? [String: Any] ?? [:]
        extra["hang"] = ["native_frames": raw, "waited_ms": Int((waited ?? 0) * 1000)]
        event["extra"] = extra
        var tags = event["tags"] as? [String: String] ?? [:]
        if tags.count < 32 { tags["mechanism"] = fatal ? "watchdog" : "hang" }
        event["tags"] = tags
        return event
    }
}

extension Nuggets {
    static var previousExceptionHandler: (@convention(c) (NSException) -> Void)?

    static func installExceptionHandler() {
        previousExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            let frames = exception.callStackReturnAddresses.map { $0.uintValue }
            _ = frames.withUnsafeBufferPointer { buffer in
                bn_write_exception(exception.name.rawValue, exception.reason ?? "", buffer.baseAddress, Int32(buffer.count))
            }
            Nuggets.previousExceptionHandler?(exception)
        }
    }

    static var watchdogSupported: Bool = {
        #if os(iOS) || os(tvOS)
        return true
        #else
        return false
        #endif
    }()

    func killedInForeground(_ previous: [String: Any]?) -> Bool {
        guard options.watchdogTerminations, let p = previous else { return false }
        return p["clean"] as? Bool != true
            && p["foreground"] as? Bool == true
            && p["debugger"] as? Bool != true
            && p["crashes"] as? Bool == true
            && p["build"] as? String == DeviceInfo.build
            && p["os"] as? String == DeviceInfo.osVersion
            && (p["boot"] as? NSNumber)?.int64Value == bn_boot_time()
    }

    func recover() {
        io.sync {
            previous = Json.read(runFile)
            let saved = Json.read(scopeFile)
            let text = try? String(contentsOf: crashFile, encoding: .utf8)
            try? FileManager.default.removeItem(at: crashFile)
            guard active else { return }
            if let text, let report = CrashReport.parse(text) {
                log("found a crash from the last run, sending it")
                if let event = applyHooks(report.event(self, scope: saved)) { transport.enqueue("/api/v1/events", event) }
                Sessions.close(previous, as: "crashed", nuggets: self)
            } else if Nuggets.watchdogSupported, killedInForeground(previous) {
                let hang = previous?["hang"] as? [String: Any]
                let at = (previous?["at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } ?? Date()
                let waited = (hang?["since"] as? NSNumber).map { max(0, at.timeIntervalSince1970 - $0.doubleValue / 1000) + options.hangThreshold }
                var event = HangWatch.event(self, frames: hang?["frames"] as? [[String: Any]] ?? [], raw: hang?["native_frames"] as? [String] ?? [], waited: hang == nil ? nil : waited, fatal: true, scope: saved ?? [:], at: at)
                if hang == nil, var exception = event["exception"] as? [String: Any] {
                    let memory = previous?["memory_warning"] as? Bool == true
                    exception["value"] = memory
                        ? "The system ended the app while it was in the foreground, without a crash, after a low-memory warning (likely out of memory)"
                        : "The system ended the app while it was in the foreground, without a crash (watchdog or out of memory)"
                    event["exception"] = exception
                }
                if let event = applyHooks(event) { transport.enqueue("/api/v1/events", event) }
                Sessions.close(previous, as: "abnormal", nuggets: self)
            } else if previous?["clean"] as? Bool != true {
                Sessions.close(previous, as: "exited", nuggets: self)
            }
        }
    }

    func applyHooks(_ event: [String: Any]) -> [String: Any]? {
        guard let hook = options.beforeSend else { return event }
        return hook(event).flatMap { JSONSerialization.isValidJSONObject($0) ? $0 : nil }
    }

    func boot() {
        recover()
        let debugger = bn_debugger_attached() != 0
        run = [
            "release": release as Any,
            "environment": options.environment,
            "build": DeviceInfo.build,
            "os": DeviceInfo.osVersion,
            "boot": bn_boot_time(),
            "debugger": debugger,
            "crashes": options.crashes,
            "foreground": false,
            "clean": false,
            "at": Clock.ms(),
        ]
        saveRun()
        scopeChanged()
        if options.crashes {
            bn_install(crashFile.path, options.machExceptions ? 1 : 0)
            Nuggets.installExceptionHandler()
        }
        if options.sessions, release != nil {
            let sessions = Sessions(self)
            Sessions.shared = sessions
            sessions.begin()
        }
        atexit { Nuggets.shared?.cleanExit() }
        transport.flush()
    }

    func cleanExit() {
        io.sync {
            if let sessions = Sessions.shared, let sid = sessions.sid, let release {
                let body = Sessions.body(sid: sid, status: "exited", errors: sessions.errors, started: sessions.started, release: release, environment: options.environment, user: nil)
                transport.counter += 1
                Json.write(["path": "/api/v1/sessions", "body": body], transport.dir.appendingPathComponent(String(format: "%013lld-%06d.json", Clock.ms(), transport.counter % 1_000_000)))
                sessions.sid = nil
            }
            run["clean"] = true
            run["session"] = nil
            run["at"] = Clock.ms()
            Json.write(run, runFile)
        }
    }
}
