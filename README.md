<p align="center">
  <img src="https://notibase.com/icon-512.png" width="72" alt="Notibase">
</p>
<h1 align="center">Notibase iOS SDK</h1>
<p align="center">
  Push notifications, in-app messages, an in-app inbox and click tracking
  for iOS — <b>zero dependencies</b>, Foundation only.<br>
  <a href="https://notibase.dev/ios.html">Documentation</a> ·
  <a href="https://notibase.com">Website</a> ·
  <a href="https://app.notibase.com">Console</a>
</p>

---

Swift, iOS 13+, Foundation only — nothing to version-conflict with your app.

## Coming from OneSignal

Notibase is an alternative to OneSignal, and the device-side model is the
same shape: register a token, identify the person behind it, tag them, send
to a segment. Most of a port is renaming calls. What is arranged differently
is that push, in-app messages, an in-app inbox, email and SMS are one
audience and one API here rather than several products with separate lists.

It does not sit between your app and Apple. Notibase talks to APNs with your
own `.p8` key, so the notifications go out on your own credentials — and the
same campaign reaches Android, the web, an inbox, an email and a text
without you writing any of it a second time.


## Install (Swift Package Manager)

Xcode → **File → Add Package Dependencies…** → paste:

```
https://github.com/notibaseorg/notibase-ios
```

…and pick version **0.7.3** (or "Up to Next Major"). Or in `Package.swift`:

```swift
.package(url: "https://github.com/notibaseorg/notibase-ios.git", from: "0.7.3")
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
  Notibase.registerForPushNotifications()          // permission + APNs + opens
  return true
}

// Only your app delegate receives the token — forward this one line:
func application(_ app: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
  Notibase.setAPNsToken(token)
}
```

`registerForPushNotifications` asks for permission, registers with APNs, and
installs a notification-centre delegate that records opens and follows the
message's URL. It **wraps** whatever delegate you already have rather than
replacing it, so an app with its own handling keeps all of it.

Notifications from other services are ignored safely.

## Rich notifications

Images and action buttons cannot be shown on iOS from a payload alone — both
need an extension running between APNs and the notification. Add it once in
Xcode (File → New → Target → Notification Service Extension), add the
`NotibaseNotificationService` product to that target, and replace the
generated class with:

```swift
import NotibaseNotificationService
class NotificationService: NotibaseNotificationService {}
```

Without one, images and buttons are dropped **silently** — the setup test
below says so.

## Where a tap goes

A message composed with a URL opens that URL. A tapped action button that
carries its own URL goes there instead. To route inside your app:

```swift
Notibase.notificationUrlHandler = { url in
  guard url.scheme == "darlivo" else { return false }
  Router.shared.go(to: url)
  return true          // handled — Notibase does nothing more
}
```

`Notibase.openNotificationUrls = false` turns opening off entirely. `file:`,
`javascript:` and `data:` URLs are refused.

## Keeping your own delegate

Skip `installNotificationDelegate` and do both halves yourself:

```swift
func userNotificationCenter(_ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completion: @escaping () -> Void) {
  let info = response.notification.request.content.userInfo
  Notibase.trackNotificationOpen(userInfo: info)
  Notibase.openNotificationUrl(userInfo: info, actionId: response.actionIdentifier)
  completion()
}
```

## Attribution

Installs, sessions and revenue are reported for you. `install` goes out once
and `session_start` on each cold start, as soon as the device is registered —
which is what lets a campaign link be credited with the installs it drove.

```swift
// a Universal Link or your own scheme that opened the app
.onOpenURL { Notibase.handleDeepLink($0) }

Notibase.trackPurchase(9.99, currency: "USD", productId: "pro_monthly")
```

`Notibase.autoTrackSessions = false` turns the automatic events off.
Full model: [notibase.dev/attribution.html](https://notibase.dev/attribution.html)

## Setup test

Everything that usually goes wrong during an integration is invisible from
inside the app: credentials that were never uploaded, an APNs key minted for
another bundle, a client key belonging to a different app. Add one line to a
debug build and the answer prints in the console — and in the dashboard,
under Settings → Push platforms:

```swift
#if DEBUG
Notibase.runSetupTest()
#endif
```

```
✔ Client key belongs to "helloworld"
✘ The APNs key is for a different bundle id
    This build is com.darlivo.app.dev; the uploaded key is for com.darlivo.app. …
```

## Identity, events, inbox

```swift
// signature minted by YOUR backend — https://notibase.dev/security.html
Notibase.identify("user-42", signature: sig, attributes: ["plan": "pro"])

Notibase.track("level_complete", properties: ["level": 3])

Notibase.inbox { items in /* render your notification center */ }
Notibase.inboxMarkRead([itemId])
```

> Test on a real device — the simulator cannot receive APNs pushes. Use the
> *development* APNs environment while running debug builds from Xcode.

## In-app messages

A message shown *inside* your app rather than sent to it. You publish a rule in the
console; the SDK caches it and decides on the device when to show it — on app open, or
when you put a value in front of it. Nobody has to be online when you press save.

```swift
Notibase.enableInAppMessages()            // once, after configure()

// A local fact for rules to test against. Never leaves the device.
Notibase.setTrigger("cart_value", 240)
```

How often somebody sees a message is counted on the device, so an app opened in airplane
mode still knows it showed one yesterday. The cost of that: a reinstall forgets, and two
devices belonging to one person count separately.

The reason to reach for this first: a message with an **Ask for push permission** button
lets you ask inside your app before `UNUserNotificationCenter` does. iOS gives you one
system prompt per install and the only way back is Settings, so a "not now" in your own UI
costs you nothing.

## Support

- Docs: [notibase.dev/ios.html](https://notibase.dev/ios.html)
- Issues & feature requests: [support@notibase.com](mailto:support@notibase.com)
- Security reports: [security@notibase.com](mailto:security@notibase.com)

## License

MIT © Notibase — see [LICENSE](LICENSE).

## Changelog

[CHANGELOG.md](./CHANGELOG.md).

<sub>This repository is a published snapshot of the Notibase SDK, updated
automatically on each release.</sub>
