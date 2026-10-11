# BlipitSwift

Blipit error monitoring for iOS, macOS, tvOS and watchOS. Know your app broke before your users tell you.

## Install

In Xcode, File > Add Package Dependencies and enter `https://github.com/blipit-io/blipit-swift`, or in `Package.swift`:

```swift
.package(url: "https://github.com/blipit-io/blipit-swift", from: "0.2.0")
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

## Performance

Pass `tracesSampleRate: 0.2` to `start` and app starts, screen loads and requests show up on the Performance page.

Docs: https://docs.blipit.io/mobile
