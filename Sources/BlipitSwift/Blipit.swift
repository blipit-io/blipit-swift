import Foundation
import Sentry

public enum Blipit {
    public static let defaultEndpoint = "https://in.blipit.io"

    public static func dsn(key: String, project: String, endpoint: String = defaultEndpoint) -> String {
        let host = (endpoint.components(separatedBy: "://").last ?? endpoint).replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        let scheme = endpoint.hasPrefix("http://") ? "http" : "https"
        return "\(scheme)://\(key)@\(host)/\(project)"
    }

    public static func configure(
        _ options: Options,
        key: String,
        project: String,
        environment: String? = nil,
        release: String? = nil,
        tracesSampleRate: Double = 0,
        endpoint: String = defaultEndpoint
    ) {
        precondition(!key.isEmpty, "Blipit.start needs the project's public key")
        precondition(!project.isEmpty, "Blipit.start needs the project id")
        options.dsn = dsn(key: key, project: project, endpoint: endpoint)
        if let environment { options.environment = environment }
        options.releaseName = release
        options.tracesSampleRate = NSNumber(value: tracesSampleRate)
        options.sendDefaultPii = false
    }

    public static func start(
        key: String,
        project: String,
        environment: String? = nil,
        release: String? = nil,
        tracesSampleRate: Double = 0,
        endpoint: String = defaultEndpoint,
        configure extra: ((Options) -> Void)? = nil
    ) {
        SentrySDK.start { options in
            configure(options, key: key, project: project, environment: environment, release: release, tracesSampleRate: tracesSampleRate, endpoint: endpoint)
            extra?(options)
        }
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
