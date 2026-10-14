#if os(iOS)
import UIKit

@available(iOS 15.0, *)
enum ReportTheme {
    static let navy = UIColor(red: 11 / 255, green: 26 / 255, blue: 58 / 255, alpha: 1)
    static let card = UIColor(red: 26 / 255, green: 33 / 255, blue: 53 / 255, alpha: 1)
    static let brand = UIColor(red: 56 / 255, green: 130 / 255, blue: 246 / 255, alpha: 1)
    static let muted = UIColor(red: 152 / 255, green: 166 / 255, blue: 190 / 255, alpha: 1)
    static let mark = UIColor(red: 1, green: 59 / 255, blue: 48 / 255, alpha: 1)
    static let danger = UIColor(red: 1, green: 122 / 255, blue: 110 / 255, alpha: 1)
}

@available(iOS 15.0, *)
extension Blipit {
    static var reportButton: UIButton?

    public static func showReport() {
        guard let client = reporter else {
            print("[blipit] call Blipit.start before Blipit.showReport")
            return
        }
        DispatchQueue.main.async {
            ReportFlow(client: client).begin()
        }
    }

    public static func showReportButton() {
        DispatchQueue.main.async {
            guard reportButton == nil, let window = ReportFlow.keyWindow() else { return }
            let button = UIButton(type: .system)
            button.setTitle(" " + ReportLanguage.text("title"), for: .normal)
            button.setImage(UIImage(systemName: "exclamationmark.bubble.fill"), for: .normal)
            button.tintColor = .white
            button.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
            button.backgroundColor = ReportTheme.brand
            button.layer.cornerRadius = 22
            button.layer.shadowColor = UIColor.black.cgColor
            button.layer.shadowOpacity = 0.25
            button.layer.shadowRadius = 10
            button.layer.shadowOffset = CGSize(width: 0, height: 4)
            button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 18)
            button.accessibilityLabel = ReportLanguage.text("title")
            button.translatesAutoresizingMaskIntoConstraints = false
            button.addAction(UIAction { _ in showReport() }, for: .touchUpInside)
            window.addSubview(button)
            NSLayoutConstraint.activate([
                button.heightAnchor.constraint(equalToConstant: 44),
                button.trailingAnchor.constraint(equalTo: window.safeAreaLayoutGuide.trailingAnchor, constant: -16),
                button.bottomAnchor.constraint(equalTo: window.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            ])
            reportButton = button
        }
    }

    public static func hideReportButton() {
        DispatchQueue.main.async {
            reportButton?.removeFromSuperview()
            reportButton = nil
        }
    }
}

@available(iOS 15.0, *)
final class ReportFlow {
    let client: ReportClient
    let lang = ReportLanguage.pick()
    var image: UIImage?
    var shapes: [ReportShape] = []
    var video: (file: URL, durationMs: Int)?
    var recordingAllowed = false
    var recordingMaxMs = 60_000
    static var active: ReportFlow?

    init(client: ReportClient) {
        self.client = client
    }

    func t(_ key: String) -> String { ReportLanguage.text(key, lang) }

