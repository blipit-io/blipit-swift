import Foundation
import CoreGraphics

public struct ReportShape: Equatable {
    public enum Tool: String { case pen, rect, arrow }
    public var tool: Tool
    public var color: String
    public var points: [CGPoint]

    public init(tool: Tool, color: String = "#FF3B30", points: [CGPoint]) {
        self.tool = tool
        self.color = color
        self.points = points
    }
}

public struct ReportReceipt {
    public let id: String
    public let token: String
    public let ref: String?
}

public enum ReportError: Error, Equatable {
    case http(Int)
    case invalidResponse
}

enum ReportLanguage {
    static func pick(_ preferred: [String] = Locale.preferredLanguages) -> String {
        for tag in preferred {
            let base = String(tag.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
            if ReportStrings.table[base] != nil { return base }
        }
        return "en"
    }

    static func text(_ key: String, _ lang: String = pick()) -> String {
        ReportStrings.table[lang]?[key] ?? ReportStrings.table["en"]?[key] ?? key
    }
}

public enum ReportPayload {
    static func round(_ v: CGFloat) -> Double { (Double(v) * 10_000).rounded() / 10_000 }

    public static func annotations(_ shapes: [ReportShape], size: CGSize) -> [[String: Any]] {
        guard size.width > 0, size.height > 0 else { return [] }
        return shapes.compactMap { shape in
            guard let first = shape.points.first, let last = shape.points.last else { return nil }
            var out: [String: Any] = ["tool": shape.tool.rawValue, "color": shape.color]
            if shape.tool == .pen {
                let xs = shape.points.map(\.x), ys = shape.points.map(\.y)
                let minX = xs.min()!, minY = ys.min()!
                out["x"] = round(minX / size.width)
                out["y"] = round(minY / size.height)
                out["w"] = round((xs.max()! - minX) / size.width)
                out["h"] = round((ys.max()! - minY) / size.height)
                out["points"] = shape.points.flatMap { [round($0.x / size.width), round($0.y / size.height)] }
            } else {
                out["x"] = round(first.x / size.width)
                out["y"] = round(first.y / size.height)
                out["w"] = round((last.x - first.x) / size.width)
                out["h"] = round((last.y - first.y) / size.height)
            }
            return out
        }
    }

    public static func feedback(title: String, message: String, email: String?, context: [String: Any], shapes: [ReportShape], imageSize: CGSize?, screenshots: Int, recordings: Int, locale: String, eventId: String? = nil) -> [String: Any] {
        var body: [String: Any] = [
            "message": message,
            "kind": "bug",
            "source": "widget",
            "locale": locale,
            "context": context,
            "attachments": ["screenshots": screenshots, "recordings": recordings],
        ]
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { body["title"] = title }
        if let email = email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty { body["email"] = email }
        if let eventId = eventId.flatMap(ReportSettings.crashId) { body["event_id"] = eventId }
        if let size = imageSize {
            let list = annotations(shapes, size: size)
            if !list.isEmpty { body["annotations"] = [["position": 0, "shapes": list]] }
        }
        return body
    }
}

public final class ReportClient {
    public let endpoint: String
    public let key: String
    let session: URLSession

    public init(endpoint: String, key: String, session: URLSession = .shared) {
        self.endpoint = endpoint.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        self.key = key
        self.session = session
    }

    func url(_ path: String) -> URL { URL(string: endpoint + path)! }

    func run(_ request: URLRequest, _ done: @escaping (Result<Data, Error>) -> Void) {
        if PlatformMismatch.blocked { return done(.failure(ReportError.http(409))) }
        var request = request
        request.setValue(key, forHTTPHeaderField: "X-Blipit-Key")
        session.dataTask(with: request) { data, response, error in
            if let error { return done(.failure(error)) }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                PlatformMismatch.check(status, data)
                return done(.failure(ReportError.http(status)))
            }
            done(.success(data ?? Data()))
        }.resume()
    }

