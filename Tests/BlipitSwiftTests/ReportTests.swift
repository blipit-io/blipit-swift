import XCTest
import Sentry
@testable import BlipitSwift
#if os(iOS)
import UIKit
#endif

final class StubProtocol: URLProtocol {
    static var log: [(method: String, path: String, headers: [String: String], body: Data)] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        let path = request.url!.path + (request.url!.query.map { "?" + $0 } ?? "")
        StubProtocol.lock.lock()
        StubProtocol.log.append((request.httpMethod ?? "GET", path, request.allHTTPHeaderFields ?? [:], body))
        StubProtocol.lock.unlock()
        var json = "{}"
        var status = 201
        if path == "/api/v1/feedback" { json = #"{"id":42,"ref":"BR-7","upload_token":"tok"}"# }
        if path == "/api/v1/feedback/settings" { json = #"{"recording":true,"recording_max_ms":90000}"#; status = 200 }
        if path.hasSuffix("/recording/start") { json = #"{"url":"https://in.example/api/v1/feedback/42/recording/0","headers":{"Content-Type":"video/mp4","X-Blipit-Upload":"tok"}}"# }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        log = []
        return URLSession(configuration: config)
    }
}

final class ReportTests: XCTestCase {
    func testAnnotationsAreNormalisedLikeTheBrowserReporter() {
        let size = CGSize(width: 200, height: 100)
        let shapes = [
            ReportShape(tool: .arrow, points: [CGPoint(x: 20, y: 10), CGPoint(x: 120, y: 60)]),
            ReportShape(tool: .pen, points: [CGPoint(x: 50, y: 50), CGPoint(x: 100, y: 25), CGPoint(x: 150, y: 75)]),
        ]
        let list = ReportPayload.annotations(shapes, size: size)
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0]["tool"] as? String, "arrow")
        XCTAssertEqual(list[0]["x"] as? Double, 0.1)
        XCTAssertEqual(list[0]["w"] as? Double, 0.5)
        XCTAssertEqual(list[0]["h"] as? Double, 0.5)
        XCTAssertEqual(list[1]["x"] as? Double, 0.25)
        XCTAssertEqual(list[1]["y"] as? Double, 0.25)
        XCTAssertEqual(list[1]["points"] as? [Double], [0.25, 0.5, 0.5, 0.25, 0.75, 0.75])
        XCTAssertTrue(ReportPayload.annotations(shapes, size: .zero).isEmpty)
    }

