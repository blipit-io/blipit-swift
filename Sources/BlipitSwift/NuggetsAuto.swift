import Foundation
import ObjectiveC
#if canImport(BlipitNuggets)
import BlipitNuggets
#endif
#if canImport(UIKit)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

final class Tracer {
    let nuggets: Nuggets
    let rate: Double
    private let lock = NSLock()
    private var buffer: [[String: Any]] = []
    private var scheduled = false

    init(_ nuggets: Nuggets, rate: Double) {
        self.nuggets = nuggets
        self.rate = rate
    }

    func sampled() -> Bool { rate > 0 && nuggets.sampler() < rate }

    static func hex(_ bytes: Int) -> String {
        (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    static func attribute(_ key: String, _ value: Any) -> [String: Any] {
        switch value {
        case let v as Bool: return ["key": key, "value": ["boolValue": v]]
        case let v as Int: return ["key": key, "value": ["intValue": v]]
        case let v as Double: return ["key": key, "value": ["doubleValue": v]]
        default: return ["key": key, "value": ["stringValue": "\(value)"]]
        }
    }

    static func nanos(_ date: Date) -> String { String(Int64(date.timeIntervalSince1970 * 1_000_000_000)) }

    func record(_ name: String, kind: Int, start: Date, end: Date, attributes: [String: Any] = [:], error: Bool = false) {
        guard nuggets.active else { return }
        let span: [String: Any] = [
            "traceId": Tracer.hex(16),
            "spanId": Tracer.hex(8),
            "name": Json.cut(name, 512),
            "kind": kind,
            "startTimeUnixNano": Tracer.nanos(start),
            "endTimeUnixNano": Tracer.nanos(max(start, end)),
            "attributes": attributes.map { Tracer.attribute($0.key, $0.value) } + [Tracer.attribute("blipit.sample_rate", rate)],
            "status": ["code": error ? 2 : 1],
        ]
        lock.lock()
        buffer.append(span)
        let full = buffer.count >= 50
        let schedule = !scheduled && !full
        if schedule { scheduled = true }
        lock.unlock()
        if full { flush() } else if schedule { nuggets.io.asyncAfter(deadline: .now() + 10) { self.flush() } }
    }

    func payload(_ spans: [[String: Any]]) -> [String: Any] {
        var resource: [[String: Any]] = [
            Tracer.attribute("service.name", Bundle.main.bundleIdentifier ?? "app"),
            Tracer.attribute("deployment.environment", nuggets.options.environment),
            Tracer.attribute("telemetry.sdk.name", "blipit-swift"),
            Tracer.attribute("telemetry.sdk.version", Blipit.version),
            Tracer.attribute("os.name", DeviceInfo.osName),
            Tracer.attribute("os.version", DeviceInfo.osVersion),
            Tracer.attribute("device.model.identifier", DeviceInfo.model),
        ]
        if let release = nuggets.release { resource.append(Tracer.attribute("service.version", release)) }
        return ["resourceSpans": [["resource": ["attributes": resource], "scopeSpans": [["scope": ["name": "blipit-swift"], "spans": spans]]]]]
    }

    func flush() {
        lock.lock()
        let spans = buffer
        buffer = []
        scheduled = false
        lock.unlock()
        if !spans.isEmpty { nuggets.transport.enqueue("/v1/traces", payload(spans)) }
    }
}

enum Network {
    static var installed = false
    static var host: String?
    static var key: UInt8 = 0

    final class Watch: NSObject {
        let started = Date()
        var observation: NSKeyValueObservation?
    }

    static func clean(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "" }
        parts.user = nil
        parts.password = nil
        parts.query = nil
        parts.fragment = nil
        return Json.cut(parts.string ?? "", 2048)
    }

    static func install(host: String?) {
        guard !installed else { return }
        installed = true
        self.host = host
        let session = URLSession(configuration: .ephemeral)
        guard let url = URL(string: "https://127.0.0.1") else { return }
        let task = session.dataTask(with: url)
        let selector = NSSelectorFromString("resume")
        var current: AnyClass? = object_getClass(task)
        while let cls = current, cls != NSObject.self {
            let superclass: AnyClass? = class_getSuperclass(cls)
            if let method = class_getInstanceMethod(cls, selector) {
                let inherited = superclass.flatMap { class_getInstanceMethod($0, selector) }.map(method_getImplementation)
                if inherited != method_getImplementation(method) { hook(method, selector) }
            }
            current = superclass
        }
        task.cancel()
        session.invalidateAndCancel()
    }

    static func hook(_ method: Method, _ selector: Selector) {
        typealias Resume = @convention(c) (AnyObject, Selector) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Resume.self)
        let block: @convention(block) (AnyObject) -> Void = { object in
            if let task = object as? URLSessionTask { willResume(task) }
            original(object, selector)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    static func willResume(_ task: URLSessionTask) {
        guard let nuggets = Nuggets.shared, nuggets.active, task.state == .suspended,
              objc_getAssociatedObject(task, &key) == nil,
              let url = task.currentRequest?.url ?? task.originalRequest?.url,
              url.scheme?.hasPrefix("http") == true, url.host != host else { return }
        let watch = Watch()
        objc_setAssociatedObject(task, &key, watch, .OBJC_ASSOCIATION_RETAIN)
        watch.observation = task.observe(\.state, options: [.new]) { task, _ in
            guard task.state == .completed else { return }
            finished(task, watch: watch, url: url)
        }
    }

    static func finished(_ task: URLSessionTask, watch: Watch, url: URL) {
        guard let nuggets = Nuggets.shared, watch.observation != nil else { return }
        let observation = watch.observation
        watch.observation = nil
        nuggets.io.async { observation?.invalidate() }
        let method = task.originalRequest?.httpMethod ?? "GET"
        let status = (task.response as? HTTPURLResponse)?.statusCode
        let failed = task.error != nil && (task.error as NSError?)?.code != NSURLErrorCancelled
        let ended = Date()
        if nuggets.options.networkBreadcrumbs {
            var data: [String: Any] = ["url": clean(url), "method": method, "duration_ms": Int(ended.timeIntervalSince(watch.started) * 1000)]
            if let status { data["status_code"] = status }
            if failed, let error = task.error as NSError? { data["error"] = "\(error.domain) \(error.code)" }
            let level: Level = failed || (status ?? 0) >= 500 ? .error : (status ?? 0) >= 400 ? .warning : .info
            nuggets.scope.add("\(method) \(clean(url))" + (status.map { " \($0)" } ?? ""), category: "http", level: level, data: data)
            nuggets.scopeChanged()
        }
        if let tracer = Auto.tracer, tracer.sampled() {
            var attributes: [String: Any] = ["http.request.method": method, "url.full": clean(url)]
            if let host = url.host { attributes["server.address"] = host }
            if let status { attributes["http.response.status_code"] = status }
            tracer.record("\(method) \(url.host ?? "")\(url.path)", kind: 3, start: watch.started, end: ended, attributes: attributes, error: failed || (status ?? 0) >= 500)
        }
    }
}

enum Auto {
    static var tracer: Tracer?
    static var hang: HangWatch?
    static var started = false
    static var appStartSent = false
    static var observers: [NSObjectProtocol] = []

    static func install(_ nuggets: Nuggets) {
        if nuggets.options.tracesSampleRate > 0 { tracer = Tracer(nuggets, rate: min(1, nuggets.options.tracesSampleRate)) }
        if nuggets.options.networkBreadcrumbs || tracer != nil { Network.install(host: nuggets.transport.host) }
        if nuggets.options.hangs {
            let watch = HangWatch(nuggets, threshold: nuggets.options.hangThreshold)
            hang = watch
            watch.start()
        }
        onMain {
            bn_mark_main_thread()
            DeviceInfo.readScreen()
            lifecycle(nuggets)
            #if os(iOS) || os(tvOS)
            if nuggets.options.screenBreadcrumbs || nuggets.options.screenPicker || tracer != nil { Screens.install() }
            #endif
        }
    }

    static func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    static func setForeground(_ on: Bool, _ nuggets: Nuggets) {
        hang?.foreground = on
        nuggets.updateRun { $0["foreground"] = on }
        if on {
            Sessions.shared?.foreground()
        } else {
            Sessions.shared?.background()
            tracer?.flush()
            nuggets.transport.flush()
        }
    }

    static func crumb(_ nuggets: Nuggets, _ message: String) {
        guard nuggets.options.lifecycleBreadcrumbs else { return }
        nuggets.scope.add(message, category: "app.lifecycle")
        nuggets.scopeChanged()
    }

    static func appStarted(_ nuggets: Nuggets) {
        guard !appStartSent else { return }
        appStartSent = true
        let start = Date(timeIntervalSince1970: Double(bn_process_start_ms()) / 1000)
        let now = Date()
        guard let tracer, tracer.sampled(), now.timeIntervalSince(start) < 60 else { return }
        tracer.record("App Start", kind: 1, start: start, end: now, attributes: ["app.start.type": "cold"])
    }

    static func lifecycle(_ nuggets: Nuggets) {
        let center = NotificationCenter.default
        func on(_ name: Notification.Name, _ run: @escaping () -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { _ in run() })
        }
        #if os(iOS) || os(tvOS)
        on(UIApplication.didBecomeActiveNotification) { crumb(nuggets, "app became active"); appStarted(nuggets) }
        on(UIApplication.willResignActiveNotification) { crumb(nuggets, "app will resign active") }
        on(UIApplication.didEnterBackgroundNotification) { crumb(nuggets, "app entered background"); setForeground(false, nuggets) }
        on(UIApplication.willEnterForegroundNotification) { crumb(nuggets, "app will enter foreground"); setForeground(true, nuggets) }
        on(UIApplication.didReceiveMemoryWarningNotification) {
            crumb(nuggets, "low memory warning")
            nuggets.updateRun { $0["memory_warning"] = true }
        }
        on(UIApplication.willTerminateNotification) { crumb(nuggets, "app will terminate"); nuggets.cleanExit() }
        setForeground(UIApplication.shared.applicationState != .background, nuggets)
        #elseif os(macOS)
        on(NSApplication.didBecomeActiveNotification) { crumb(nuggets, "app became active"); appStarted(nuggets) }
        on(NSApplication.didResignActiveNotification) { crumb(nuggets, "app resigned active") }
        on(NSApplication.willTerminateNotification) { crumb(nuggets, "app will terminate"); nuggets.cleanExit() }
        setForeground(true, nuggets)
        #else
        setForeground(true, nuggets)
        #endif
    }
}

#if os(iOS) || os(tvOS)
enum Screens {
    static var installed = false
    static var key: UInt8 = 0
    static var current: String?

