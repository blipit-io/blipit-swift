## 0.5.0
- Runs on blipit-nuggets, Blipit's own crash and error core. The package has no third-party dependencies any more and sends only Blipit's own format to `/api/v1/events`, `/api/v1/sessions` and `/v1/traces`.
- Crashes from signals and, on iOS and macOS, Mach exceptions are written to a small file at crash time and symbolicated and sent on the next launch with that run's breadcrumbs, user, tags and release. Uncaught `NSException`s keep their name, reason and stack.
- App hangs (main thread blocked for 2 s, `hangThreshold`) are reported with the main thread's stack. Watchdog and out-of-memory terminations on iOS and tvOS are reported on the next launch as `WatchdogTermination`, only when the app was on screen, did not crash, did not exit cleanly and the build, OS and boot are the same.
- Offline queue on disk (newest 100), retries with back-off, `Retry-After` honoured across launches, an invalid key stops sending.
- `Blipit.setConsent(_:)` and `Blipit.hasConsent`: no consent, nothing is sent and the queue is deleted; remembered across launches. `Blipit.setContext(_:_:)` and `Blipit.crash()`.
- Sessions, lifecycle, screen and `URLSession` breadcrumbs, and app start, screen load and request spans with `tracesSampleRate`, all built in.
- Privacy manifest with the system boot time reason `35F9.1`, the collected data types and no tracking; App Store checklist in the README.
- Stuck startup and flow reports go through the same disk queue, consent and `beforeSend` as every other event, so they survive going offline and a relaunch.
- Breaking: `Options` is Blipit's own class, `capture...` return `EventId`, `level:` takes `Level`, `beforeSend` works on the event as a dictionary, `Blipit.dsn` is gone, and the stuck-on-startup check no longer calls `reportFullyDisplayed`.

## 0.4.0

- Stuck screens and flows: `waitForReady` with `Blipit.reportReady()`, and `startFlow`, `flowStep` and `endFlow`. When the app never reaches its first usable screen, or a flow such as sign-in never finishes, Blipit opens a Stuck issue with the last step and the steps before it. Only time on screen counts; the time limits come from Blipit.
- `startupDeadline` from 0.3.1 is now off by default and only switches the check on (any value above 0); the limit comes from Blipit. Apps that relied on the 0.3.1 default pass `waitForReady: true`.
- Ships a privacy manifest (`PrivacyInfo.xcprivacy`): crash, performance and other diagnostic data, not linked, no tracking, no required-reason APIs.

## 0.3.1
- Stuck on startup: `Blipit.reportReady()` and the `startupDeadline` parameter of `start` (20 seconds by default, 0 turns it off). If the app has been in the foreground that long without `reportReady`, one warning is sent per launch, grouped into one Stuck on startup issue with the screen and breadcrumbs. A late `reportReady` adds a breadcrumb with the time it took and calls `SentrySDK.reportFullyDisplayed()`.

## 0.3.0
- `Blipit.showReport()` and `Blipit.showReportButton()` (iOS 15 and later): the reporter asks first, Take a screenshot, Record a video or Skip. The screenshot opens full screen with Back, zoom and Next above it and Draw, Rectangle, Arrow, Undo and Fit below it; pinch, two-finger pan and double-tap zoom up to 5x, and marks land where you touch at any zoom. Then a title, what happened and an optional email, and Send. Recordings use in-app ReplayKit (only your app is recorded) and are capped at the plan's recording length.
- Events carry the `swiftpm:blipit-swift` package, so the dashboard can tell you when an update is out.

## 0.2.0

- `Blipit.start` and `Blipit.configure` with an empty key or project id print a warning, return false and leave Blipit off instead of crashing on a precondition.
- `captureException(_:)` and `captureMessage(_:level:)`, matching the other SDKs; `capture(error:)` and `capture(message:level:)` still work.
