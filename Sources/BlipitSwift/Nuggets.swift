import Foundation
#if canImport(BlipitNuggets)
import BlipitNuggets
#endif
#if canImport(UIKit)
import UIKit
#endif

public enum Level: String {
    case fatal, error, warning, info, debug
}

public struct EventId: Hashable, CustomStringConvertible {
    public let value: String
    public static let empty = EventId(value: "")
    public var description: String { value }
    public var isEmpty: Bool { value.isEmpty }
}

public final class Options {
    public var enabled = true
    public var key = ""
    public var project = ""
    public var endpoint = Blipit.defaultEndpoint
    public var environment = "production"
    public var release: String?
    public var sampleRate = 1.0
    public var tracesSampleRate = 0.0
    public var maxBreadcrumbs = 100
    public var debug = false
    public var crashes = true
    public var machExceptions = true
    public var hangs = true
    public var hangThreshold: TimeInterval = 2
    public var watchdogTerminations = true
    public var sessions = true
    public var networkBreadcrumbs = true
    public var screenBreadcrumbs = true
    public var lifecycleBreadcrumbs = true
    public var shakeToReport = false
    public var screenshotToReport = false
    public var twoFingerReport = false
    public var reportAfterCrash = false
    public var screenPicker = true
    public var beforeSend: (([String: Any]) -> [String: Any]?)?
    public var directory: URL?
    var urlSession: URLSession?

    public init() {}
}

enum Clock {
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func stamp(_ date: Date = Date()) -> String { iso.string(from: date) }
    static func ms(_ date: Date = Date()) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }
    static func id() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
}

enum Json {
    static func read(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func write(_ value: [String: Any], _ url: URL) {
        guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func cut(_ value: String, _ max: Int) -> String {
        value.count > max ? String(value.prefix(max)) : value
    }
}

struct DeviceInfo {
    static let osName: String = {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
        #elseif os(tvOS)
        return "tvOS"
        #elseif os(watchOS)
        return "watchOS"
        #else
        return "macOS"
        #endif
    }()

    static let osVersion: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }()

    static let model: String = {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
    }()

    static var screen: String?

    static func readScreen() {
        #if os(iOS) || os(tvOS)
        let size = UIScreen.main.bounds.size
        screen = "\(Int(size.width))x\(Int(size.height))"
        #endif
    }

    static let app: [String: Any] = {
        var app: [String: Any] = [:]
        let info = Bundle.main.infoDictionary ?? [:]
        if let id = Bundle.main.bundleIdentifier { app["id"] = id }
        if let version = info["CFBundleShortVersionString"] { app["version"] = version }
        if let build = info["CFBundleVersion"] { app["build"] = build }
        return app
    }()

    static var defaultRelease: String? {
        guard let id = app["id"] as? String else { return nil }
        let version = app["version"] as? String ?? "0"
        return app["build"].map { "\(id)@\(version)+\($0)" } ?? "\(id)@\(version)"
    }

    static var build: String {
        "\(app["version"] ?? "")+\(app["build"] ?? "")"
    }

    static var contexts: [String: Any] {
        var device: [String: Any] = ["model": model]
        if let screen { device["screen"] = screen }
        return ["os": ["name": osName, "version": osVersion], "device": device]
    }
}

struct Image {
    let base: UInt
    let size: UInt
    let uuid: String
    let path: String

    var name: String { (path as NSString).lastPathComponent }

    static func loaded() -> [Image] {
        var out: [Image] = []
        var uuid = [CChar](repeating: 0, count: 33)
        for i in 0..<bn_image_count() {
            var base: UInt = 0, size: UInt = 0
            var path: UnsafePointer<CChar>?
            if bn_image_at(i, &base, &size, &uuid, &path) == 1 {
                out.append(Image(base: base, size: size, uuid: String(cString: uuid), path: path.map { String(cString: $0) } ?? "?"))
            }
        }
        return out
    }
}

enum Symbols {
    typealias Demangle = @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?
    static let demangler: Demangle? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle").map { unsafeBitCast($0, to: Demangle.self) }

