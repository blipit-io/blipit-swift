import Foundation
import Sentry

public enum Blipit {
    public static let defaultEndpoint = "https://in.blipit.io"
    public static let version = "0.4.0"
    public static let packageName = "swiftpm:blipit-swift"
    static var reporter: ReportClient?
    static let missingKeyWarning = "[blipit] Blipit.start got no key, so Blipit is off and nothing is sent. Pass the project's public key from app.blipit.io, Keys."
    static let missingProjectWarning = "[blipit] Blipit.start got no project id, so Blipit is off and nothing is sent. Pass the id from the project's Keys page at app.blipit.io."

    public static func dsn(key: String, project: String, endpoint: String = defaultEndpoint) -> String {
        let host = (endpoint.components(separatedBy: "://").last ?? endpoint).replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        let scheme = endpoint.hasPrefix("http://") ? "http" : "https"
        return "\(scheme)://\(key)@\(host)/\(project)"
    }

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
        options.dsn = dsn(key: key, project: project, endpoint: endpoint)
        if let environment { options.environment = environment }
        options.releaseName = release
        options.tracesSampleRate = NSNumber(value: tracesSampleRate)
        options.sendDefaultPii = false
        let user = options.beforeSend
        options.beforeSend = { event in
            identify(event)
            return user.map { $0(event) } ?? event
        }
        reporter = ReportClient(endpoint: endpoint, key: key)
        return true
    }

    static func identify(_ event: Event) {
        var sdk = event.sdk ?? [:]
        var packages = sdk["packages"] as? [[String: Any]] ?? []
        if !packages.contains(where: { $0["name"] as? String == packageName }) {
            packages.append(["name": packageName, "version": version])
            sdk["packages"] = packages
            event.sdk = sdk
        }
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
        let probe = Options()
        guard configure(probe, key: key, project: project) else { return false }
        SentrySDK.start { options in
            configure(options, key: key, project: project, environment: environment, release: release, tracesSampleRate: tracesSampleRate, endpoint: endpoint)
            extra?(options)
            let custom = options.beforeSend
            options.beforeSend = { event in
                identify(event)
                return custom.map { $0(event) } ?? event
            }
        }
        Stuck.setup(release: release, environment: environment, waitForReady: waitForReady || startupDeadline > 0)
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

    @discardableResult
    public static func capture(error: Error) -> SentryId {
        SentrySDK.capture(error: error)
    }

    @discardableResult
    public static func capture(message: String, level: SentryLevel = .info) -> SentryId {
        let event = Event(level: level)
        event.message = SentryMessage(formatted: message)
        return SentrySDK.capture(event: event)
    }

    @discardableResult
    public static func captureException(_ error: Error) -> SentryId {
        capture(error: error)
    }

    @discardableResult
    public static func captureMessage(_ message: String, level: SentryLevel = .info) -> SentryId {
        capture(message: message, level: level)
    }

    public static func setUser(id: String?, email: String? = nil, username: String? = nil) {
        let user = User()
        user.userId = id
        user.email = email
        user.username = username
        SentrySDK.setUser(user)
    }

    public static func setTag(_ key: String, _ value: String) {
        SentrySDK.configureScope { scope in scope.setTag(value: value, key: key) }
    }

    public static func addBreadcrumb(_ message: String, category: String = "default", level: SentryLevel = .info) {
        let crumb = Breadcrumb(level: level, category: category)
        crumb.message = message
        SentrySDK.addBreadcrumb(crumb)
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

    @discardableResult
    public static func captureSecurity(
        kind: String,
        actor: String,
        outcome: String? = nil,
        actorId: String? = nil,
        ip: String? = nil,
        userAgent: String? = nil,
        target: String? = nil
    ) -> SentryId {
        let context = securityContext(kind: kind, actor: actor, outcome: outcome, actorId: actorId, ip: ip, userAgent: userAgent, target: target)
        let level: SentryLevel = kind == "login_failed" || kind == "login_blocked" ? .warning : .info
        let event = Event(level: level)
        event.message = SentryMessage(formatted: "\(kind) for \(actor)")
        return SentrySDK.capture(event: event) { scope in
            scope.setContext(value: context, key: "security")
            scope.setTag(value: kind, key: "security.kind")
        }
    }

    public static func flush(timeout: TimeInterval = 2) {
        SentrySDK.flush(timeout: timeout)
    }
}
