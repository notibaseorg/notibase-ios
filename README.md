<p align="center">
  <img src="https://notibase.com/icon-512.png" width="72" alt="Notibase">
</p>
<h1 align="center">Notibase iOS SDK</h1>
<p align="center">
  Push notifications, in-app inbox and click tracking for iOS —
  <b>zero dependencies</b>, Foundation only.<br>
  <a href="https://notibase.dev/ios.html">Documentation</a> ·
  <a href="https://notibase.com">Website</a> ·
  <a href="https://app.notibase.com">Console</a>
</p>

---

Swift, iOS 13+, Foundation only — nothing to version-conflict with your app.

## Install (Swift Package Manager)

Xcode → **File → Add Package Dependencies…** → paste:

```
https://github.com/notibaseorg/notibase-ios
```

…and pick version **0.2.1** (or "Up to Next Major"). Or in `Package.swift`:

```swift
.package(url: "https://github.com/notibaseorg/notibase-ios.git", from: "0.2.1")
// product: "Notibase"
```

## Requirements

An **Apple Developer Program** membership and an **APNs auth key** (`.p8`),
uploaded once in the Notibase console. Enable the *Push Notifications*
capability on your target.

Full walkthrough from an empty Apple Developer account:
**[notibase.dev/ios.html](https://notibase.dev/ios.html)**

## Quick start

```swift
import Notibase

// AppDelegate
func application(_ app: UIApplication,
    didFinishLaunchingWithOptions opts: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
  Notibase.configure(clientKey: "ck_live_…")        // public by design
  Notibase.requestAuthorization { granted in
    if granted {
      DispatchQueue.main.async { app.registerForRemoteNotifications() }
    }
  }
  return true
}

func application(_ app: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
  Notibase.setAPNsToken(token)                      // registers the device
}
```

## Click tracking

Report notification taps from your notification-center delegate — one line,
and the Clicked / CTR columns in the console light up:

```swift
func userNotificationCenter(_ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completion: @escaping () -> Void) {
  Notibase.trackNotificationOpen(userInfo:
      response.notification.request.content.userInfo)
  completion()
}
```

Notifications from other services are ignored safely.

## Identity, events, inbox

```swift
// signature minted by YOUR backend — https://notibase.dev/security.html
Notibase.identify("user-42", signature: sig, attributes: ["plan": "pro"])

Notibase.track("purchase", properties: ["value": 9.99])

Notibase.inbox { items in /* render your notification center */ }
Notibase.inboxMarkRead([itemId])
```

> Test on a real device — the simulator cannot receive APNs pushes. Use the
> *development* APNs environment while running debug builds from Xcode.

## Support

- Docs: [notibase.dev/ios.html](https://notibase.dev/ios.html)
- Issues & feature requests: [support@notibase.com](mailto:support@notibase.com)
- Security reports: [security@notibase.com](mailto:security@notibase.com)

## License

MIT © Notibase — see [LICENSE](LICENSE).

<sub>This repository is a published snapshot of the Notibase SDK, updated
automatically on each release.</sub>