    static func demangle(_ name: String) -> String {
        guard name.hasPrefix("$s") || name.hasPrefix("_$s") || name.hasPrefix("$S") || name.hasPrefix("_T0"), let demangler else { return name }
        guard let out = name.withCString({ demangler($0, strlen($0), nil, nil, 0) }) else { return name }
        defer { free(out) }
        return String(cString: out)
    }

    static func symbol(_ address: UInt) -> String? {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0, let name = info.dli_sname else { return nil }
        let text = String(cString: name)
        if text == "_mh_execute_header" || text == "<redacted>" || text.isEmpty { return nil }
        return demangle(text)
    }

    static func inApp(_ path: String) -> Bool {
        if path == Bundle.main.executablePath { return true }
        guard path.contains(".app/") else { return false }
        return !path.hasPrefix("/System/") && !path.hasPrefix("/usr/") && !path.contains("/Frameworks/libswift")
    }

    static func frames(_ addresses: [UInt], images: [Image], current: [Image] = Image.loaded()) -> (frames: [[String: Any]], raw: [String], used: [[String: String]]) {
        var frames: [[String: Any]] = []
        var raw: [String] = []
        var used: [String: [String: String]] = [:]
        let byUUID = Dictionary(current.map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        for (index, address) in addresses.prefix(128).enumerated() {
            let lookup = index == 0 || address == 0 ? address : address - 1
            guard let image = images.first(where: { lookup >= $0.base && lookup < $0.base + $0.size }) else {
                frames.append(["filename": "?", "function": "0x" + String(address, radix: 16), "in_app": false])
                raw.append("? 0x" + String(address, radix: 16))
                continue
            }
            let offset = lookup - image.base
            let hex = "0x" + String(offset, radix: 16)
            var name: String?
            if let now = byUUID[image.uuid], image.uuid != String(repeating: "0", count: 32) {
                name = symbol(now.base + offset)
            }
            frames.append(["filename": Json.cut(image.name, 1024), "function": Json.cut(name ?? "\(image.name) + \(hex)", 512), "in_app": inApp(image.path)])
            raw.append("\(image.name) \(hex)")
            used[image.uuid] = ["name": image.name, "uuid": image.uuid]
        }
        return (frames.reversed(), raw, Array(used.values))
    }

    static func here(skipping prefix: String = "BlipitSwift.") -> [UInt] {
        let all = Thread.callStackReturnAddresses.map { $0.uintValue }
        let firstOutside = all.firstIndex { address in !(symbol(address)?.contains(prefix) ?? false) } ?? 0
        return Array(all.dropFirst(firstOutside))
    }
}

final class Scope {
    private let lock = NSLock()
    private(set) var user: [String: String]?
    private(set) var tags: [String: String] = [:]
    private(set) var context: [String: Any] = [:]
    private(set) var breadcrumbs: [[String: Any]] = []
    var max = 100

    static let categories: Set<String> = ["ui.click", "ui.input", "navigation", "http", "console", "query", "custom"]

    func setUser(_ user: [String: String]?) { lock.lock(); self.user = user; lock.unlock() }

    func setTag(_ key: String, _ value: String) {
        lock.lock(); defer { lock.unlock() }
        let key = Json.cut(key.filter { $0.isLetter || $0.isNumber || "_.-".contains($0) }, 64)
        guard !key.isEmpty, tags[key] != nil || tags.count < 32 else { return }
        tags[key] = Json.cut(value, 256)
    }

    func setContext(_ key: String, _ value: Any?) {
        lock.lock(); defer { lock.unlock() }
        context[key] = value
    }

