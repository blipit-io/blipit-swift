## 0.6.0
- Report from the screen with the bug, all off by default: `shakeToReport` (shake opens the reporter on the current screen), `screenshotToReport` (an iOS screenshot shows a small "Report a bug with this screen?" prompt for 6 seconds; Report opens the reporter with Blipit's own capture), `twoFingerReport` (two-finger press and hold for about a second, touches are only watched) and `reportAfterCrash` (the first launch after a caught crash asks what the person was doing and links the report to that crash). One trigger opens one reporter, never while one is open.
- `screenPicker`, on by default because it only changes the reporter: `Blipit.showReport()` from your own menu asks which screen the bug is on, with the current screen and up to 3 earlier ones. Earlier screens are small in-memory snapshots with password fields blacked out, never written to disk, cleared after 3 minutes in the background or when consent is off; only the picked one is uploaded. Set `screenPicker = false` to keep the old flow.
- The floating Report a bug button can now be switched on by Blipit for everyone or for testers only (dashboard, Bug reports). The SDK sends the `setUser` id and email with the settings request and gets back only yes or no. `showReportButton()` keeps working as before; `hideReportButton()` removes the button unless Blipit's setting shows it.
- `Blipit.setScreen(_:)` names the current screen for SwiftUI and other views without their own view controller (for example `.onAppear { Blipit.setScreen("Cart") }`): it adds the same screen breadcrumb as automatic tracking and gives the screen picker a snapshot of it.
- `Blipit.setReportHandler(_:)`, `Blipit.promptAfterCrash(_:)` and `Blipit.lastCrashId` for the React Native and Flutter bridges.
- No new permissions, no CoreMotion and no new required-reason API; the privacy manifest is unchanged. Prompt and picker texts in all 11 reporter languages, right to left in Arabic.
- Platform mismatch: when Blipit refuses data because the key belongs to a project for another platform (HTTP 409 platform_mismatch), the SDK logs one clear error and stops sending for the rest of the launch. Crash reports, sessions, events and bug reports all stop; the message shows in the Xcode console.

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
