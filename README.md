# Notibase iOS SDK

Native iOS SDK for [Notibase](https://notibase.com). Swift, iOS 13+,
**zero dependencies** — Foundation only, so it can never version-conflict
with a host app.

## Install (Swift Package Manager)

Xcode → File → Add Package Dependencies → this repository URL
(subpath `packages/sdk-ios`), or in `Package.swift`:

```swift
.package(url: "https://github.com/notibaseorg/notibase.git", branch: "master")
// product: "Notibase"
```

## Use

```swift
import Notibase

// AppDelegate / App init
Notibase.configure(clientKey: "ck_live_…")      // client key — public by design

// after your soft-prompt, from a user gesture:
Notibase.requestAuthorization { granted in
    if granted { DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() } }
}

func application(_ application: UIApplication,
                 didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    Notibase.setAPNsToken(deviceToken)          // registers the device
}

// after login — signature minted by YOUR backend (docs → Security)
Notibase.identify("user-42", signature: sig, attributes: ["plan": "pro"])

// custom events → segments + attribution
Notibase.track("level_complete", properties: ["level": 3])

// in-app inbox
Notibase.inbox { items in /* render */ }
Notibase.inboxMarkRead([id])
```

Sending goes through **your** APNs credentials (the .p8 you upload in the
dashboard) — the SDK only registers the token and talks to the Notibase API.

## Verification

The dev sandbox has no Swift toolchain, so CI is the gate
(`.github/workflows/ios-sdk.yml`):

- **linux-e2e** — the core is Foundation-only, so the *exact shipped code*
  compiles on Linux and runs `Sources/TestMain` against the real API
  (buildServer on PGlite via `apps/api/scripts/e2e-ios-core.mjs`): sk_ key
  refusal, 401s, registration idempotency, HMAC identify enforcement
  (unsigned/forged → 403), track, send → inbox → markRead.
- **ios-build** — `xcodebuild` compiles the package for the real iOS
  platform on a macOS runner.

## Security model

The `ck_` client key ships inside the IPA and is public by design (Arch
§5.3): it can only register devices, identify **with an HMAC signature your
backend mints**, track events, and read its own device's inbox. Server keys
(`sk_`) are refused at `configure` time with a teaching error.