    func add(_ message: String?, category: String, level: Level = .info, data: [String: Any]? = nil, at: Date = Date()) {
        var crumb: [String: Any] = ["timestamp": Clock.stamp(at), "category": Scope.categories.contains(category) ? category : "custom"]
        if let message { crumb["message"] = Json.cut(message, 1024) }
        crumb["level"] = level == .fatal ? "error" : level.rawValue
        var data = data ?? [:]
        if !Scope.categories.contains(category) { data["category"] = category }
        if !data.isEmpty, JSONSerialization.isValidJSONObject(data) { crumb["data"] = data }
        lock.lock(); defer { lock.unlock() }
        breadcrumbs.append(crumb)
        if breadcrumbs.count > min(max, 100) { breadcrumbs.removeFirst(breadcrumbs.count - min(max, 100)) }
    }

    func snapshot() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        var out: [String: Any] = ["tags": tags, "breadcrumbs": breadcrumbs]
        if let user { out["user"] = user }
        if !context.isEmpty, JSONSerialization.isValidJSONObject(context) { out["context"] = context }
        return out
    }
}

enum Outcome {
    case delivered, drop, retry, limited(TimeInterval), refused
}

final class Transport {
    let endpoint: String
    let key: String
    let dir: URL
    let session: URLSession
    let io: DispatchQueue
    var blockedUntil = Date.distantPast
    var stopped = false
    var sending = false
    var waiters: [() -> Void] = []
    var failures = 0
    var retryScheduled = false
    var counter = 0
    let maxItems = 100

    init(endpoint: String, key: String, dir: URL, session: URLSession, io: DispatchQueue) {
        self.endpoint = endpoint.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        self.key = key
        self.dir = dir
        self.session = session
        self.io = io
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let text = try? String(contentsOf: dir.appendingPathComponent("retry-after"), encoding: .utf8), let at = Double(text) {
            blockedUntil = Date(timeIntervalSince1970: at)
        }
    }

    var host: String? { URL(string: endpoint)?.host }

    func pending() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted().map { dir.appendingPathComponent($0) }
    }

    func enqueue(_ path: String, _ body: [String: Any]) {
        io.async {
            guard !self.stopped else { return }
            self.counter += 1
            let name = String(format: "%013lld-%06d.json", Clock.ms(), self.counter % 1_000_000)
            Json.write(["path": path, "body": body], self.dir.appendingPathComponent(name))
            let all = self.pending()
            for old in all.prefix(max(0, all.count - self.maxItems)) { try? FileManager.default.removeItem(at: old) }
            self.pump()
        }
    }

    func clear() {
        io.async {
            for file in self.pending() { try? FileManager.default.removeItem(at: file) }
        }
    }

    func flush(_ done: (() -> Void)? = nil) {
        io.async { self.pump(done) }
    }

    func pump(_ done: (() -> Void)? = nil) {
        if let done { waiters.append(done) }
        guard !sending else { return }
        guard !stopped, Date() >= blockedUntil, let next = pending().first else { return finish() }
        guard let item = Json.read(next), let path = item["path"] as? String, let body = item["body"] as? [String: Any] else {
            try? FileManager.default.removeItem(at: next)
            return pump()
        }
        sending = true
        send(path, body) { outcome in
            self.io.async {
                self.sending = false
                switch outcome {
                case .delivered, .drop:
                    self.failures = 0
                    try? FileManager.default.removeItem(at: next)
                    self.pump()
                case .refused:
                    try? FileManager.default.removeItem(at: next)
                    self.stopped = true
                    self.finish()
                case let .limited(wait):
                    self.blockedUntil = Date().addingTimeInterval(wait)
                    try? String(self.blockedUntil.timeIntervalSince1970).write(to: self.dir.appendingPathComponent("retry-after"), atomically: true, encoding: .utf8)
                    self.later(wait)
                    self.finish()
                case .retry:
                    self.failures += 1
                    self.later(min(300, 5 * pow(2, Double(min(self.failures, 6)))))
                    self.finish()
                }
            }
        }
    }

    func finish() {
        let list = waiters
        waiters = []
        list.forEach { $0() }
    }

