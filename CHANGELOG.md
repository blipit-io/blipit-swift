## 0.3.1
- Stuck on startup: `Blipit.reportReady()` and the `startupDeadline` parameter of `start` (20 seconds by default, 0 turns it off). If the app has been in the foreground that long without `reportReady`, one warning is sent per launch, grouped into one Stuck on startup issue with the screen and breadcrumbs. A late `reportReady` adds a breadcrumb with the time it took and calls `SentrySDK.reportFullyDisplayed()`.

## 0.3.0
- `Blipit.showReport()` and `Blipit.showReportButton()` (iOS 15 and later): the reporter asks first, Take a screenshot, Record a video or Skip. The screenshot opens full screen with Back, zoom and Next above it and Draw, Rectangle, Arrow, Undo and Fit below it; pinch, two-finger pan and double-tap zoom up to 5x, and marks land where you touch at any zoom. Then a title, what happened and an optional email, and Send. Recordings use in-app ReplayKit (only your app is recorded) and are capped at the plan's recording length.
- Events carry the `swiftpm:blipit-swift` package, so the dashboard can tell you when an update is out.

## 0.2.0

- `Blipit.start` and `Blipit.configure` with an empty key or project id print a warning, return false and leave Blipit off instead of crashing on a precondition.
- `captureException(_:)` and `captureMessage(_:level:)`, matching the other SDKs; `capture(error:)` and `capture(message:level:)` still work.