    static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }

    static func top(_ base: UIViewController? = keyWindow()?.rootViewController) -> UIViewController? {
        if let presented = base?.presentedViewController { return top(presented) }
        if let nav = base as? UINavigationController { return top(nav.visibleViewController) }
        if let tab = base as? UITabBarController { return top(tab.selectedViewController) }
        return base
    }

    func begin() {
        ReportFlow.active = self
        client.settings { recording, maxMs in
            DispatchQueue.main.async {
                self.recordingAllowed = recording && ScreenRecorder.available
                self.recordingMaxMs = maxMs
                self.present(ReportChoiceController(flow: self))
            }
        }
    }

    func present(_ controller: UIViewController) {
        controller.modalPresentationStyle = .fullScreen
        ReportFlow.top()?.present(controller, animated: true)
    }

    func capture(from controller: UIViewController) {
        controller.dismiss(animated: false) {
            Blipit.reportButton?.isHidden = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.image = ReportFlow.snapshot()
                Blipit.reportButton?.isHidden = false
                if let image = self.image {
                    self.present(ReportEditorController(flow: self, image: image))
                } else {
                    self.present(ReportDetailsController(flow: self, notice: self.t("noShot")))
                }
            }
        }
    }

    static func snapshot() -> UIImage? {
        guard let window = keyWindow() else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(window.screen.scale, 2)
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    func record(from controller: UIViewController) {
        controller.dismiss(animated: true) {
            ScreenRecorder.shared.start(maxMs: self.recordingMaxMs, label: self.t("recordTitle"), stop: self.t("stop")) { result in
                DispatchQueue.main.async {
                    switch result {
                    case let .success(take):
                        self.video = take
                        self.present(ReportDetailsController(flow: self, notice: nil))
                    case let .failure(error):
                        let denied = (error as NSError).domain == "com.apple.ReplayKit.RPRecordingErrorDomain" && (error as NSError).code == -5801
                        self.present(ReportDetailsController(flow: self, notice: self.t(denied ? "recDenied" : "recError")))
                    }
                }
            }
        }
    }

    func flattened() -> UIImage? {
        guard let image else { return nil }
        if shapes.isEmpty { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: format).image { ctx in
            image.draw(at: .zero)
            let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
            ctx.cgContext.scaleBy(x: image.size.width / pixels.width, y: image.size.height / pixels.height)
            for shape in shapes {
                ReportCanvas.path(shape, width: ReportCanvas.stroke(pixels)).stroke()
            }
        }
    }

    func finish() {
        ReportFlow.active = nil
    }
}

@available(iOS 15.0, *)
final class ReportChoiceController: UIViewController {
    let flow: ReportFlow

    init(flow: ReportFlow) {
        self.flow = flow
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ReportTheme.navy
        overrideUserInterfaceStyle = .dark
        let close = ReportUI.bar(flow.t("close"), image: "xmark") { [weak self] in
            self?.dismiss(animated: true) { self?.flow.finish() }
        }
        let title = ReportUI.label(flow.t("mHow"), size: 24, weight: .bold)
        title.numberOfLines = 0
        var cards = [
            ReportUI.card(flow.t("mShot"), sub: nil, image: "camera.viewfinder") { [weak self] in
                guard let self else { return }
                self.flow.capture(from: self)
            },
        ]
        if flow.recordingAllowed {
            cards.append(ReportUI.card(flow.t("mVideo"), sub: flow.t("mVideoSub"), image: "record.circle") { [weak self] in
                guard let self else { return }
                self.flow.record(from: self)
            })
        }
        cards.append(ReportUI.card(flow.t("mSkip"), sub: nil, image: "text.bubble") { [weak self] in
            guard let self else { return }
            self.dismiss(animated: false) { self.flow.present(ReportDetailsController(flow: self.flow, notice: nil)) }
        })
        let stack = UIStackView(arrangedSubviews: [title] + cards)
        stack.axis = .vertical
        stack.spacing = 14
        stack.setCustomSpacing(24, after: title)
        [close, stack].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            close.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            close.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -20),
            stack.centerYAnchor.constraint(equalTo: guide.centerYAnchor),
        ])
    }
}

@available(iOS 15.0, *)
final class ReportEditorController: UIViewController, UIScrollViewDelegate {
    let flow: ReportFlow
    let image: UIImage
    let scroll = UIScrollView()
    let content = UIView()
    let imageView: UIImageView
    let canvas: ReportCanvas
    let zoomLabel = UILabel()
    var tool: ReportShape.Tool = .pen
    var toolButtons: [ReportShape.Tool: UIButton] = [:]

