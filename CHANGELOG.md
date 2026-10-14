## 0.3.0
- `Blipit.showReport()` and `Blipit.showReportButton()` (iOS 15 and later): the reporter asks first, Take a screenshot, Record a video or Skip. The screenshot opens full screen with Back, zoom and Next above it and Draw, Rectangle, Arrow, Undo and Fit below it; pinch, two-finger pan and double-tap zoom up to 5x, and marks land where you touch at any zoom. Then a title, what happened and an optional email, and Send. Recordings use in-app ReplayKit (only your app is recorded) and are capped at the plan's recording length.
- Events carry the `swiftpm:blipit-swift` package, so the dashboard can tell you when an update is out.

## 0.2.0

- `Blipit.start` and `Blipit.configure` with an empty key or project id print a warning, return false and leave Blipit off instead of crashing on a precondition.
- `captureException(_:)` and `captureMessage(_:level:)`, matching the other SDKs; `capture(error:)` and `capture(message:level:)` still work.
