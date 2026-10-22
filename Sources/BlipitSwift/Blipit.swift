import Foundation
#if canImport(BlipitNuggets)
import BlipitNuggets
#endif

public enum Blipit {
    public static let defaultEndpoint = "https://in.blipit.io"
    public static let version = "0.5.0"
    public static let packageName = "swiftpm:blipit-swift"
    static var reporter: ReportClient?
    static let missingKeyWarning = "[blipit] Blipit.start got no key, so Blipit is off and nothing is sent. Pass the project's public key from app.blipit.io, Keys."
    static let missingProjectWarning = "[blipit] Blipit.start got no project id, so Blipit is off and nothing is sent. Pass the id from the project's Keys page at app.blipit.io."

    @discardableResult
    public static func configure(
        _ options: Options,
        key: String,
        project: String,
        environment: String? = nil,
        release: String? = nil,
        tracesSampleRate: Double = 0,
        endpoint: String = defaultEndpoint
    ) -> Bool {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = project.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty || project.isEmpty {
            print(key.isEmpty ? missingKeyWarning : missingProjectWarning)
            options.enabled = false
            return false
        }
        options.key = key
        options.project = project
        options.endpoint = endpoint
        if let environment { options.environment = environment }
        options.release = release
        options.tracesSampleRate = tracesSampleRate
        reporter = ReportClient(endpoint: endpoint, key: key)
        return true
    }

    @discardableResult
    public static func start(
        key: String,
        project: String,
        environment: String? = nil,
        release: String? = nil,
        tracesSampleRate: Double = 0,
        endpoint: String = defaultEndpoint,
        waitForReady: Bool = false,
        startupDeadline: TimeInterval = 0,
        configure extra: ((Options) -> Void)? = nil
    ) -> Bool {
        let options = Options()
        guard configure(options, key: key, project: project, environment: environment, release: release, tracesSampleRate: tracesSampleRate, endpoint: endpoint) else { return false }
        extra?(options)
        guard options.enabled, Nuggets.shared == nil else { return options.enabled }
        let nuggets = Nuggets(options: options)
        Nuggets.shared = nuggets
        nuggets.boot()
        Auto.install(nuggets)
        Stuck.setup(release: nuggets.release, environment: options.environment, waitForReady: waitForReady || startupDeadline > 0)
        return true
    }

    public static func reportReady() {
        Stuck.end(FlowWatch.startup)
    }

    public static func startFlow(_ name: String) {
        if let name = StuckEvent.name(name, max: 64) { Stuck.start(name) }
    }

    public static func flowStep(_ name: String, _ step: String) {
        guard let name = StuckEvent.name(name, max: 64), let step = StuckEvent.name(step, max: 128) else { return }
        Stuck.step(name, step)
    }

    public static func endFlow(_ name: String) {
        if let name = StuckEvent.name(name, max: 64) { Stuck.end(name) }
    }

    @inline(never)
    @discardableResult
    public static func capture(error: Error) -> EventId {
        var frames = [UInt](repeating: 0, count: 128)
        let count = Int(bn_backtrace(&frames, 128, 1))
        return Nuggets.shared?.capture(error: error, addresses: Array(frames.prefix(count))) ?? .empty
    }

    @discardableResult
    public static func capture(message: String, level: Level = .info) -> EventId {
        Nuggets.shared?.capture(message: message, level: level) ?? .empty
    }

    @inline(never)
    @discardableResult
    public static func captureException(_ error: Error) -> EventId {
        var frames = [UInt](repeating: 0, count: 128)
        let count = Int(bn_backtrace(&frames, 128, 1))
        return Nuggets.shared?.capture(error: error, addresses: Array(frames.prefix(count))) ?? .empty
    }

    @discardableResult
    public static func captureMessage(_ message: String, level: Level = .info) -> EventId {
        capture(message: message, level: level)
    }

    public static func setUser(id: String?, email: String? = nil, username: String? = nil) {
        guard let nuggets = Nuggets.shared else { return }
        var user: [String: String] = [:]
        if let id { user["id"] = Json.cut(id, 128) }
        if let email { user["email"] = Json.cut(email, 256) }
        if let username { user["username"] = Json.cut(username, 128) }
        nuggets.scope.setUser(user.isEmpty ? nil : user)
        nuggets.scopeChanged()
    }

    public static func setTag(_ key: String, _ value: String) {
        guard let nuggets = Nuggets.shared else { return }
        nuggets.scope.setTag(key, value)
        nuggets.scopeChanged()
    }

    public static func setContext(_ key: String, _ value: [String: Any]?) {
        guard let nuggets = Nuggets.shared else { return }
        nuggets.scope.setContext(key, value)
        nuggets.scopeChanged()
    }

    public static func addBreadcrumb(_ message: String, category: String = "custom", level: Level = .info, data: [String: Any]? = nil) {
        guard let nuggets = Nuggets.shared else { return }
        nuggets.scope.add(message, category: category, level: level, data: data)
        nuggets.scopeChanged()
    }

    public static func setConsent(_ granted: Bool) {
        Nuggets.shared?.setConsent(granted)
    }

    public static var hasConsent: Bool {
        Nuggets.shared?.consent ?? true
    }

    public static func crash() {
        bn_crash(0)
    }

    public static func securityContext(
        kind: String,
        actor: String,
        outcome: String? = nil,
        actorId: String? = nil,
        ip: String? = nil,
        userAgent: String? = nil,
        target: String? = nil
    ) -> [String: String] {
        var context = ["kind": kind, "actor": actor]
        if let outcome { context["outcome"] = outcome }
        if let actorId { context["actor_id"] = actorId }
        if let ip { context["ip"] = ip }
        if let userAgent { context["user_agent"] = userAgent }
        if let target { context["target"] = target }
        return context
    }

    static let securityKinds: Set<String> = ["login_failed", "login_succeeded", "login_blocked", "password_reset_requested", "privilege_granted"]
    static let securityLimits = ["actor": 256, "actor_id": 128, "ip": 45, "user_agent": 512, "outcome": 64, "target": 256]

    @discardableResult
    public static func captureSecurity(
        kind: String,
        actor: String,
        outcome: String? = nil,
        actorId: String? = nil,
        ip: String? = nil,
        userAgent: String? = nil,
        target: String? = nil
    ) -> EventId {
        guard let nuggets = Nuggets.shared, securityKinds.contains(kind), !actor.trimmingCharacters(in: .whitespaces).isEmpty else { return .empty }
        var context = securityContext(kind: kind, actor: actor, outcome: outcome, actorId: actorId, ip: ip, userAgent: userAgent, target: target)
        for (field, max) in securityLimits { context[field] = context[field].map { Json.cut($0, max) } }
        let level: Level = kind == "login_failed" || kind == "login_blocked" || kind == "privilege_granted" ? .warning : .info
        return nuggets.send(nuggets.event(["message": "\(kind) for \(context["actor"] ?? actor)", "level": level.rawValue, "security": context]))
    }

    public static func flush(timeout: TimeInterval = 2) {
        guard let nuggets = Nuggets.shared else { return }
        Auto.tracer?.flush()
        let done = DispatchSemaphore(value: 0)
        nuggets.transport.flush { done.signal() }
        _ = done.wait(timeout: .now() + timeout)
    }
}
