import Foundation
import Sentry
#if os(iOS) || os(tvOS)
import UIKit
#endif

final class StartupClock {
    var deadline: TimeInterval
    private let now: () -> TimeInterval
    private var since: TimeInterval?
    private var spent: TimeInterval = 0
    private(set) var ready = false
    private(set) var stalled = false

    init(deadline: TimeInterval, now: @escaping () -> TimeInterval) {
        self.deadline = deadline
        self.now = now
    }

    var armed: Bool { deadline > 0 && !ready && !stalled && since != nil }

    func foreground() {
        if since == nil { since = now() }
    }

    func background() {
        guard let since else { return }
        spent += now() - since
        self.since = nil
    }

    func elapsed() -> TimeInterval { spent + (since.map { now() - $0 } ?? 0) }

    func remaining() -> TimeInterval { deadline - elapsed() }

    func check() -> Bool {
        guard armed, elapsed() >= deadline else { return false }
        stalled = true
        return true
    }

    func markReady() -> TimeInterval? {
        if ready { return nil }
        ready = true
        return elapsed()
    }
}

enum Startup {
    static let fingerprint = "blipit-startup-stalled"
    static let queue = DispatchQueue(label: "io.blipit.startup")
    static var clock: StartupClock?
    static var pending: DispatchWorkItem?
    static var observers: [NSObjectProtocol] = []

    static func milliseconds(_ seconds: TimeInterval) -> Int { Int((seconds * 1000).rounded()) }

    static func message(_ deadline: TimeInterval) -> String {
        let ms = milliseconds(deadline)
        let seconds = ms % 1000 == 0 ? String(ms / 1000) : String(Double(ms) / 1000)
        return "App did not become ready within \(seconds) s"
    }

    static func start(deadline: TimeInterval) {
        queue.async {
            if let clock {
                clock.deadline = deadline
                arm()
                return
            }
            clock = StartupClock(deadline: deadline, now: { ProcessInfo.processInfo.systemUptime })
            DispatchQueue.main.async { observe() }
        }
    }

    static func observe() {
        #if os(iOS) || os(tvOS)
        let center = NotificationCenter.default
        for name in [UIApplication.willEnterForegroundNotification, UIApplication.didBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { _ in queue.async { clock?.foreground(); arm() } })
        }
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in queue.async { clock?.background(); arm() } })
        let active = UIApplication.shared.applicationState != .background
        queue.async {
            if active { clock?.foreground() }
            arm()
        }
        #else
        queue.async {
            clock?.foreground()
            arm()
        }
        #endif
    }

    static func arm() {
        pending?.cancel()
        pending = nil
        guard let clock, clock.armed else { return }
        let item = DispatchWorkItem { tick() }
        pending = item
        queue.asyncAfter(deadline: .now() + max(0, clock.remaining()), execute: item)
    }

    static func tick() {
        guard let clock else { return }
        let deadline = clock.deadline
        if clock.check() { capture(deadline) } else { arm() }
    }

    static func capture(_ deadline: TimeInterval) {
        let screen = currentScreen()
        let event = Event(level: .warning)
        event.message = SentryMessage(formatted: message(deadline))
        event.fingerprint = [fingerprint]
        SentrySDK.capture(event: event) { scope in
            scope.setTag(value: "true", key: "startup.stalled")
            scope.setTag(value: String(milliseconds(deadline)), key: "startup.deadline_ms")
            if let screen { scope.setTag(value: screen, key: "startup.screen") }
        }
    }

    static func currentScreen() -> String? {
        #if os(iOS)
        var name: String?
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            if #available(iOS 15.0, *), let top = ReportFlow.top() { name = String(describing: type(of: top)) }
            done.signal()
        }
        return done.wait(timeout: .now() + 0.5) == .success ? name : nil
        #else
        return nil
        #endif
    }

    static func ready() {
        queue.async {
            let elapsed = clock?.markReady()
            if clock != nil && elapsed == nil { return }
            pending?.cancel()
            pending = nil
            DispatchQueue.main.async { SentrySDK.reportFullyDisplayed() }
            guard let clock, let elapsed else { return }
            let ms = milliseconds(elapsed)
            let crumb = Breadcrumb(level: .info, category: "startup")
            crumb.message = clock.stalled ? "App became ready after \(ms) ms, past the startup deadline" : "App ready after \(ms) ms"
            crumb.data = ["ready_ms": ms, "stalled": clock.stalled]
            SentrySDK.addBreadcrumb(crumb)
        }
    }
}
