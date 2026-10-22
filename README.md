# BlipitSwift

Blipit error monitoring for iOS, macOS, tvOS and watchOS. Know your app broke before your users tell you.

Since 0.4.0 the package runs on blipit-nuggets, Blipit's own crash and error core. It has no third-party dependencies and talks only to Blipit, in Blipit's own event format.

## Install

In Xcode, File > Add Package Dependencies and enter `https://github.com/blipit-io/blipit-swift`, or in `Package.swift`:

```swift
.package(url: "https://github.com/blipit-io/blipit-swift", from: "0.4.0")
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

`enabled`, `environment`, `release`, `sampleRate` (errors only, never crashes), `tracesSampleRate`, `maxBreadcrumbs` (up to 100), `debug`, `crashes`, `machExceptions`, `hangs`, `hangThreshold`, `watchdogTerminations`, `sessions`, `networkBreadcrumbs`, `screenBreadcrumbs`, `lifecycleBreadcrumbs`, `beforeSend` (gets and returns the event as Blipit JSON; return `nil` to drop it) and `directory` (where queued events wait).

## Offline, rate limits and consent

Events, sessions and spans are written to a queue in the app's Application Support folder (Caches on tvOS), excluded from backups, and sent in order. Without a connection or on a server error they wait and are retried with back-off, also after the next launch; the queue keeps the newest 100. On HTTP 429 nothing is sent until the `Retry-After` time has passed, also across launches. An invalid key stops sending for the rest of the run.

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

## Performance

Pass `tracesSampleRate: 0.2` to `start` and the app start, UIKit screen loads and `URLSession` requests are sent as spans to the Performance page.

## Check the setup

`Blipit.crash()` crashes the app on purpose. Run the app without the debugger (stop it in Xcode, then open it from the home screen), tap the button that calls it, open the app again, and the crash shows up at app.blipit.io.

## Upgrading from 0.3

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
- No background modes, no entitlements and no Info.plist keys are needed. Screen recording in the bug reporter is in-app ReplayKit and asks the user every time.
- Data goes only to `in.blipit.io` (or the `endpoint` you pass), over HTTPS.

## Tests

`swift test` on a Mac runs the whole suite, including real crashes in a forked child process (signal, abort, trap and a Mach exception), a real main-thread hang and the crash file round trip. `xcodebuild test -scheme BlipitSwift -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` runs it on a simulator too.

What needs a real device: Mach exception handling and stack walking on arm64e (pointer authentication), watchdog and out-of-memory terminations (the simulator does not run the watchdog or jetsam), and symbol names in release builds, where app symbols are stripped and frames show `MyApp + 0x1a2b` instead.

Docs: https://docs.blipit.io/mobile
