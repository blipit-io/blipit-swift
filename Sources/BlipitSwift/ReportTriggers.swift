#if os(iOS)
import ObjectiveC
import UIKit

@available(iOS 15.0, *)
enum ReportTriggers {
    static var options: Options?
    static var handler: ((String, String?) -> Void)?
    static var gate = TriggerGate()
    static var state = PromptState()
    static var banner: UIView?
    static var bannerCrash: String?
    static var shelf = ScreenShelf<UIImage>()
    static var serverButton = false
    static var checking = false
    static var checkAgain = false
    static var buttonCheck: DispatchWorkItem?
    static var snap: DispatchWorkItem?
    static var backgroundAt: Date?
    static var observers: [NSObjectProtocol] = []
    static var shakeInstalled = false
    static let watcher = TouchWatcher()

    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    static var busy: Bool { ReportFlow.active != nil || state.kind != nil }

    static func install(_ options: Options) {
        DispatchQueue.main.async {
            guard self.options == nil else { return }
            self.options = options
            let center = NotificationCenter.default
            func on(_ name: Notification.Name, _ run: @escaping (Notification) -> Void) {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main, using: run))
            }
            if options.shakeToReport { installShake() }
            if options.screenshotToReport {
                on(UIApplication.userDidTakeScreenshotNotification) { _ in prompt(.screenshot, crashId: nil) }
            }
            if options.twoFingerReport {
                on(UIWindow.didBecomeKeyNotification) { note in
                    if let window = note.object as? UIWindow { watch(window) }
                }
                if let window = ReportFlow.keyWindow() { watch(window) }
            }
            on(UIApplication.didEnterBackgroundNotification) { _ in backgroundAt = Date() }
            on(UIApplication.willEnterForegroundNotification) { _ in
                if let at = backgroundAt { shelf.foreground(after: Date().timeIntervalSince(at)) }
                backgroundAt = nil
            }
            if options.reportAfterCrash, let id = Blipit.lastCrashId {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { prompt(.crash, crashId: id) }
            }
            refreshButton(after: 0)
        }
    }

    static func userChanged() {
        DispatchQueue.main.async { refreshButton(after: 1) }
    }

    static func refreshButton(after delay: TimeInterval) {
        buttonCheck?.cancel()
        let item = DispatchWorkItem { checkButton() }
        buttonCheck = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    static func checkButton() {
        guard options != nil, let client = Blipit.reporter else { return }
        if checking {
            checkAgain = true
            return
        }
        checking = true
        let user = Blipit.reportUser
        client.buttonSettings(userId: user.id, email: user.email) { show in
            DispatchQueue.main.async {
                checking = false
                serverButton = show
                Blipit.updateButton()
                if checkAgain {
                    checkAgain = false
                    checkButton()
                }
            }
        }
    }

    static func fire(_ trigger: ReportTrigger, crashId: String? = nil) {
        guard gate.allow(now: now, busy: busy) else { return }
        if let handler {
            handler(trigger.rawValue, crashId)
        } else if let client = Blipit.reporter {
            ReportFlow(client: client, crashId: crashId).begin()
        }
    }

    static func screenAppeared(_ name: String) {
        DispatchQueue.main.async {
            snap?.cancel()
            let item = DispatchWorkItem {
                guard Screens.current == name, ReportFlow.active == nil, UIApplication.shared.applicationState == .active,
                      Nuggets.shared?.active == true, let image = thumbnail() else { return }
                shelf.add(name, image)
            }
            snap = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: item)
        }
    }

    static func thumbnail() -> UIImage? {
        guard let window = ReportFlow.keyWindow(), window.bounds.width > 0, window.bounds.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(window.screen.scale, 480 / max(window.bounds.width, window.bounds.height))
        let hidden = [banner, Blipit.reportButton].compactMap { $0 }.filter { !$0.isHidden }
        let secret = secureFields(in: window).map { $0.convert($0.bounds, to: window) }
        hidden.forEach { $0.isHidden = true }
        defer { hidden.forEach { $0.isHidden = false } }
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { ctx in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
            UIColor.black.setFill()
            secret.forEach { ctx.fill($0) }
        }
    }

    static func secureFields(in view: UIView) -> [UIView] {
        if let field = view as? UITextField, field.isSecureTextEntry, !field.isHidden { return [field] }
        return view.subviews.flatMap(secureFields)
    }

    static func installShake() {
        guard !shakeInstalled else { return }
        shakeInstalled = true
        let original = #selector(UIResponder.motionEnded(_:with:))
        let replacement = #selector(UIWindow.blipitMotionEnded(_:with:))
        guard let a = class_getInstanceMethod(UIWindow.self, original), let b = class_getInstanceMethod(UIWindow.self, replacement) else { return }
        if class_addMethod(UIWindow.self, original, method_getImplementation(b), method_getTypeEncoding(b)) {
            class_replaceMethod(UIWindow.self, replacement, method_getImplementation(a), method_getTypeEncoding(a))
        } else {
            method_exchangeImplementations(a, b)
        }
    }

    static func watch(_ window: UIWindow) {
        guard !(window.gestureRecognizers ?? []).contains(where: { $0 is TwoFingerPress }) else { return }
        let press = TwoFingerPress(target: watcher, action: #selector(TouchWatcher.pressed(_:)))
        press.numberOfTouchesRequired = 2
        press.minimumPressDuration = 1
        press.allowableMovement = 24
        press.cancelsTouchesInView = false
        press.delaysTouchesBegan = false
        press.delaysTouchesEnded = false
        press.delegate = watcher
        window.addGestureRecognizer(press)
    }

    static func prompt(_ kind: PromptState.Kind, crashId: String?) {
        guard let window = ReportFlow.keyWindow(), state.show(kind, now: now, reporterOpen: ReportFlow.active != nil) else { return }
        bannerCrash = crashId
        let lang = ReportLanguage.pick()
        let t = { (key: String) in ReportLanguage.text(key, lang) }
        let rtl: UISemanticContentAttribute = lang == "ar" ? .forceRightToLeft : .unspecified
        let card = UIView()
        card.backgroundColor = ReportTheme.card
        card.layer.cornerRadius = 16
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor.white.withAlphaComponent(0.1).cgColor
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.3
        card.layer.shadowRadius = 12
        card.layer.shadowOffset = CGSize(width: 0, height: 4)
        card.overrideUserInterfaceStyle = .dark
        card.semanticContentAttribute = rtl
        let text = ReportUI.label(t(kind == .crash ? "crashAsk" : "shotAsk"), size: 15, weight: .semibold)
        text.numberOfLines = 0
        text.textAlignment = .natural
        let later = UIButton(type: .system)
        later.setTitle(t("notNow"), for: .normal)
        later.setTitleColor(ReportTheme.muted, for: .normal)
        later.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        later.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        later.addAction(UIAction { _ in choose(report: false) }, for: .touchUpInside)
        let go = ReportUI.primary(t(kind == .crash ? "tellUs" : "report")) { choose(report: true) }
        let buttons = UIStackView(arrangedSubviews: [UIView(), later, go])
        buttons.spacing = 8
        buttons.alignment = .center
        buttons.semanticContentAttribute = rtl
        let stack = UIStackView(arrangedSubviews: [text, buttons])
        stack.axis = .vertical
        stack.spacing = 10
        stack.semanticContentAttribute = rtl
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        card.translatesAutoresizingMaskIntoConstraints = false
        window.addSubview(card)
        let guide = window.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            card.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            card.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -12),
        ])
        banner = card
        UIAccessibility.post(notification: .screenChanged, argument: text)
        let timeout = PromptState.timeout(kind)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            if state.expire(now: now) { close() }
        }
    }

    static func choose(report: Bool) {
        let kind = state.choose(report: report)
        let crash = bannerCrash
        close()
        switch kind {
        case .screenshot: fire(.screenshot)
        case .crash: fire(.crash, crashId: crash)
        case nil: break
        }
    }

    static func close() {
        banner?.removeFromSuperview()
        banner = nil
        bannerCrash = nil
    }

    static func shaken() {
        guard options?.shakeToReport == true else { return }
        fire(.shake)
    }
}