    func later(_ wait: TimeInterval) {
        guard !retryScheduled else { return }
        retryScheduled = true
        io.asyncAfter(deadline: .now() + wait) {
            self.retryScheduled = false
            self.pump()
        }
    }

    static func retryAfter(_ response: HTTPURLResponse, _ data: Data?) -> TimeInterval {
        if let header = response.value(forHTTPHeaderField: "Retry-After") {
            if let seconds = Double(header.trimmingCharacters(in: .whitespaces)) { return max(1, seconds) }
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = f.date(from: header) { return max(1, date.timeIntervalSinceNow) }
        }
        if let data, let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let wait = (json["retry_after"] as? NSNumber)?.doubleValue {
            return max(1, wait)
        }
        return 60
    }

    static func outcome(_ status: Int, _ response: HTTPURLResponse?, _ data: Data?) -> Outcome {
        switch status {
        case 200..<300: return .delivered
        case 429: return response.map { .limited(retryAfter($0, data)) } ?? .limited(60)
        case 401: return .refused
        case 403:
            let reason = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }?["reason"] as? String
            return reason == "security_needs_secret_key" ? .drop : .refused
        case 408, 500..<600, 0: return .retry
        default: return .drop
        }
    }

    func send(_ path: String, _ body: [String: Any], _ done: @escaping (Outcome) -> Void) {
        guard let url = URL(string: endpoint + path), let data = try? JSONSerialization.data(withJSONObject: body) else { return done(.drop) }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "X-Blipit-Key")
        request.httpBody = data
        session.dataTask(with: request) { data, response, error in
            if error != nil { return done(.retry) }
            let http = response as? HTTPURLResponse
            done(Transport.outcome(http?.statusCode ?? 0, http, data))
        }.resume()
    }
}

final class Nuggets {
    static var shared: Nuggets?

    let options: Options
    let dir: URL
    let scope = Scope()
    let transport: Transport
    let io = DispatchQueue(label: "io.blipit.nuggets")
    let release: String?
    var previous: [String: Any]?
    var run: [String: Any] = [:]
    var pendingCrash: String?
    var scopeDirty = false
    var consent = true
    let consentFile: URL
    let sampler: () -> Double

    init(options: Options, sampler: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        self.options = options
        self.sampler = sampler
        dir = options.directory ?? Nuggets.defaultDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var marked = dir
        try? marked.setResourceValues(values)
        consentFile = dir.appendingPathComponent("consent-denied")
        consent = !FileManager.default.fileExists(atPath: consentFile.path)
        release = options.release ?? DeviceInfo.defaultRelease
        let session = options.urlSession ?? URLSession(configuration: .ephemeral)
        transport = Transport(endpoint: options.endpoint, key: options.key, dir: dir.appendingPathComponent("queue"), session: session, io: io)
        scope.max = options.maxBreadcrumbs
        if !consent { transport.stopped = true }
    }