    static func install() {
        guard !installed else { return }
        installed = true
        swap(#selector(UIViewController.viewDidLoad), #selector(UIViewController.blipitViewDidLoad))
        swap(#selector(UIViewController.viewDidAppear(_:)), #selector(UIViewController.blipitViewDidAppear(_:)))
    }

    static func swap(_ original: Selector, _ replacement: Selector) {
        guard let a = class_getInstanceMethod(UIViewController.self, original), let b = class_getInstanceMethod(UIViewController.self, replacement) else { return }
        method_exchangeImplementations(a, b)
    }

    static func tracked(_ controller: UIViewController) -> String? {
        let type = Swift.type(of: controller)
        guard Bundle(for: type) == Bundle.main else { return nil }
        let name = String(describing: type)
        return name.hasPrefix("_") ? nil : name
    }

    static func loaded(_ controller: UIViewController) {
        guard Auto.tracer != nil, tracked(controller) != nil else { return }
        objc_setAssociatedObject(controller, &key, Date(), .OBJC_ASSOCIATION_RETAIN)
    }

    static func appeared(_ controller: UIViewController) {
        guard let nuggets = Nuggets.shared, let name = tracked(controller) else { return }
        if nuggets.options.screenBreadcrumbs, name != current {
            var data: [String: Any] = ["to": name]
            if let current { data["from"] = current }
            nuggets.scope.add("screen \(name)", category: "navigation", data: data)
            nuggets.scopeChanged()
        }
        current = name
        #if os(iOS)
        if nuggets.options.screenPicker, #available(iOS 15.0, *) { ReportTriggers.screenAppeared(name) }
        #endif
        if let start = objc_getAssociatedObject(controller, &key) as? Date {
            objc_setAssociatedObject(controller, &key, nil, .OBJC_ASSOCIATION_RETAIN)
            if let tracer = Auto.tracer, tracer.sampled() {
                tracer.record("\(name) load", kind: 1, start: start, end: Date(), attributes: ["ui.screen": name])
            }
        }
    }
}

extension UIViewController {
    @objc func blipitViewDidLoad() {
        blipitViewDidLoad()
        Screens.loaded(self)
    }

    @objc func blipitViewDidAppear(_ animated: Bool) {
        blipitViewDidAppear(animated)
        Screens.appeared(self)
    }
}
#endif