    init(flow: ReportFlow, image: UIImage) {
        self.flow = flow
        self.image = image
        imageView = UIImageView(image: image)
        canvas = ReportCanvas(pixels: CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale))
        canvas.shapes = flow.shapes
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ReportTheme.navy
        overrideUserInterfaceStyle = .dark

        let back = ReportUI.bar(flow.t("mBack"), image: "chevron.backward") { [weak self] in
            guard let self else { return }
            self.flow.shapes = self.canvas.shapes
            self.dismiss(animated: true) { self.flow.present(ReportChoiceController(flow: self.flow)) }
        }
        let zoomOut = ReportUI.icon("minus.magnifyingglass", flow.t("mZoomOut")) { [weak self] in self?.zoom(by: 1 / 1.5) }
        let zoomIn = ReportUI.icon("plus.magnifyingglass", flow.t("mZoomIn")) { [weak self] in self?.zoom(by: 1.5) }
        zoomLabel.textColor = ReportTheme.muted
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        zoomLabel.textAlignment = .center
        zoomLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true
        let next = ReportUI.primary(flow.t("mNext")) { [weak self] in
            guard let self else { return }
            self.flow.shapes = self.canvas.shapes
            self.dismiss(animated: true) { self.flow.present(ReportDetailsController(flow: self.flow, notice: nil)) }
        }
        let top = UIStackView(arrangedSubviews: [back, UIView(), zoomOut, zoomLabel, zoomIn, UIView(), next])
        top.alignment = .center
        top.spacing = 4

        scroll.delegate = self
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 5
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.panGestureRecognizer.minimumNumberOfTouches = 2
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.backgroundColor = UIColor.black.withAlphaComponent(0.25)
        imageView.contentMode = .scaleToFill
        content.addSubview(imageView)
        content.addSubview(canvas)
        scroll.addSubview(content)

        let draw = UIPanGestureRecognizer(target: self, action: #selector(drawing(_:)))
        draw.maximumNumberOfTouches = 1
        canvas.addGestureRecognizer(draw)
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
        double.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(double)

        let tools = UIStackView(arrangedSubviews: [
            toolButton(.pen, flow.t("pen"), "scribble"),
            toolButton(.rect, flow.t("rect"), "rectangle"),
            toolButton(.arrow, flow.t("arrow"), "arrow.up.right"),
            ReportUI.tool(flow.t("undo"), "arrow.uturn.backward") { [weak self] in self?.canvas.undo() },
            ReportUI.tool(flow.t("mFit"), "arrow.down.right.and.arrow.up.left") { [weak self] in self?.scroll.setZoomScale(1, animated: true) },
        ])
        tools.distribution = .fillEqually
        selectTool(.pen)

        [top, scroll, tools].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: guide.topAnchor, constant: 6),
            top.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 8),
            top.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -10),
            top.heightAnchor.constraint(equalToConstant: 48),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: tools.topAnchor, constant: -6),
            tools.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 8),
            tools.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -8),
            tools.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -4),
            tools.heightAnchor.constraint(equalToConstant: 60),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard scroll.zoomScale == 1 else { return }
        let bounds = scroll.bounds.size
        guard bounds.width > 0, bounds.height > 0 else { return }
        let ratio = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        content.frame = CGRect(origin: .zero, size: size)
        imageView.frame = content.bounds
        canvas.frame = content.bounds
        scroll.contentSize = size
        center()
        zoomLabel.text = "100%"
    }

    func center() {
        let bounds = scroll.bounds.size
        let size = scroll.contentSize
        scroll.contentInset = UIEdgeInsets(top: max(0, (bounds.height - size.height) / 2), left: max(0, (bounds.width - size.width) / 2), bottom: 0, right: 0)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        center()
        zoomLabel.text = "\(Int((scrollView.zoomScale * 100).rounded()))%"
    }

    func zoom(by factor: CGFloat) {
        scroll.setZoomScale(min(scroll.maximumZoomScale, max(scroll.minimumZoomScale, scroll.zoomScale * factor)), animated: true)
    }

    @objc func doubleTap(_ gesture: UITapGestureRecognizer) {
        if scroll.zoomScale > 1.01 {
            scroll.setZoomScale(1, animated: true)
            return
        }
        let point = gesture.location(in: content)
        let scale: CGFloat = 2.5
        let size = CGSize(width: scroll.bounds.width / scale, height: scroll.bounds.height / scale)
        scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
    }

    @objc func drawing(_ gesture: UIPanGestureRecognizer) {
        let point = canvas.toPixels(gesture.location(in: canvas))
        switch gesture.state {
        case .began:
            canvas.begin(tool, at: point)
        case .changed:
            canvas.move(to: point)
        case .ended:
            canvas.end()
        default:
            canvas.cancel()
        }
    }

    func toolButton(_ tool: ReportShape.Tool, _ title: String, _ image: String) -> UIButton {
        let button = ReportUI.tool(title, image) { [weak self] in self?.selectTool(tool) }
        toolButtons[tool] = button
        return button
    }

    func selectTool(_ tool: ReportShape.Tool) {
        self.tool = tool
        for (key, button) in toolButtons {
            let on = key == tool
            button.tintColor = on ? .white : ReportTheme.muted
            button.setTitleColor(on ? .white : ReportTheme.muted, for: .normal)
            button.backgroundColor = on ? ReportTheme.brand : .clear
            button.accessibilityTraits = on ? [.button, .selected] : .button
        }
    }
}