    static func defaultDirectory() -> URL {
        #if os(tvOS)
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        #else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #endif
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "blipit").appendingPathComponent("blipit-nuggets")
    }

    var scopeFile: URL { dir.appendingPathComponent("scope.json") }
    var runFile: URL { dir.appendingPathComponent("run.json") }
    var crashFile: URL { dir.appendingPathComponent("crash.txt") }

    func log(_ text: String) {
        if options.debug { print("[blipit] " + text) }
    }

    func setConsent(_ granted: Bool) {
        io.async {
            self.consent = granted
            self.transport.stopped = !granted
            if granted {
                try? FileManager.default.removeItem(at: self.consentFile)
                self.transport.pump()
            } else {
                FileManager.default.createFile(atPath: self.consentFile.path, contents: Data())
                for file in self.transport.pending() { try? FileManager.default.removeItem(at: file) }
                try? FileManager.default.removeItem(at: self.crashFile)
            }
        }
    }

    var active: Bool { options.enabled && consent && !transport.stopped }

    func scopeChanged() {
        io.async {
            guard !self.scopeDirty else { return }
            self.scopeDirty = true
            self.io.asyncAfter(deadline: .now() + 0.25) {
                self.scopeDirty = false
                var saved = self.scope.snapshot()
                saved["release"] = self.release
                saved["environment"] = self.options.environment
                Json.write(saved, self.scopeFile)
            }
        }
    }

    func saveRun() {
        let state = run
        io.async { Json.write(state, self.runFile) }
    }

    func updateRun(_ change: @escaping (inout [String: Any]) -> Void) {
        io.async {
            change(&self.run)
            self.run["at"] = Clock.ms()
            Json.write(self.run, self.runFile)
        }
    }

    func event(_ partial: [String: Any], scope saved: [String: Any]? = nil, at: Date = Date()) -> [String: Any] {
        let source = saved ?? scope.snapshot()
        var event: [String: Any] = [
            "event_id": Clock.id(),
            "timestamp": Clock.stamp(at),
            "platform": "other",
            "level": "error",
            "environment": Json.cut((saved?["environment"] as? String) ?? options.environment, 64),
            "contexts": DeviceInfo.contexts,
            "sdk": ["name": "blipit-swift", "version": Blipit.version],
        ]
        if let release = (saved?["release"] as? String) ?? release { event["release"] = Json.cut(release, 256) }
        if let user = source["user"] as? [String: String], !user.isEmpty { event["user"] = user }
        if let tags = source["tags"] as? [String: String], !tags.isEmpty { event["tags"] = tags }
        if let crumbs = source["breadcrumbs"] as? [[String: Any]], !crumbs.isEmpty { event["breadcrumbs"] = crumbs }
        var extra: [String: Any] = ["app": DeviceInfo.app]
        if let context = source["context"] as? [String: Any] { extra.merge(context) { a, _ in a } }
        event["extra"] = extra
        for (k, v) in partial { event[k] = v }
        return event
    }

    @discardableResult
    func send(_ event: [String: Any]) -> EventId {
        guard active else { return .empty }
        let level = event["level"] as? String
        if level != "fatal", options.sampleRate < 1, sampler() >= options.sampleRate { return .empty }
        var event = event
        if let hook = options.beforeSend {
            guard let changed = hook(event) else { return .empty }
            event = changed
        }
        guard JSONSerialization.isValidJSONObject(event) else {
            log("event dropped, it holds values that are not JSON")
            return .empty
        }
        transport.enqueue("/api/v1/events", event)
        if let exception = event["exception"] as? [String: Any] {
            Sessions.shared?.markError(crashed: exception["handled"] as? Bool == false)
        }
        return EventId(value: event["event_id"] as? String ?? "")
    }

    static func exception(_ error: Error) -> (type: String, value: String) {
        let kind = type(of: error)
        if kind is NSError.Type {
            let ns = error as NSError
            return ("\(ns.domain) \(ns.code)", ns.localizedDescription)
        }
        return (String(reflecting: kind), String(describing: error))
    }

    @discardableResult
    func capture(error: Error, addresses: [UInt] = Symbols.here()) -> EventId {
        let (kind, value) = Nuggets.exception(error)
        let symbolicated = Symbols.frames(addresses, images: Image.loaded())
        var exception: [String: Any] = ["type": Json.cut(kind, 256), "value": Json.cut(value, 4096), "handled": true]
        if !symbolicated.frames.isEmpty { exception["stacktrace"] = ["frames": symbolicated.frames] }
        var event = self.event(["exception": exception, "level": "error"])
        if !symbolicated.used.isEmpty, var extra = event["extra"] as? [String: Any] {
            extra["debug_images"] = symbolicated.used
            event["extra"] = extra
        }
        return send(event)
    }

    @discardableResult
    func capture(message: String, level: Level) -> EventId {
        send(event(["message": Json.cut(message, 8192), "level": level.rawValue]))
    }
}
