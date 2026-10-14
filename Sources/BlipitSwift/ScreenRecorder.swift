#if os(iOS)
import AVFoundation
import ReplayKit
import UIKit

@available(iOS 15.0, *)
final class ScreenRecorder {
    static let shared = ScreenRecorder()
    static var available: Bool { RPScreenRecorder.shared().isAvailable }

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var started: CMTime?
    private var last: CMTime?
    private var file: URL?
    private var done: ((Result<(file: URL, durationMs: Int), Error>) -> Void)?
    private var timer: Timer?
    private var pill: UIWindow?
    private let queue = DispatchQueue(label: "io.blipit.recorder")

    func start(maxMs: Int, label: String, stop: String, done: @escaping (Result<(file: URL, durationMs: Int), Error>) -> Void) {
        guard self.done == nil else { return }
        self.done = done
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("blipit-\(UUID().uuidString).mp4")
        self.file = file
        let recorder = RPScreenRecorder.shared()
        recorder.isMicrophoneEnabled = false
        recorder.startCapture(handler: { [weak self] buffer, type, error in
            guard let self, error == nil, type == .video, CMSampleBufferDataIsReady(buffer) else { return }
            self.queue.async { self.append(buffer) }
        }, completionHandler: { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.finish(.failure(error))
                    return
                }
                self.showPill(label: label, stop: stop)
                self.timer = Timer.scheduledTimer(withTimeInterval: Double(maxMs) / 1000, repeats: false) { [weak self] _ in self?.stop() }
            }
        })
    }

    private func append(_ buffer: CMSampleBuffer) {
        let time = CMSampleBufferGetPresentationTimeStamp(buffer)
        if writer == nil {
            guard let file, let format = CMSampleBufferGetFormatDescription(buffer) else { return }
            let size = CMVideoFormatDescriptionGetDimensions(format)
            let scale = min(1, 1280 / Double(max(size.width, size.height)))
            let width = Int(Double(size.width) * scale) / 2 * 2
            let height = Int(Double(size.height) * scale) / 2 * 2
            guard let writer = try? AVAssetWriter(outputURL: file, fileType: .mp4) else { return }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000],
            ])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { return }
            writer.add(input)
            writer.startWriting()
            writer.startSession(atSourceTime: time)
            self.writer = writer
            self.input = input
            started = time
        }
        if input?.isReadyForMoreMediaData == true, input?.append(buffer) == true {
            last = time
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        RPScreenRecorder.shared().stopCapture { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard let writer = self.writer, let input = self.input, let file = self.file, let started = self.started else {
                    DispatchQueue.main.async { self.finish(.failure(NSError(domain: "io.blipit.recorder", code: 1))) }
                    return
                }
                let ms = Int(CMTimeGetSeconds(CMTimeSubtract(self.last ?? started, started)) * 1000)
                input.markAsFinished()
                writer.finishWriting {
                    DispatchQueue.main.async {
                        if writer.status == .completed {
                            self.finish(.success((file, max(1, ms))))
                        } else {
                            self.finish(.failure(writer.error ?? NSError(domain: "io.blipit.recorder", code: 2)))
                        }
                    }
                }
            }
        }
    }

    private func finish(_ result: Result<(file: URL, durationMs: Int), Error>) {
        pill?.isHidden = true
        pill = nil
        writer = nil
        input = nil
        started = nil
        last = nil
        let callback = done
        done = nil
        callback?(result)
    }

    private func showPill(label: String, stop: String) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let window = PillWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        window.rootViewController = controller
        let dot = UIView()
        dot.backgroundColor = UIColor(red: 1, green: 59 / 255, blue: 48 / 255, alpha: 1)
        dot.layer.cornerRadius = 5
        dot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 10).isActive = true
        let text = UILabel()
        text.text = label
        text.textColor = .white
        text.font = .systemFont(ofSize: 14, weight: .semibold)
        var config = UIButton.Configuration.filled()
        config.title = stop
        config.image = UIImage(systemName: "stop.fill")
        config.imagePadding = 6
        config.baseBackgroundColor = UIColor(red: 1, green: 59 / 255, blue: 48 / 255, alpha: 1)
        config.cornerStyle = .capsule
        let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.stop() })
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        let row = UIStackView(arrangedSubviews: [dot, text, button])
        row.alignment = .center
        row.spacing = 10
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 4)
        row.backgroundColor = UIColor(red: 11 / 255, green: 26 / 255, blue: 58 / 255, alpha: 0.92)
        row.layer.cornerRadius = 26
        row.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(row)
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor),
            row.bottomAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])
        window.frame = scene.coordinateSpace.bounds
        window.isHidden = false
        pill = window
    }
}

@available(iOS 15.0, *)
final class PillWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self || hit === rootViewController?.view ? nil : hit
    }
}
#endif
