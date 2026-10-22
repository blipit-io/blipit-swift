import Foundation

public enum ReportTrigger: String {
    case shake
    case screenshot
    case twoFinger = "two_finger"
    case crash
}

struct TriggerGate {
    var gap: TimeInterval = 1.5
    private(set) var last = -TimeInterval.infinity

    mutating func allow(now: TimeInterval, busy: Bool) -> Bool {
        guard !busy, now - last >= gap else { return false }
        last = now
        return true
    }
}

struct PromptState {
    enum Kind { case screenshot, crash }

    private(set) var kind: Kind?
    private(set) var shownAt: TimeInterval = 0

    static func timeout(_ kind: Kind) -> TimeInterval { kind == .crash ? 15 : 6 }

    mutating func show(_ kind: Kind, now: TimeInterval, reporterOpen: Bool) -> Bool {
        guard self.kind == nil, !reporterOpen else { return false }
        self.kind = kind
        shownAt = now
        return true
    }

    mutating func choose(report: Bool) -> Kind? {
        defer { kind = nil }
        return report ? kind : nil
    }

    mutating func expire(now: TimeInterval) -> Bool {
        guard let kind, now - shownAt >= PromptState.timeout(kind) else { return false }
        self.kind = nil
        return true
    }
}

struct ScreenShelf<Image> {
    static var earlierMax: Int { 3 }
    static var idleClear: TimeInterval { 180 }

    private(set) var entries: [(name: String, image: Image)] = []

    mutating func add(_ name: String, _ image: Image) {
        entries.removeAll { $0.name == name }
        entries.insert((name, image), at: 0)
        if entries.count > ScreenShelf.earlierMax + 1 { entries.removeLast(entries.count - ScreenShelf.earlierMax - 1) }
    }

    func earlier(than current: String?) -> [Image] {
        Array(entries.filter { $0.name != current }.prefix(ScreenShelf.earlierMax).map(\.image))
    }

    mutating func clear() { entries = [] }

    mutating func foreground(after away: TimeInterval) {
        if away >= ScreenShelf.idleClear { clear() }
    }
}

enum ReportSettings {
    static func button(_ json: Any?) -> Bool {
        (json as? [String: Any])?["report_button"] as? Bool ?? false
    }

    static func crashId(_ value: String) -> String? {
        let id = value.lowercased()
        return id.count == 32 && id.allSatisfy(\.isHexDigit) ? id : nil
    }
}
