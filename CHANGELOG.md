# Changelog — NotibaseSDK (iOS)

Two of six SDKs had no release notes at all, and this was one of them.
The three mobile SDKs share a single version number, so the entries below
are reconstructed from the commits and correspond one-to-one with the
same versions in `packages/sdk-flutter/CHANGELOG.md` and
`packages/sdk-android/CHANGELOG.md` — where a release changed nothing on
this platform, it says so rather than being absent.

## 0.6.3

- **The same deep link is acted on once, however often it arrives.** A
  cold start from a campaign link delivers the URL twice on iOS — the
  launch options and the notification response both produce it — and the
  guard against that was checking `pendingClickKey`
  (`Notibase.swift:177`), which `:228` removes as soon as its id has been
  used. So the guard stopped working at exactly the moment it had done
  its job: each repeat reported another `session_start` and re-credited
  the campaign that produced the install. A campaign could be credited
  three times for one install.

  The id last acted on is now kept in a separate key that is never
  cleared, which is the fix Flutter shipped in 0.6.2 and Android shipped
  alongside this one.

## 0.6.2

No change on iOS. Published to keep the three mobile SDKs on one version;
the deep-link fix above landed in Flutter first.

## 0.6.1

- Documentation and packaging only.

## 0.6.0

- **In-app messages.** `Notibase.enableInAppMessages()` fetches the rules
  this device is eligible for, caches them, and evaluates them on the
  device — on every foreground and whenever your app calls
  `Notibase.setTrigger(_:value:)`. A message still fires for somebody who
  was offline when it was published.

  The three checks that decide whether a message shows run here because
  no server can make them honestly: has the trigger fired, has this
  person seen it enough times, has the gap between displays elapsed.
  Counts are per install — a reinstall forgets, and two devices belonging
  to one person count separately.

  Messages are drawn with UIKit. There is no WKWebView and nothing in a
  message can become code running in your app.
- A message can carry an **Ask for push permission** button. iOS gives an
  app one system prompt per install and a decline is close to permanent,
  so asking in your own UI first makes a "no" free.
- `Notibase.setTrigger` / `removeTrigger` / `clearTriggers`. A trigger is
  a local fact for messages to test against and never leaves the device.
  Values are not coerced across types: the string `"240"` does not
  satisfy a rule configured for `over 100`.

## 0.5.1

- No change on iOS. The 0.5.1 fixes were Flutter's: `configure()` waiting
  on the network, and a notification tap awaiting its click beacon before
  opening. This SDK already handed both to a background queue and
  returned.

## 0.5.0

- **Setup test.** `Notibase.runSetupTest()` asks the server what it can
  see — whether an APNs key exists, whether it was issued for this bundle
  id, whether the device this app thinks it registered is one the server
  has. None of that is knowable from inside the app, which is the shape
  every integration problem takes.

## 0.4.0

- **Rich notifications render.** The notification service extension
  downloads and attaches `nb_image`, and `nb_buttons` become
  `UNNotificationAction`s on a category registered at launch. Without the
  extension an image cannot be attached at all — the docs say so now
  rather than implying it happens by magic.

## 0.3.0

- **Attribution.** A tapped campaign link carries `nb_click` through the
  install, and `install` / `session_start` events report it, so an
  install can be credited to the link that produced it.

## 0.2.0

- **A tapped notification opens its destination.** The URL travels in the
  payload and the delegate opens it, on every platform.

## 0.1.0

- First release. Device registration, APNs token handling, click tracking
  and custom events. Foundation only, zero dependencies.
