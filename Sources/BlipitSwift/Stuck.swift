import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

public struct StuckLimits: Equatable {
    public let startupMs: Double
    public let flowMs: Double

    public init(startupMs: Double, flowMs: Double) {
        self.startupMs = startupMs
        self.flowMs = flowMs
    }

    public static func from(_ value: Any?) -> StuckLimits? {
        guard let map = value as? [String: Any], let startup = (map["startup_ms"] as? NSNumber)?.doubleValue, let flow = (map["flow_ms"] as? NSNumber)?.doubleValue else { return nil }
        return StuckLimits(startupMs: startup, flowMs: flow)
    }
}

public struct StuckFlow: Equatable {
    public let name: String
    public let step: String?
    public let waitedMs: Double
}

public final class FlowWatch {
    public static let startup = "startup"
    private struct Open {
        var step: String?
        var spent: Double
        var since: Double?
    }

    private var open: [String: Open] = [:]
    private var order: [String] = []
    private var foreground = false
    private let lock = NSLock()

    public init() {}

    public func start(_ name: String, now: Double) {
        lock.lock(); defer { lock.unlock() }
        if open[name] == nil { order.append(name) }
        open[name] = Open(step: nil, spent: 0, since: foreground ? now : nil)
    }

    @discardableResult
    public func step(_ name: String, _ step: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard open[name] != nil else { return false }
        open[name]?.step = step
        return true
    }

    @discardableResult
    public func end(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        order.removeAll { $0 == name }
        return open.removeValue(forKey: name) != nil
    }

    public var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return open.isEmpty
    }

    public func setForeground(_ on: Bool, now: Double) {
        lock.lock(); defer { lock.unlock() }
        guard on != foreground else { return }
        foreground = on
        for name in order {
            guard var flow = open[name] else { continue }
            if on {
                flow.since = now
            } else {
                flow.spent += now - (flow.since ?? now)
                flow.since = nil
            }
            open[name] = flow
        }
    }

    public func due(now: Double, limits: StuckLimits?) -> [StuckFlow] {
        guard let limits else { return [] }
        lock.lock(); defer { lock.unlock() }
        var out: [StuckFlow] = []
        for name in order {
            guard let flow = open[name] else { continue }
            let waited = flow.spent + (flow.since.map { now - $0 } ?? 0)
            let limit = name == FlowWatch.startup ? limits.startupMs : limits.flowMs
            if limit > 0 && waited >= limit {
                out.append(StuckFlow(name: name, step: flow.step, waitedMs: waited))
                open.removeValue(forKey: name)
            }
        }
        order.removeAll { open[$0] == nil }
        return out
    }
}

public enum StuckEvent {
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static func name(_ value: String, max: Int) -> String? {
        let clean = value.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return clean.isEmpty ? nil : String(clean.prefix(max))
    }

    public static func build(stuck: [String: Any], trail: [[String: Any]], release: String?, environment: String?, os: String, model: String?, at: Date = Date()) -> [String: Any] {
        let kind = stuck["kind"] as? String ?? "flow"
        let subject = stuck["flow"] as? String ?? kind
        var body: [String: Any] = [
            "event_id": UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            "timestamp": iso.string(from: at),
            "platform": "other",
            "level": "warning",
            "message": "stuck: \(kind) \(subject)",
            "stuck": stuck,
            "sdk": ["name": "blipit-swift", "version": Blipit.version],
        ]
        var contexts: [String: Any] = ["os": ["name": osName, "version": os]]
        if let model { contexts["device"] = ["model": model] }
        body["contexts"] = contexts
        if !trail.isEmpty { body["breadcrumbs"] = trail }
        if let release { body["release"] = release }
        if let environment { body["environment"] = environment }
        return body
    }

    static var osName: String {
        #if os(iOS)
        return "iOS"
        #elseif os(tvOS)
        return "tvOS"
        #elseif os(watchOS)
        return "watchOS"
        #else
        return "macOS"
        #endif
    }
}

