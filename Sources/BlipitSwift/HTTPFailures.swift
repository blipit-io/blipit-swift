import Foundation

final class FailureGate {
    private var seen: [String: (at: Double, folded: Int)] = [:]
    private let lock = NSLock()

    func pass(_ key: String, now: Double, intervalMs: Double) -> Int? {
        lock.lock(); defer { lock.unlock() }
        if let last = seen[key], now - last.at < intervalMs {
            seen[key] = (last.at, last.folded + 1)
            return nil
        }
        let folded = seen[key]?.folded ?? 0
        if seen.count >= 500 { seen = seen.filter { now - $0.value.at < intervalMs } }
        seen[key] = (now, 0)
        return folded
    }
}

enum HTTPFailures {
    static let type = "HTTPRequestFailed"
    static let gate = FailureGate()
    static var enabled = true
    static var intervalMs = 60_000.0

    static func configure(_ value: Any?) {
        guard let map = value as? [String: Any] else { return }
        if let on = map["enabled"] as? Bool { enabled = on }
        if let ms = (map["interval_ms"] as? NSNumber)?.doubleValue, ms >= 0 { intervalMs = ms }
    }

    static let names: [Int: String] = [
        NSURLErrorTimedOut: "timedOut",
        NSURLErrorCannotFindHost: "cannotFindHost",
        NSURLErrorCannotConnectToHost: "cannotConnectToHost",
        NSURLErrorNetworkConnectionLost: "networkConnectionLost",
        NSURLErrorDNSLookupFailed: "dnsLookupFailed",
        NSURLErrorNotConnectedToInternet: "notConnectedToInternet",
        NSURLErrorBadServerResponse: "badServerResponse",
        NSURLErrorBadURL: "badURL",
        NSURLErrorUnsupportedURL: "unsupportedURL",
        NSURLErrorHTTPTooManyRedirects: "httpTooManyRedirects",
        NSURLErrorRedirectToNonExistentLocation: "redirectToNonExistentLocation",
        NSURLErrorResourceUnavailable: "resourceUnavailable",
        NSURLErrorZeroByteResource: "zeroByteResource",
        NSURLErrorCannotDecodeRawData: "cannotDecodeRawData",
        NSURLErrorCannotDecodeContentData: "cannotDecodeContentData",
        NSURLErrorCannotParseResponse: "cannotParseResponse",
        NSURLErrorUserAuthenticationRequired: "userAuthenticationRequired",
        NSURLErrorSecureConnectionFailed: "secureConnectionFailed",
        NSURLErrorServerCertificateHasBadDate: "serverCertificateHasBadDate",
        NSURLErrorServerCertificateUntrusted: "serverCertificateUntrusted",
        NSURLErrorServerCertificateHasUnknownRoot: "serverCertificateHasUnknownRoot",
        NSURLErrorServerCertificateNotYetValid: "serverCertificateNotYetValid",
        NSURLErrorClientCertificateRejected: "clientCertificateRejected",
        NSURLErrorClientCertificateRequired: "clientCertificateRequired",
        NSURLErrorCannotLoadFromNetwork: "cannotLoadFromNetwork",
        NSURLErrorInternationalRoamingOff: "internationalRoamingOff",
        NSURLErrorCallIsActive: "callIsActive",
        NSURLErrorDataNotAllowed: "dataNotAllowed",
        NSURLErrorRequestBodyStreamExhausted: "requestBodyStreamExhausted",
        NSURLErrorAppTransportSecurityRequiresSecureConnection: "appTransportSecurityRequiresSecureConnection",
        NSURLErrorBackgroundSessionWasDisconnected: "backgroundSessionWasDisconnected",
        NSURLErrorUnknown: "unknown",
    ]

    static func name(_ error: NSError) -> String {
        error.domain == NSURLErrorDomain ? names[error.code] ?? "URLError \(error.code)" : "\(error.domain) \(error.code)"
    }

    static func failed(status: Int?, error: NSError?) -> Bool {
        if let error { return !(error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled) }
        return (status ?? 0) >= 500
    }

    static func event(_ nuggets: Nuggets, method: String, url: URL, status: Int?, error: NSError?, durationMs: Int, folded: Int) -> [String: Any] {
        let reason = error.map(name) ?? status.map(String.init) ?? "unknown"
        let path = url.path.isEmpty ? "/" : url.path
        var http: [String: Any] = ["method": method, "url": Network.clean(url), "duration_ms": durationMs]
        if let status { http["status_code"] = status }
        if let error {
            http["error_code"] = error.code
            http["error"] = name(error)
        }
        if folded > 0 { http["repeated"] = folded }
        var event = nuggets.event([
            "level": "error",
            "exception": ["type": type, "value": Json.cut("\(method) \(url.host ?? "")\(path) failed: \(reason)", 4096), "handled": true],
            "request": ["url": Network.clean(url), "method": Json.cut(method, 16)],
        ])
        var extra = event["extra"] as? [String: Any] ?? [:]
        extra["http"] = http
        event["extra"] = extra
        return event
    }

    static func report(_ nuggets: Nuggets, method: String, url: URL, status: Int?, error: NSError?, durationMs: Int, now: Double = Date().timeIntervalSince1970 * 1000) {
        guard enabled, nuggets.options.httpFailures, failed(status: status, error: error) else { return }
        let key = "\(method) \(url.host ?? "")\(url.path)"
        guard let folded = gate.pass(key, now: now, intervalMs: intervalMs) else { return }
        nuggets.send(event(nuggets, method: method, url: url, status: status, error: error, durationMs: durationMs, folded: folded))
    }
}