@available(iOS 15.0, *)
final class ReportCanvas: UIView {
    let pixels: CGSize
    var shapes: [ReportShape] = [] { didSet { setNeedsDisplay() } }
    var current: ReportShape?

    init(pixels: CGSize) {
        self.pixels = pixels
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { nil }

    func toPixels(_ point: CGPoint) -> CGPoint {
        guard bounds.width > 0, bounds.height > 0 else { return point }
        return CGPoint(x: min(max(point.x, 0), bounds.width) * pixels.width / bounds.width, y: min(max(point.y, 0), bounds.height) * pixels.height / bounds.height)
    }

    func begin(_ tool: ReportShape.Tool, at point: CGPoint) {
        current = ReportShape(tool: tool, points: [point, point])
        setNeedsDisplay()
    }

    func move(to point: CGPoint) {
        guard var shape = current else { return }
        if shape.tool == .pen { shape.points.append(point) } else { shape.points[1] = point }
        current = shape
        setNeedsDisplay()
    }

    func end() {
        if let shape = current, shape.points.count > 1, shape.points.first != shape.points.last || shape.tool == .pen {
            shapes.append(shape)
        }
        current = nil
        setNeedsDisplay()
    }

    func cancel() {
        current = nil
        setNeedsDisplay()
    }

    func undo() {
        if !shapes.isEmpty { shapes.removeLast() }
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), pixels.width > 0 else { return }
        ctx.scaleBy(x: bounds.width / pixels.width, y: bounds.height / pixels.height)
        let width = ReportCanvas.stroke(pixels)
        for shape in shapes + (current.map { [$0] } ?? []) {
            ReportCanvas.path(shape, width: width).stroke()
        }
    }

    static func stroke(_ pixels: CGSize) -> CGFloat { max(4, pixels.width / 130) }

    static func path(_ shape: ReportShape, width: CGFloat) -> UIBezierPath {
        ReportTheme.mark.setStroke()
        let path = UIBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        guard let first = shape.points.first, let last = shape.points.last else { return path }
        switch shape.tool {
        case .pen:
            path.move(to: first)
            shape.points.dropFirst().forEach { path.addLine(to: $0) }
        case .rect:
            path.append(UIBezierPath(rect: CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y))))
        case .arrow:
            path.move(to: first)
            path.addLine(to: last)
            let angle = atan2(last.y - first.y, last.x - first.x)
            let head = width * 5
            for side in [CGFloat.pi * 0.8, -CGFloat.pi * 0.8] {
                path.move(to: last)
                path.addLine(to: CGPoint(x: last.x + head * cos(angle + side), y: last.y + head * sin(angle + side)))
            }
        }
        return path
    }
}

