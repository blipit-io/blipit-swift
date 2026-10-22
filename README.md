# BlipitSwift

Blipit error monitoring for iOS, macOS, tvOS and watchOS. Know your app broke before your users tell you.

Since 0.5.0 the package runs on blipit-nuggets, Blipit's own crash and error core. It has no third-party dependencies and talks only to Blipit, in Blipit's own event format.

## Install

In Xcode, File > Add Package Dependencies and enter `https://github.com/blipit-io/blipit-swift`, or in `Package.swift`:

```swift
.package(url: "https://github.com/blipit-io/blipit-swift", from: "0.5.1")
```

and add `BlipitSwift` to your target's dependencies.

## Quick start

Call `start` once, in `application(_:didFinishLaunchingWithOptions:)` or the `App` initializer.

```swift
import BlipitSwift

Blipit.start(key: "<public key>", project: "<project id>", environment: "production", release: "myapp@1.4.2")
```

Both values are on the project's Keys page at app.blipit.io. If the key or project id is empty, `start` prints a warning, returns `false` and Blipit stays off; it never crashes the app. Without `release`, Blipit uses `<bundle id>@<version>+<build>`.

## What is reported on its own

- Crashes: signals (SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGFPE, SIGTRAP, SIGSYS) and, on iOS and macOS, Mach exceptions (bad access, bad instruction, arithmetic, traps). At crash time Blipit only writes a small file with the crashed thread's return addresses and the loaded images; it is symbolicated and sent on the next launch, with the breadcrumbs, user, tags, release and environment of the run that crashed.
- Uncaught Objective-C exceptions (`NSException`), with their name, reason and stack.
- App hangs: the main thread blocked for 2 seconds or more, with the main thread's stack at that moment.
- Watchdog and out-of-memory terminations (iOS, tvOS): if the last run ended while the app was in the foreground, without a crash file and without a clean exit, on the same app build, OS version and boot, the next launch reports it as `WatchdogTermination`. A low-memory warning before the end, or a hang in progress, is named in the report. Runs under the debugger are never counted.
- Sessions for release health: one per foreground period (a new one after 30 seconds in the background), marked errored, crashed or abnormal.
- Breadcrumbs: app lifecycle, screens (UIKit view controllers from your app's bundle) and `URLSession` requests (method, URL without query string, status, duration; never headers or bodies).

## Manual capture

```swift
Blipit.captureException(error)
Blipit.captureMessage("cache miss rate above 50%", level: .warning)
Blipit.setUser(id: "42", email: "ana@example.com")
Blipit.setTag("region", "ap-southeast-1")
Blipit.setContext("cart", ["items": 3])
Blipit.addBreadcrumb("opened checkout", category: "ui")
Blipit.captureSecurity(kind: "login_failed", actor: "ana@example.com", ip: "10.0.0.1")
Blipit.flush()
```

`capture(error:)` and `capture(message:level:)` still work and do the same thing. Each call returns the event's `EventId` (empty when nothing was sent).

## Options

```swift
Blipit.start(key: "<public key>", project: "<project id>") { options in
    options.sampleRate = 0.5
    options.hangThreshold = 3
    options.networkBreadcrumbs = false
    options.beforeSend = { event in
        var event = event
        event["tags"] = ["build": "beta"]
        return event
    }
}
```

`enabled`, `environment`, `release`, `sampleRate` (errors only, never crashes), `tracesSampleRate`, `maxBreadcrumbs` (up to 100), `debug`, `crashes`, `machExceptions`, `hangs`, `hangThreshold`, `watchdogTerminations`, `sessions`, `networkBreadcrumbs`, `screenBreadcrumbs`, `lifecycleBreadcrumbs`, `shakeToReport`, `screenshotToReport`, `twoFingerReport`, `reportAfterCrash`, `screenPicker` (see Bug reports), `beforeSend` (gets and returns the event as Blipit JSON; return `nil` to drop it) and `directory` (where queued events wait).

## Offline, rate limits and consent

Events, sessions, stuck reports and spans are written to a queue in the app's Application Support folder (Caches on tvOS), excluded from backups, and sent in order. Without a connection or on a server error they wait and are retried with back-off, also after the next launch; the queue keeps the newest 100. On HTTP 429 nothing is sent until the `Retry-After` time has passed, also across launches. An invalid key stops sending for the rest of the run.

```swift
Blipit.setConsent(false)
```

stops all sending, deletes everything queued and any pending crash file, and is remembered across launches until `setConsent(true)`. `Blipit.hasConsent` reads it.

## Stuck screens and flows

Some failures never crash: the launch screen keeps spinning, or Sign in with Apple never calls back. Tell Blipit when the app is ready and wrap the flows that must finish:

```swift
Blipit.start(key: "<public key>", project: "<project id>", waitForReady: true)

Blipit.reportReady()

Blipit.startFlow("sign-in")
Blipit.flowStep("sign-in", "apple-sheet")
Blipit.endFlow("sign-in")
```

With `waitForReady: true`, call `Blipit.reportReady()` once the first usable screen shows.

If one does not finish in time, Blipit opens a **Stuck** issue with the flow, the last step, the screen when it is known, how long it waited and the steps before it. Only time on screen counts: while the app is in the background the clock stops, so a sign-in that sends people to a browser is not cut short. Blipit sets the time limits on its side and the SDK picks them up with its settings, so they can change without an app release. Nothing is decided before those settings arrive.

Call `startFlow` when the person starts the action (taps Continue with Google), not when the screen opens. `endFlow` covers every way out, including the person cancelling. Flow and step names are sent as you write them: use fixed names such as `sign-in` or `google-picker`, never emails, phone numbers or other personal data.

## Bug reports

On iOS 15 and later, show the floating Report a bug button, or open the reporter from your own menu:

```swift
Blipit.showReportButton()
Blipit.showReport()
```

The reporter asks first: Take a screenshot, Record a video (in-app ReplayKit, only your app is recorded) or Skip. The screenshot opens full screen with the tools above and below it; pinch or double-tap to zoom, mark the problem, then add a title and what happened and send. Reports arrive under Bug reports at app.blipit.io.

### Report from the screen with the bug

A Report a bug item in a Profile or Settings menu means the screenshot shows that menu, not the screen where the bug was. Turn on any of these so people can report from where they are:

```swift
Blipit.start(key: "<public key>", project: "<project id>") { options in
    options.shakeToReport = true
    options.screenshotToReport = true
    options.twoFingerReport = true
    options.reportAfterCrash = true
}
Blipit.setUser(id: "42", email: "ana@example.com")
```

- `shakeToReport` (off by default): shaking the phone opens the reporter on the current screen. One shake opens one reporter, never while a reporter or a Blipit prompt is open.
- `screenshotToReport` (off by default): when the person takes a normal iOS screenshot in your app, a small prompt asks "Report a bug with this screen?" with Report and Not now, and goes away after 6 seconds. Report opens the reporter with Blipit's own capture of the screen. The SDK never reads the photo library; it only learns that a screenshot happened.
- `twoFingerReport` (off by default): a two-finger press and hold of about one second anywhere opens the reporter. It only watches touches; your buttons, scrolls and gestures keep working.
- `reportAfterCrash` (off by default): on the first launch after a crash Blipit caught, a prompt asks "The app closed unexpectedly. Tell us what you were doing?". Tell us opens the reporter (text only or with a screenshot) and links the report to that crash, so the crash issue shows the report and the report shows the crash. It asks once per crash.
- `screenPicker` (on by default, it only changes the reporter): when you open the reporter from your own code with `Blipit.showReport()`, Take a screenshot asks "Which screen is the bug on?" with the current screen and up to 3 screens the person saw before it. The earlier screens are small snapshots kept in memory only: never on disk, never in crash files or logs, password fields blacked out, cleared after 3 minutes in the background or when consent is turned off. Only the screen the person picks is uploaded. Snapshots are taken for your own view controllers about 0.7 s after each one appears. SwiftUI screens are not view controllers of their own, so name them with `Blipit.setScreen`, which also adds the screen breadcrumb:

  ```swift
  CartView()
      .onAppear { Blipit.setScreen("Cart") }
  ```
- Floating button for testers: in the dashboard, Project settings, Bug reports, set Floating button on phone apps to Off, Everyone or Testers only and list the testers' user ids or emails. The SDK sends the id and email you set with `Blipit.setUser` and Blipit answers only yes or no, so the tester list never reaches the app. `Blipit.showReportButton()` still shows the button whatever the setting says.

React Native and Flutter use the same native triggers through `Blipit.setReportHandler { trigger, crashId in }`, which hands the trigger to your own reporter instead of opening this one, and `Blipit.promptAfterCrash(_:)` for a crash caught outside Swift. `Blipit.lastCrashId` returns the last caught crash once.

## Performance

Pass `tracesSampleRate: 0.2` to `start` and the app start, UIKit screen loads and `URLSession` requests are sent as spans to the Performance page.

## Check the setup

`Blipit.crash()` crashes the app on purpose. Run the app without the debugger (stop it in Xcode, then open it from the home screen), tap the button that calls it, open the app again, and the crash shows up at app.blipit.io.

## Upgrading from 0.4

- `Options` is now Blipit's own class with the fields listed above; code that set other fields in the `configure` closure must drop them.
- `capture...` returns `EventId` and `level:` takes `Level` (`.fatal`, `.error`, `.warning`, `.info`, `.debug`).
- `Blipit.dsn(key:project:endpoint:)` is gone; `start` takes the key and project id directly.
- `beforeSend` receives and returns the event as a dictionary in Blipit's format.

## App Store checklist

- Privacy manifest: the package ships `PrivacyInfo.xcprivacy`. Xcode merges it into your app's privacy report.
  - Required reason API: system boot time (`NSPrivacyAccessedAPICategorySystemBootTime`, reason `35F9.1`), used to time hangs and startup and to tell a reboot from a watchdog kill. The boot time never leaves the device.
  - No UserDefaults, no file timestamp, disk space or active keyboard APIs.
  - Tracking: `NSPrivacyTracking` is false and there are no tracking domains. No IDFA, no `AdSupport`, no App Tracking Transparency prompt, no device fingerprinting.
- App Privacy label in App Store Connect, data the SDK collects on its own, none linked to the user's identity and none used for tracking:
  - Diagnostics, Crash Data: App Functionality.
  - Diagnostics, Performance Data: App Functionality.
  - Diagnostics, Other Diagnostic Data: App Functionality.
  - Usage Data, Product Interaction (sessions, screen and lifecycle breadcrumbs): App Functionality, Analytics.
- Add these yourself when your app uses the matching calls:
  - `setUser(id:)`: Identifiers, User ID, linked to the user.
  - `setUser(email:)` or an email typed in the bug reporter: Contact Info, Email Address, linked to the user.
  - Bug reports: User Content, Other User Content (text, screenshots, screen recordings), App Functionality.
- No private APIs. Crash capture uses public POSIX signal APIs and public Mach APIs from the SDK headers; breadcrumbs swap `UIViewController.viewDidLoad`/`viewDidAppear` and `URLSessionTask.resume` through the public Objective-C runtime.
- The report triggers use only public UIKit: shake is the UIKit motion event (`motionEnded` with `.motionShake`, reached by swapping `UIWindow.motionEnded` once through the public Objective-C runtime and calling the original), not CoreMotion, so there is no motion permission, no `NSMotionUsageDescription` and nothing to declare. Screenshot to report listens to `UIApplication.userDidTakeScreenshotNotification`, which needs no permission and gives no access to the image or the photo library. The two-finger press is a standard `UILongPressGestureRecognizer` that never cancels or delays your touches. No new required-reason API, so `PrivacyInfo.xcprivacy` is unchanged.
- No background modes, no entitlements and no Info.plist keys are needed. Screen recording in the bug reporter is in-app ReplayKit and asks the user every time.
- Data goes only to `in.blipit.io` (or the `endpoint` you pass), over HTTPS.

## Tests

`swift test` on a Mac runs the whole suite, including real crashes in a forked child process (signal, abort, trap and a Mach exception), a real main-thread hang and the crash file round trip. `xcodebuild test -scheme BlipitSwift -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` runs it on a simulator too.

What needs a real device: Mach exception handling and stack walking on arm64e (pointer authentication), watchdog and out-of-memory terminations (the simulator does not run the watchdog or jetsam), and symbol names in release builds, where app symbols are stripped and frames show `MyApp + 0x1a2b` instead.

Docs: https://docs.blipit.io/mobile
