## 0.2.0

- `Blipit.start` and `Blipit.configure` with an empty key or project id print a warning, return false and leave Blipit off instead of crashing on a precondition.
- `captureException(_:)` and `captureMessage(_:level:)`, matching the other SDKs; `capture(error:)` and `capture(message:level:)` still work.