@available(iOS 15.0, *)
final class ReportDetailsController: UIViewController {
    let flow: ReportFlow
    let notice: String?
    let titleField = UITextField()
    let message = UITextView()
    let placeholder = UILabel()
    let email = UITextField()
    let status = UILabel()
    var send: UIButton!
    let spinner = UIActivityIndicatorView(style: .medium)
    var busy = false

    init(flow: ReportFlow, notice: String?) {
        self.flow = flow
        self.notice = notice
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ReportTheme.navy
        overrideUserInterfaceStyle = .dark

        let back = ReportUI.bar(flow.t("mBack"), image: "chevron.backward") { [weak self] in
            guard let self, !self.busy else { return }
            self.dismiss(animated: true) {
                if let image = self.flow.image {
                    self.flow.present(ReportEditorController(flow: self.flow, image: image))
                } else {
                    self.flow.present(ReportChoiceController(flow: self.flow))
                }
            }
        }
        send = ReportUI.primary(flow.t("send")) { [weak self] in self?.submit() }
        spinner.color = .white
        let top = UIStackView(arrangedSubviews: [back, UIView(), spinner, send])
        top.alignment = .center
        top.spacing = 8

        let heading = ReportUI.label(flow.t("title"), size: 22, weight: .bold)
        var rows: [UIView] = [heading]
        if let preview = flow.flattened() {
            let thumb = UIImageView(image: preview)
            thumb.contentMode = .scaleAspectFit
            thumb.layer.cornerRadius = 10
            thumb.clipsToBounds = true
            thumb.backgroundColor = ReportTheme.card
            thumb.heightAnchor.constraint(equalToConstant: 140).isActive = true
            rows.append(thumb)
        } else if let video = flow.video {
            let line = ReportUI.label("▶︎  " + flow.t("recordTitle") + "  ·  " + String(format: "%d:%02d", video.durationMs / 60_000, video.durationMs / 1000 % 60), size: 15, weight: .medium)
            rows.append(line)
        }
        if let notice {
            let line = ReportUI.label(notice, size: 14, weight: .regular)
            line.textColor = ReportTheme.danger
            line.numberOfLines = 0
            rows.append(line)
        }
        ReportUI.field(titleField, flow.t("fTitle"))
        ReportUI.field(email, flow.t("email"))
        email.keyboardType = .emailAddress
        email.autocapitalizationType = .none
        email.autocorrectionType = .no
        email.textContentType = .emailAddress
        message.font = .systemFont(ofSize: 16)
        message.textColor = .white
        message.backgroundColor = ReportTheme.card
        message.layer.cornerRadius = 12
        message.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        message.heightAnchor.constraint(equalToConstant: 130).isActive = true
        message.accessibilityLabel = flow.t("fDesc")
        placeholder.text = flow.t("fDesc")
        placeholder.textColor = ReportTheme.muted
        placeholder.font = .systemFont(ofSize: 16)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        message.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.topAnchor.constraint(equalTo: message.topAnchor, constant: 12),
            placeholder.leadingAnchor.constraint(equalTo: message.leadingAnchor, constant: 15),
        ])
        NotificationCenter.default.addObserver(forName: UITextView.textDidChangeNotification, object: message, queue: .main) { [weak self] _ in
            self?.placeholder.isHidden = !(self?.message.text.isEmpty ?? true)
        }
        status.numberOfLines = 0
        status.font = .systemFont(ofSize: 14)
        status.textColor = ReportTheme.muted
        rows += [titleField, message, email, status]

        let stack = UIStackView(arrangedSubviews: rows)
        stack.axis = .vertical
        stack.spacing = 12
        let scroll = UIScrollView()
        scroll.keyboardDismissMode = .interactive
        scroll.alwaysBounceVertical = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        [top, scroll].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: guide.topAnchor, constant: 6),
            top.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 8),
            top.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -10),
            top.heightAnchor.constraint(equalToConstant: 48),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
        ])
    }

    func show(_ text: String, error: Bool) {
        status.text = text
        status.textColor = error ? ReportTheme.danger : ReportTheme.muted
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    func setBusy(_ on: Bool, _ label: String? = nil) {
        busy = on
        send.isEnabled = !on
        send.alpha = on ? 0.6 : 1
        on ? spinner.startAnimating() : spinner.stopAnimating()
        if let label { show(label, error: false) }
    }

    func submit() {
        guard !busy else { return }
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            show(flow.t("required"), error: true)
            message.becomeFirstResponder()
            return
        }
        view.endEditing(true)
        let image = flow.flattened()
        let data = image?.jpegData(compressionQuality: 0.85)
        let body = ReportPayload.feedback(
            title: titleField.text ?? "",
            message: text,
            email: email.text,
            context: ReportDevice.context(),
            shapes: flow.shapes,
            imageSize: flow.image.map { CGSize(width: $0.size.width * $0.scale, height: $0.size.height * $0.scale) },
            screenshots: data == nil ? 0 : 1,
            recordings: flow.video == nil ? 0 : 1,
            locale: flow.lang
        )
        setBusy(true, flow.t("sending"))
        flow.client.send(body) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                DispatchQueue.main.async {
                    self.setBusy(false)
                    self.show(self.flow.t("error"), error: true)
                }
            case let .success(receipt):
                self.attach(receipt, data: data)
            }
        }
    }

    func attach(_ receipt: ReportReceipt, data: Data?) {
        let group = DispatchGroup()
        var failed = false
        if let data {
            group.enter()
            flow.client.uploadScreenshot(receipt, data: data, type: "image/jpeg") { result in
                if case .failure = result { failed = true }
                group.leave()
            }
        }
        if let video = flow.video {
            DispatchQueue.main.async { self.show(self.flow.t("uploadingVideo"), error: false) }
            group.enter()
            flow.client.uploadRecording(receipt, file: video.file, durationMs: video.durationMs) { result in
                if case .failure = result { failed = true }
                try? FileManager.default.removeItem(at: video.file)
                group.leave()
            }
        }
        group.notify(queue: .main) {
            self.setBusy(false)
            let done = receipt.ref.map { self.flow.t("sentRef").replacingOccurrences(of: "{ref}", with: $0) } ?? self.flow.t("sentTitle")
            self.show(failed ? done + " · " + self.flow.t("recError") : done, error: failed)
            self.send.isHidden = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                self.dismiss(animated: true) { self.flow.finish() }
            }
        }
    }
}