    public func settings(_ done: @escaping (_ recording: Bool, _ maxMs: Int) -> Void) {
        run(URLRequest(url: url("/api/v1/feedback/settings"))) { result in
            guard case let .success(data) = result, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return done(false, 60_000) }
            done(json["recording"] as? Bool ?? false, json["recording_max_ms"] as? Int ?? 60_000)
        }
    }

    public func buttonSettings(userId: String?, email: String?, _ done: @escaping (Bool) -> Void) {
        var request = URLRequest(url: url("/api/v1/feedback/settings"))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let userId, !userId.isEmpty { request.setValue(userId, forHTTPHeaderField: "X-Blipit-User-Id") }
        if let email, !email.isEmpty { request.setValue(email, forHTTPHeaderField: "X-Blipit-User-Email") }
        run(request) { result in
            guard case let .success(data) = result else { return done(false) }
            done(ReportSettings.button(try? JSONSerialization.jsonObject(with: data)))
        }
    }

    public func stuckSettings(_ done: @escaping (StuckLimits?) -> Void) {
        run(URLRequest(url: url("/api/v1/feedback/settings"))) { result in
            guard case let .success(data) = result, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return done(nil) }
            done(StuckLimits.from(json["stuck"]))
        }
    }

    public func event(_ body: [String: Any], _ done: @escaping (Bool) -> Void) {
        var request = URLRequest(url: url("/api/v1/events"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        run(request) { result in
            switch result {
            case .success: done(true)
            case let .failure(ReportError.http(status)): done((400..<500).contains(status) && status != 408 && status != 429)
            case .failure: done(false)
            }
        }
    }

    public func send(_ body: [String: Any], _ done: @escaping (Result<ReportReceipt, Error>) -> Void) {
        var request = URLRequest(url: url("/api/v1/feedback"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        run(request) { result in
            switch result {
            case let .failure(error): done(.failure(error))
            case let .success(data):
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let token = json["upload_token"] as? String else { return done(.failure(ReportError.invalidResponse)) }
                let id = (json["id"] as? NSNumber)?.stringValue ?? (json["id"] as? String) ?? ""
                done(.success(ReportReceipt(id: id, token: token, ref: json["ref"] as? String)))
            }
        }
    }

    public func uploadScreenshot(_ receipt: ReportReceipt, data: Data, type: String, _ done: @escaping (Result<Void, Error>) -> Void) {
        var request = URLRequest(url: url("/api/v1/feedback/\(receipt.id)/screenshot?position=0"))
        request.httpMethod = "POST"
        request.setValue(type, forHTTPHeaderField: "Content-Type")
        request.setValue(receipt.token, forHTTPHeaderField: "X-Blipit-Upload")
        request.httpBody = data
        run(request) { done($0.map { _ in () }) }
    }

    public func uploadRecording(_ receipt: ReportReceipt, file: URL, durationMs: Int, _ done: @escaping (Result<Void, Error>) -> Void) {
        guard let data = try? Data(contentsOf: file) else { return done(.failure(ReportError.invalidResponse)) }
        var start = URLRequest(url: url("/api/v1/feedback/\(receipt.id)/recording/start"))
        start.httpMethod = "POST"
        start.setValue("application/json", forHTTPHeaderField: "Content-Type")
        start.setValue(receipt.token, forHTTPHeaderField: "X-Blipit-Upload")
        start.httpBody = try? JSONSerialization.data(withJSONObject: ["content_type": "video/mp4", "size": data.count, "duration_ms": max(1, durationMs), "position": 0])
        run(start) { result in
            guard case let .success(body) = result,
                  let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let target = (json["url"] as? String).flatMap(URL.init(string:)) else {
                if case let .failure(error) = result { return done(.failure(error)) }
                return done(.failure(ReportError.invalidResponse))
            }
            var put = URLRequest(url: target)
            put.httpMethod = "PUT"
            for (name, value) in json["headers"] as? [String: String] ?? [:] { put.setValue(value, forHTTPHeaderField: name) }
            put.httpBody = data
            self.session.dataTask(with: put) { _, response, error in
                if let error { return done(.failure(error)) }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status) else { return done(.failure(ReportError.http(status))) }
                var complete = URLRequest(url: self.url("/api/v1/feedback/\(receipt.id)/recording/complete?position=0"))
                complete.httpMethod = "POST"
                complete.setValue("application/json", forHTTPHeaderField: "Content-Type")
                complete.setValue(receipt.token, forHTTPHeaderField: "X-Blipit-Upload")
                complete.httpBody = Data("{}".utf8)
                self.run(complete) { done($0.map { _ in () }) }
            }.resume()
        }
    }
}
