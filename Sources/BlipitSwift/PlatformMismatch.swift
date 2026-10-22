import Foundation

enum PlatformMismatch {
    private static let lock = NSLock()
    private static var hit = false

    static var blocked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hit
    }

    @discardableResult
    static func check(_ status: Int, _ data: Data?) -> Bool {
        guard status == 409, let data, let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], json["reason"] as? String == "platform_mismatch" else { return false }
        lock.lock()
        let first = !hit
        hit = true
        lock.unlock()
        if first {
            let message = json["error"] as? String ?? "This key belongs to a Blipit project for another platform."
            NSLog("%@", "[blipit] BLIPIT IS NOT SENDING: \(message) Nothing more is sent with this key until the app restarts.")
        }
        return true
    }

    static func reset() {
        lock.lock()
        hit = false
        lock.unlock()
    }
}
