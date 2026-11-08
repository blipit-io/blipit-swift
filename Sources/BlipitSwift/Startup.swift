import Foundation
#if canImport(Security)
import Security
#endif

enum Startup {
    static let type = "StartupFailed"
    static let began: Date = {
        #if canImport(Darwin)
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        if sysctl(&mib, 4, &info, &size, nil, 0) == 0 {
            let start = info.kp_proc.p_un.__p_starttime
            if start.tv_sec > 0 { return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000) }
        }
        #endif
        return Date()
    }()
    private static let lock = NSLock()
    private static var reported = false
    private static var early: [(Nuggets) -> Void] = []
    private static var previous: [String: Any]?

    static func whenStarted(_ work: @escaping (Nuggets) -> Void) {
        lock.lock()
        if let nuggets = Nuggets.shared {
            lock.unlock()
            work(nuggets)
            return
        }
        if early.count < 100 { early.append(work) }
        lock.unlock()
    }

    static func started(_ nuggets: Nuggets) {
        lock.lock()
        let work = early
        early = []
        lock.unlock()
        for item in work { item(nuggets) }
    }

    static func remember(previousScope saved: [String: Any]?, release: String?) {
        guard let crumbs = saved?["breadcrumbs"] as? [[String: Any]], !crumbs.isEmpty else { return }
        var launch: [String: Any] = ["label": "previous launch", "breadcrumbs": Array(crumbs.suffix(50))]
        if let release = (saved?["release"] as? String) ?? release { launch["release"] = release }
        lock.lock(); previous = launch; lock.unlock()
    }

    static func attachPrevious(_ event: inout [String: Any]) {
        lock.lock()
        let launch = previous
        previous = nil
        lock.unlock()
        guard let launch else { return }
        var extra = event["extra"] as? [String: Any] ?? [:]
        extra["previous_launch"] = launch
        event["extra"] = extra
    }

    static func reset() {
        lock.lock()
        early = []
        previous = nil
        reported = false
        lock.unlock()
    }

    static func first() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if reported { return false }
        reported = true
        return true
    }

    static func event(_ nuggets: Nuggets, value: String, details: [String: Any], step: String?) -> [String: Any] {
        var event = nuggets.event([
            "level": "warning",
            "exception": ["type": type, "value": Json.cut(value, 4096), "handled": true],
        ])
        var tags = event["tags"] as? [String: String] ?? [:]
        tags["startup.outcome"] = "failed"
        if let step { tags["startup.step"] = Json.cut(step, 256) }
        event["tags"] = tags
        var startup = details
        startup["outcome"] = "failed"
        startup["since_start_ms"] = Int(Date().timeIntervalSince(began) * 1000)
        if let step { startup["step"] = step }
        var extra = event["extra"] as? [String: Any] ?? [:]
        extra["startup"] = startup
        event["extra"] = extra
        return event
    }

    static func failed(_ nuggets: Nuggets, reason: String) -> EventId {
        guard first() else { return .empty }
        return nuggets.send(event(nuggets, value: reason, details: ["reason": reason], step: nil))
    }

    static func details(_ error: Error) -> (summary: String, details: [String: Any]) {
        let ns = error as NSError
        var details: [String: Any] = ["error_domain": ns.domain, "error_code": ns.code, "message": Json.cut(ns.localizedDescription, 1024)]
        let summary: String
        if Swift.type(of: error) is NSError.Type {
            details["error_type"] = ns.domain
            summary = "\(ns.domain) \(ns.code)"
        } else {
            let name = String(describing: Swift.type(of: error))
            details["error_type"] = String(reflecting: Swift.type(of: error))
            summary = Json.cut("\(name).\(String(describing: error))", 256)
        }
        if ns.domain == NSOSStatusErrorDomain {
            details["os_status"] = ns.code
            if let text = statusMessage(OSStatus(truncatingIfNeeded: ns.code)) { details["os_status_message"] = text }
        }
        var causes: [[String: Any]] = []
        var next = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        while let cause = next, causes.count < 5 {
            var item: [String: Any] = ["domain": cause.domain, "code": cause.code]
            if cause.domain == NSOSStatusErrorDomain, let text = statusMessage(OSStatus(truncatingIfNeeded: cause.code)) { item["os_status_message"] = text }
            causes.append(item)
            next = cause.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        if !causes.isEmpty { details["causes"] = causes }
        return (summary, details)
    }

    static func statusMessage(_ status: OSStatus) -> String? {
        #if canImport(Security)
        return SecCopyErrorMessageString(status, nil) as String?
        #else
        return nil
        #endif
    }

    static func capture(_ nuggets: Nuggets, error: Error, step: String) -> EventId {
        guard first() else { return .empty }
        let (summary, details) = details(error)
        return nuggets.send(event(nuggets, value: "\(step): \(summary)", details: details, step: step))
    }
}

enum Signing {
    static func kind(profile: String?) -> String {
        guard let profile, !profile.isEmpty else { return "appstore" }
        if profile.range(of: "<key>get-task-allow</key>\\s*<true\\s*/>", options: .regularExpression) != nil { return "development" }
        return "adhoc"
    }

    static var current: String? {
        #if os(iOS) || os(tvOS)
        #if targetEnvironment(simulator)
        return "development"
        #else
        let data = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision").flatMap { try? Data(contentsOf: $0) }
        return kind(profile: data.map { String(decoding: $0, as: UTF8.self) })
        #endif
        #else
        return nil
        #endif
    }

    static func environment(explicit: String?, signing: String?) -> String? {
        if let explicit { return explicit }
        return signing == "development" ? "testing" : nil
    }
}