@available(iOS 15.0, *)
final class TwoFingerPress: UILongPressGestureRecognizer {}

@available(iOS 15.0, *)
final class TouchWatcher: NSObject, UIGestureRecognizerDelegate {
    @objc func pressed(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began { ReportTriggers.fire(.twoFinger) }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

extension UIWindow {
    @objc func blipitMotionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        blipitMotionEnded(motion, with: event)
        if motion == .motionShake, #available(iOS 15.0, *) { ReportTriggers.shaken() }
    }
}

@available(iOS 15.0, *)
final class ReportPickerController: UIViewController {
    let flow: ReportFlow
    let choices: [UIImage]

    init(flow: ReportFlow, choices: [UIImage]) {
        self.flow = flow
        self.choices = choices
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ReportTheme.navy
        overrideUserInterfaceStyle = .dark
        let back = ReportUI.bar(flow.t("mBack"), image: "chevron.backward") { [weak self] in
            guard let self else { return }
            self.flow.image = nil
            self.dismiss(animated: true) { self.flow.present(ReportChoiceController(flow: self.flow)) }
        }
        let title = ReportUI.label(flow.t("pickTitle"), size: 24, weight: .bold)
        title.numberOfLines = 0
        let row = UIStackView(arrangedSubviews: choices.enumerated().map { index, image in thumb(image, index) })
        row.spacing = 14
        row.alignment = .top
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        row.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(row)
        [back, title, scroll].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            back.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            back.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 12),
            title.topAnchor.constraint(equalTo: back.bottomAnchor, constant: 20),
            title.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 20),
            title.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 20),
            scroll.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -20),
            row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
        ])
    }

    func thumb(_ image: UIImage, _ index: Int) -> UIControl {
        let control = UIControl()
        let picture = UIImageView(image: image)
        picture.contentMode = .scaleAspectFit
        picture.layer.cornerRadius = 12
        picture.layer.borderWidth = index == 0 ? 2 : 1
        picture.layer.borderColor = (index == 0 ? ReportTheme.brand : UIColor.white.withAlphaComponent(0.15)).cgColor
        picture.clipsToBounds = true
        picture.backgroundColor = ReportTheme.card
        let caption = ReportUI.label(flow.t(index == 0 ? "pickNow" : "pickBefore"), size: 14, weight: .medium)
        caption.textAlignment = .center
        let stack = UIStackView(arrangedSubviews: [picture, caption])
        stack.axis = .vertical
        stack.spacing = 8
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        control.addSubview(stack)
        let ratio = image.size.width > 0 ? image.size.height / image.size.width : 2
        NSLayoutConstraint.activate([
            picture.widthAnchor.constraint(equalToConstant: 130),
            picture.heightAnchor.constraint(equalToConstant: min(130 * ratio, 300)),
            stack.topAnchor.constraint(equalTo: control.topAnchor),
            stack.bottomAnchor.constraint(equalTo: control.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: control.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: control.trailingAnchor),
        ])
        control.isAccessibilityElement = true
        control.accessibilityLabel = caption.text
        control.accessibilityTraits = .button
        control.addAction(UIAction { [weak self] _ in self?.pick(image) }, for: .touchUpInside)
        return control
    }

    func pick(_ image: UIImage) {
        flow.image = image
        dismiss(animated: false) { self.flow.present(ReportEditorController(flow: self.flow, image: image)) }
    }
}
#endif