@available(iOS 15.0, *)
enum ReportDevice {
    static func context() -> [String: Any] {
        let device = UIDevice.current
        let screen = UIScreen.main
        let info = Bundle.main.infoDictionary ?? [:]
        var app: [String: Any] = [:]
        if let id = Bundle.main.bundleIdentifier { app["id"] = id }
        if let version = info["CFBundleShortVersionString"] { app["version"] = version }
        if let build = info["CFBundleVersion"] { app["build"] = build }
        return [
            "platform": "ios",
            "sdk": ["name": Blipit.packageName, "version": Blipit.version],
            "app": app,
            "device": [
                "os": device.systemName,
                "os_version": device.systemVersion,
                "model": device.model,
                "screen": "\(Int(screen.bounds.width))x\(Int(screen.bounds.height))",
                "dpr": Double(screen.scale),
                "language": Locale.preferredLanguages.first ?? "",
                "timezone": TimeZone.current.identifier,
                "touch": true,
            ],
        ]
    }
}

@available(iOS 15.0, *)
enum ReportUI {
    static func label(_ text: String, size: CGFloat, weight: UIFont.Weight) -> UILabel {
        let label = UILabel()
        label.text = text
        label.textColor = .white
        label.font = .systemFont(ofSize: size, weight: weight)
        label.adjustsFontForContentSizeCategory = true
        return label
    }

