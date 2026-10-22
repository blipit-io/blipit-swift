# BlipitSwift

Blipit error monitoring for iOS, macOS, tvOS and watchOS. Know your app broke before your users tell you.

## Install

In Xcode, File > Add Package Dependencies and enter `https://github.com/blipit-io/blipit-swift`, or in `Package.swift`:

```swift
.package(url: "https://github.com/blipit-io/blipit-swift", from: "0.3.1")
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

## Stuck on startup

An app that never gets past its splash or loading screen does not crash or throw, so nothing is reported on its own. Call `reportReady` once the first real screen can be used:

```swift
Blipit.addBreadcrumb("session restored", category: "startup")
Blipit.reportReady()
```

From `start`, Blipit counts the time the app is in the foreground (time in the background is not counted). If `reportReady` has not been called after 20 seconds, it sends one warning for that launch: `App did not become ready within 20 s`, with the tags `startup.stalled=true`, `startup.deadline_ms` and `startup.screen` (the top view controller, iOS) and the breadcrumbs added so far. Every such launch is grouped into one Stuck on startup issue. A later `reportReady` adds an `App became ready after N ms` breadcrumb instead of a second event, and also calls Sentry's `reportFullyDisplayed`, so apps with time to full display tracing on get the measurement too. Calling it more than once is fine.

Change the deadline in seconds, or turn the check off with 0:

```swift
Blipit.start(key: "<public key>", project: "<project id>", startupDeadline: 30)
```

## Bug reports

On iOS 15 and later, show the floating Report a bug button, or open the reporter from your own menu:

```swift
Blipit.showReportButton()
Blipit.showReport()
```

The reporter asks first: Take a screenshot, Record a video (in-app ReplayKit, only your app is recorded) or Skip. The screenshot opens full screen with the tools above and below it; pinch or double-tap to zoom, mark the problem, then add a title and what happened and send. Reports arrive under Bug reports at app.blipit.io.

## Performance

Pass `tracesSampleRate: 0.2` to `start` and app starts, screen loads and requests show up on the Performance page.

Docs: https://docs.blipit.io/mobile
