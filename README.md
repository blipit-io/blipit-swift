# BlipitSwift

Blipit error monitoring for iOS, macOS, tvOS and watchOS. Know your app broke before your users tell you.

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

Both values are on the project's Keys page at app.blipit.io. If the key or project id is empty, `start` prints a warning, returns `false` and Blipit stays off; it never crashes the app. Crashes and uncaught exceptions are reported on their own.

## Manual capture

```swift
Blipit.captureException(error)
Blipit.captureMessage("cache miss rate above 50%", level: .warning)
Blipit.setUser(id: "42", email: "ana@example.com")
Blipit.setTag("region", "ap-southeast-1")
Blipit.addBreadcrumb("opened checkout", category: "ui")
Blipit.captureSecurity(kind: "login_failed", actor: "ana@example.com", ip: "10.0.0.1")
Blipit.flush()
```

`capture(error:)` and `capture(message:level:)` still work and do the same thing.

## Bug reports

On iOS 15 and later, show the floating Report a bug button, or open the reporter from your own menu:

```swift
Blipit.showReportButton()
Blipit.showReport()
```

The reporter asks first: Take a screenshot, Record a video (in-app ReplayKit, only your app is recorded) or Skip. The screenshot opens full screen with the tools above and below it; pinch or double-tap to zoom, mark the problem, then add a title and what happened and send. Reports arrive under Bug reports at app.blipit.io.

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

## Store declarations

What to declare when you ship an app with Blipit:

- **Apple App Store**: the package ships a privacy manifest (`PrivacyInfo.xcprivacy`) that declares crash data, performance data and other diagnostic data, not linked to the person and not used for tracking. In App Store Connect, App Privacy, declare the same three types under App Functionality, not linked, no tracking. Blipit uses no required-reason APIs of its own, no IDFA, no App Tracking Transparency prompt and no background modes. If you call `setUser` with an id or email, declare those as linked to the person.

## Performance

Pass `tracesSampleRate: 0.2` to `start` and app starts, screen loads and requests show up on the Performance page.

Docs: https://docs.blipit.io/mobile