final class StuckTrail {
    private var crumbs: [[String: Any]] = []
    private let max: Int
    private let lock = NSLock()

    init(max: Int = 30) { self.max = max }

    func add(_ category: String, _ message: String, at: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        crumbs.append(["timestamp": StuckEvent.iso.string(from: at), "category": category, "message": message])
        if crumbs.count > max { crumbs.removeFirst(crumbs.count - max) }
    }

    var snapshot: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return crumbs
    }
}

enum Stuck {
    static let watch = FlowWatch()
    static let trail = StuckTrail()
    static let queue = DispatchQueue(label: "io.blipit.stuck")
    static var limits: StuckLimits?
    static var release: String?
    static var environment: String?
    static var timer: DispatchSourceTimer?
    static var pending: [[String: Any]] = []
    static var fetching = false
    static var lastFetch = 0.0
    static var ready = false

    static func now() -> Double { Date().timeIntervalSince1970 * 1000 }

    static func setup(release: String?, environment: String?, waitForReady: Bool) {
        queue.sync {
            guard !ready else { return }
            ready = true
            let info = Bundle.main.infoDictionary
            self.release = release ?? (info?["CFBundleIdentifier"] as? String).map { "\($0)@\(info?["CFBundleShortVersionString"] as? String ?? "0")" }
            self.environment = environment
        }
        observe()
        if waitForReady { start(FlowWatch.startup) }
        queue.async { fetch() }
    }

    static func observe() {
        #if canImport(UIKit) && !os(watchOS)
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in setForeground(false) }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { _ in setForeground(true) }
        let check = { setForeground(UIApplication.shared.applicationState != .background) }
        if Thread.isMainThread { check() } else { DispatchQueue.main.async(execute: check) }
        #else
        setForeground(true)
        #endif
    }

    static func setForeground(_ on: Bool) {
        watch.setForeground(on, now: now())
        if on { schedule() }
    }

    static func start(_ name: String) {
        watch.start(name, now: now())
        trail.add("custom", "flow \(name) started")
        schedule()
    }

    static func step(_ name: String, _ step: String) {
        if watch.step(name, step) { trail.add("custom", "flow \(name): \(step)") }
    }

    static func end(_ name: String) {
        if watch.end(name) { trail.add("custom", "flow \(name) finished") }
    }

    static func schedule() {
        queue.async {
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 1, repeating: 1)
            t.setEventHandler { tick() }
            timer = t
            t.resume()
        }
    }

    static func fetch() {
        guard !fetching, let client = Blipit.reporter else { return }
        fetching = true
        lastFetch = now()
        client.stuckSettings { fresh in
            queue.async {
                fetching = false
                if let fresh { limits = fresh }
            }
        }
    }

    static func tick() {
        if limits == nil && now() - lastFetch > 60_000 { fetch() }
        for flow in watch.due(now: now(), limits: limits) {
            let kind = flow.name == FlowWatch.startup ? "startup" : "flow"
            var stuck: [String: Any] = ["kind": kind, "waited_ms": Int(flow.waitedMs)]
            if kind == "flow" { stuck["flow"] = flow.name }
            if let step = flow.step { stuck["step"] = step }
            let body = StuckEvent.build(stuck: stuck, trail: trail.snapshot, release: release, environment: environment, os: osVersion(), model: model())
            if pending.count < 10 { pending.append(body) }
        }
        flush()
        if watch.isEmpty {
            timer?.cancel()
            timer = nil
        }
    }

    static func flush() {
        guard let nuggets = Nuggets.shared, !pending.isEmpty else { return }
        let batch = pending
        pending = []
        guard nuggets.active else { return }
        for body in batch {
            if let event = nuggets.applyHooks(body) { nuggets.transport.enqueue("/api/v1/events", event) }
        }
    }

    static func osVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    static func model() -> String? {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
        return machine.isEmpty ? nil : machine
    }
}