    static func bar(_ title: String, image: String, _ action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: image, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)), for: .normal)
        button.setTitle(" " + title, for: .normal)
        button.tintColor = .white
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    static func icon(_ image: String, _ label: String, _ action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: image, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)), for: .normal)
        button.tintColor = .white
        button.accessibilityLabel = label
        button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    static func primary(_ title: String, _ action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        button.backgroundColor = ReportTheme.brand
        button.layer.cornerRadius = 12
        button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 18, bottom: 0, right: 18)
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    static func tool(_ title: String, _ image: String, _ action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        let symbol = UIImage(systemName: image, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium))
        button.setImage(symbol, for: .normal)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 11, weight: .medium)
        button.titleLabel?.lineBreakMode = .byTruncatingTail
        button.tintColor = ReportTheme.muted
        button.setTitleColor(ReportTheme.muted, for: .normal)
        button.layer.cornerRadius = 12
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 54).isActive = true
        let size = symbol?.size ?? .zero
        button.titleEdgeInsets = UIEdgeInsets(top: size.height + 8, left: -size.width, bottom: 0, right: 0)
        button.imageEdgeInsets = UIEdgeInsets(top: -16, left: 0, bottom: 0, right: 0)
        button.accessibilityLabel = title
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    static func card(_ title: String, sub: String?, image: String, _ action: @escaping () -> Void) -> UIControl {
        let control = UIControl()
        control.backgroundColor = ReportTheme.card
        control.layer.cornerRadius = 16
        control.layer.borderWidth = 1
        control.layer.borderColor = UIColor.white.withAlphaComponent(0.1).cgColor
        let icon = UIImageView(image: UIImage(systemName: image, withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)))
        icon.tintColor = ReportTheme.brand
        icon.contentMode = .center
        icon.widthAnchor.constraint(equalToConstant: 32).isActive = true
        let name = label(title, size: 17, weight: .semibold)
        name.numberOfLines = 0
        let texts = UIStackView(arrangedSubviews: [name])
        texts.axis = .vertical
        texts.spacing = 2
        if let sub {
            let line = label(sub, size: 13, weight: .regular)
            line.textColor = ReportTheme.muted
            line.numberOfLines = 0
            texts.addArrangedSubview(line)
        }
        let row = UIStackView(arrangedSubviews: [icon, texts])
        row.spacing = 14
        row.alignment = .center
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        control.addSubview(row)
        NSLayoutConstraint.activate([
            control.heightAnchor.constraint(greaterThanOrEqualToConstant: 64),
            row.topAnchor.constraint(equalTo: control.topAnchor, constant: 14),
            row.bottomAnchor.constraint(equalTo: control.bottomAnchor, constant: -14),
            row.leadingAnchor.constraint(equalTo: control.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: control.trailingAnchor, constant: -16),
        ])
        control.isAccessibilityElement = true
        control.accessibilityLabel = sub.map { "\(title), \($0)" } ?? title
        control.accessibilityTraits = .button
        control.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return control
    }

    static func field(_ field: UITextField, _ placeholder: String) {
        field.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [.foregroundColor: ReportTheme.muted])
        field.textColor = .white
        field.font = .systemFont(ofSize: 16)
        field.backgroundColor = ReportTheme.card
        field.layer.cornerRadius = 12
        field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 14, height: 1))
        field.leftViewMode = .always
        field.heightAnchor.constraint(equalToConstant: 48).isActive = true
        field.accessibilityLabel = placeholder
    }
}
#endif