    func testFeedbackBodyMatchesTheIngestContract() {
        let body = ReportPayload.feedback(title: "  ", message: "Checkout froze", email: " ana@example.com ", context: ["platform": "ios"], shapes: [ReportShape(tool: .rect, points: [.zero, CGPoint(x: 10, y: 10)])], imageSize: CGSize(width: 100, height: 100), screenshots: 1, recordings: 0, locale: "en")
        XCTAssertNil(body["title"])
        XCTAssertEqual(body["message"] as? String, "Checkout froze")
        XCTAssertEqual(body["email"] as? String, "ana@example.com")
        XCTAssertEqual(body["source"] as? String, "widget")
        XCTAssertEqual((body["attachments"] as? [String: Int])?["screenshots"], 1)
        XCTAssertEqual(((body["annotations"] as? [[String: Any]])?.first?["position"]) as? Int, 0)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(body))
    }

    func testStringsCoverElevenLanguages() {
        XCTAssertEqual(ReportStrings.table.count, 11)
        let keys = Set(ReportStrings.table["en"]!.keys)
        for (lang, strings) in ReportStrings.table {
            XCTAssertEqual(Set(strings.keys), keys, lang)
        }
        XCTAssertEqual(ReportLanguage.pick(["ar-AE", "en"]), "ar")
        XCTAssertEqual(ReportLanguage.pick(["xx"]), "en")
        XCTAssertNotEqual(ReportLanguage.text("send", "ja"), ReportLanguage.text("send", "en"))
    }

    func testClientSendsTheReportThenUploadsScreenshotAndRecording() throws {
        let client = ReportClient(endpoint: "https://in.example/", key: "blipit_pk_abc", session: StubProtocol.session())
        let sent = expectation(description: "sent")
        var receipt: ReportReceipt?
        client.send(["message": "x"]) { result in
            receipt = try? result.get()
            sent.fulfill()
        }
        wait(for: [sent], timeout: 5)
        XCTAssertEqual(receipt?.id, "42")
        XCTAssertEqual(receipt?.ref, "BR-7")

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("blipit-test.mp4")
        try Data(repeating: 1, count: 2048).write(to: file)
        let uploaded = expectation(description: "uploaded")
        uploaded.expectedFulfillmentCount = 2
        client.uploadScreenshot(receipt!, data: Data([0xFF, 0xD8, 0xFF]), type: "image/jpeg") { result in
            if case .failure = result { XCTFail("upload failed") }
            uploaded.fulfill()
        }
        client.uploadRecording(receipt!, file: file, durationMs: 4200) { result in
            if case .failure = result { XCTFail("upload failed") }
            uploaded.fulfill()
        }
        wait(for: [uploaded], timeout: 5)

        let paths = StubProtocol.log.map { "\($0.method) \($0.path)" }
        XCTAssertTrue(paths.contains("POST /api/v1/feedback"))
        XCTAssertTrue(paths.contains("POST /api/v1/feedback/42/screenshot?position=0"))
        XCTAssertTrue(paths.contains("POST /api/v1/feedback/42/recording/start"))
        XCTAssertTrue(paths.contains("PUT /api/v1/feedback/42/recording/0"))
        XCTAssertTrue(paths.contains("POST /api/v1/feedback/42/recording/complete?position=0"))
        let shot = StubProtocol.log.first { $0.path.contains("/screenshot") }!
        XCTAssertEqual(shot.headers["X-Blipit-Key"], "blipit_pk_abc")
        XCTAssertEqual(shot.headers["X-Blipit-Upload"], "tok")
        XCTAssertEqual(shot.headers["Content-Type"], "image/jpeg")
        let start = StubProtocol.log.first { $0.path.hasSuffix("/recording/start") }!
        let json = try JSONSerialization.jsonObject(with: start.body) as? [String: Any]
        XCTAssertEqual(json?["content_type"] as? String, "video/mp4")
        XCTAssertEqual(json?["size"] as? Int, 2048)
        XCTAssertEqual(json?["duration_ms"] as? Int, 4200)
        XCTAssertEqual(StubProtocol.log.first { $0.method == "PUT" }?.body.count, 2048)
    }

    func testEventsCarryTheBlipitPackage() {
        let options = Options()
        XCTAssertTrue(Blipit.configure(options, key: "blipit_pk_abc", project: "7"))
        let event = Event(level: .error)
        event.sdk = ["name": "sentry.cocoa", "packages": [["name": "spm:getsentry/sentry-cocoa", "version": "8.0.0"]]]
        let out = options.beforeSend?(event)
        let packages = out?.sdk?["packages"] as? [[String: Any]]
        XCTAssertEqual(packages?.count, 2)
        XCTAssertEqual(packages?.last?["name"] as? String, "swiftpm:blipit-swift")
        XCTAssertEqual(packages?.last?["version"] as? String, Blipit.version)
        _ = options.beforeSend?(out!)
        XCTAssertEqual((out?.sdk?["packages"] as? [[String: Any]])?.count, 2)
        XCTAssertNotNil(Blipit.reporter)
    }

    #if os(iOS)
    @available(iOS 15.0, *)
    @MainActor
    func testEditorMarksLandOnTheImageAtAnyZoomAndAreFlattened() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 800), format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 800))
        }
        let flow = ReportFlow(client: ReportClient(endpoint: "https://in.example", key: "k", session: StubProtocol.session()))
        flow.image = image
        let editor = ReportEditorController(flow: flow, image: image)
        editor.loadViewIfNeeded()
        editor.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        editor.view.layoutIfNeeded()
        XCTAssertGreaterThan(editor.canvas.bounds.width, 0)
        XCTAssertLessThanOrEqual(editor.scroll.frame.maxY, editor.view.bounds.height - 60, "toolbar sits below the image")

        let mid = CGPoint(x: editor.canvas.bounds.midX, y: editor.canvas.bounds.midY)
        XCTAssertEqual(editor.canvas.toPixels(mid).x, 200, accuracy: 1)
        XCTAssertEqual(editor.canvas.toPixels(mid).y, 400, accuracy: 1)

        editor.scroll.setZoomScale(3, animated: false)
        editor.view.layoutIfNeeded()
        XCTAssertEqual(editor.canvas.toPixels(mid).x, 200, accuracy: 1, "canvas coordinates do not change with zoom")

        editor.canvas.begin(.rect, at: CGPoint(x: 100, y: 100))
        editor.canvas.move(to: CGPoint(x: 300, y: 300))
        editor.canvas.end()
        editor.canvas.begin(.pen, at: CGPoint(x: 10, y: 700))
        editor.canvas.move(to: CGPoint(x: 50, y: 720))
        editor.canvas.end()
        XCTAssertEqual(editor.canvas.shapes.count, 2)
        editor.canvas.undo()
        XCTAssertEqual(editor.canvas.shapes.count, 1)

        flow.shapes = editor.canvas.shapes
        let flat = try XCTUnwrap(flow.flattened()?.cgImage)
        XCTAssertEqual(flat.width, 400)
        let pixel = Self.pixel(flat, x: 100, y: 200)
        XCTAssertGreaterThan(pixel.r, 200)
        XCTAssertLessThan(pixel.g, 120)
        let blank = Self.pixel(flat, x: 200, y: 200)
        XCTAssertGreaterThan(blank.g, 240)
    }

    @available(iOS 15.0, *)
    @MainActor
    func testDetailsSendsTheFlattenedScreenshot() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 200), format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 200))
        }
        let flow = ReportFlow(client: ReportClient(endpoint: "https://in.example", key: "k", session: StubProtocol.session()))
        flow.image = image
        flow.shapes = [ReportShape(tool: .arrow, points: [CGPoint(x: 10, y: 10), CGPoint(x: 90, y: 190)])]
        let details = ReportDetailsController(flow: flow, notice: nil)
        details.loadViewIfNeeded()
        details.submit()
        XCTAssertEqual(details.status.text, ReportLanguage.text("required", flow.lang))
        details.message.text = "Totals are wrong"
        details.titleField.text = "Cart"
        details.submit()
        let done = expectation(description: "uploaded")
        DispatchQueue.global().async {
            for _ in 0..<50 where !StubProtocol.log.contains(where: { $0.path.contains("/screenshot") }) { Thread.sleep(forTimeInterval: 0.1) }
            done.fulfill()
        }
        wait(for: [done], timeout: 6)
        let post = try XCTUnwrap(StubProtocol.log.first { $0.path == "/api/v1/feedback" })
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: post.body) as? [String: Any])
        XCTAssertEqual(json["title"] as? String, "Cart")
        XCTAssertEqual(json["message"] as? String, "Totals are wrong")
        XCTAssertEqual((json["context"] as? [String: Any])?["platform"] as? String, "ios")
        XCTAssertNotNil(json["annotations"])
        let shot = try XCTUnwrap(StubProtocol.log.first { $0.path.contains("/screenshot") })
        XCTAssertEqual(shot.headers["Content-Type"], "image/jpeg")
        XCTAssertNotNil(UIImage(data: shot.body))
    }

    @available(iOS 15.0, *)
    @MainActor
    func testScreensRenderInsideTheSafeArea() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 390, height: 844)).image { ctx in
            UIColor(red: 0.95, green: 0.96, blue: 0.98, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 390, height: 844))
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 390, height: 110))
            ("Checkout" as NSString).draw(at: CGPoint(x: 20, y: 60), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 28), .foregroundColor: UIColor.white])
            UIColor.white.setFill()
            for i in 0..<5 { ctx.fill(CGRect(x: 16, y: 140 + i * 110, width: 358, height: 92)) }
        }
        let flow = ReportFlow(client: ReportClient(endpoint: "https://in.example", key: "k", session: StubProtocol.session()))
        flow.recordingAllowed = true
        flow.image = image
        flow.shapes = [ReportShape(tool: .rect, points: [CGPoint(x: 60, y: 300), CGPoint(x: 700, y: 520)]), ReportShape(tool: .arrow, points: [CGPoint(x: 500, y: 900), CGPoint(x: 380, y: 560)])]
        let screens: [(String, UIViewController)] = [
            ("choice", ReportChoiceController(flow: flow)),
            ("editor", ReportEditorController(flow: flow, image: image)),
            ("details", ReportDetailsController(flow: flow, notice: nil)),
        ]
        let dir = ProcessInfo.processInfo.environment["BLIPIT_SCREENS"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory.appendingPathComponent("blipit-screens")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, controller) in screens {
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = controller
            window.isHidden = false
            window.layoutIfNeeded()
            let shot = UIGraphicsImageRenderer(bounds: window.bounds).image { ctx in window.layer.render(in: ctx.cgContext) }
            let data = try XCTUnwrap(shot.pngData())
            try data.write(to: dir.appendingPathComponent("\(name).png"))
            XCTAssertGreaterThan(data.count, 4000, name)
            window.isHidden = true
        }
        print("BLIPIT_SCREENS \(dir.path)")
    }

    static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        var data = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }
    #endif
}
