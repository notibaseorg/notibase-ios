/**
 * Notibase iOS SDK — public entry point.
 *
 * Design rules (Arch §8.2), identical to the Android SDK:
 *  - ZERO dependencies. Foundation + (on Apple platforms) UserNotifications.
 *  - Never crash the host app: every public call is fire-and-forget with an
 *    optional callback; failures are logged, not thrown across app threads.
 *  - The client key is public by design (ck_…); anything sensitive
 *    (identify signatures) is minted by the app's own backend.
 *
 * Quickstart — two calls at launch, and one line for the token:
 *   Notibase.configure(clientKey: "ck_live_…")
 *   Notibase.registerForPushNotifications()
 *
 *   // in AppDelegate — only your app delegate receives the token:
 *   func application(_ app: UIApplication,
 *       didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
 *     Notibase.setAPNsToken(token)
 *   }
 *
 *   Notibase.identify("user-42", signature: sigFromYourBackend)
 *   Notibase.track("level_complete", properties: ["level": 3])
 *
 * registerForPushNotifications also installs a notification-centre delegate
 * that records opens, wrapping any delegate you already have rather than
 * replacing it.
 */
import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif
#if canImport(UIKit) && !os(watchOS)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public enum Notibase {
    private static let queue = DispatchQueue(label: "com.notibase.sdk", qos: .utility)
    private static let defaults = UserDefaults.standard
    private static let deviceIdKey = "nb_device_id"
    private static let tokenKey = "nb_apns_token"
    /// How often each in-app message has been shown on this device.
    private static let inAppStateKey = "nb_in_app_state"
    /// Cold starts counted on this device, for the session_count trigger.
    private static let inAppSessionsKey = "nb_in_app_sessions"

    private static var api: NotibaseAPI?
    #if canImport(UserNotifications) && !os(Linux)
    /// Strong reference to the delegate we install — see installNotificationDelegate.
    private static var notificationDelegate: NotibaseNotificationCenterDelegate?
    #endif

    /// Initialize once, e.g. in application(_:didFinishLaunchingWithOptions:).
    /// Safe to call again (subsequent calls are no-ops).
    public static func configure(clientKey: String, apiUrl: String = "https://api.notibase.com") {
        if api != nil { return }
        do {
            api = try NotibaseAPI(clientKey: clientKey, apiUrl: apiUrl)
        } catch {
            // Loud, immediate, and impossible to misread — a server key in
            // an app binary must never limp into production silently.
            assertionFailure(String(describing: error))
            NSLog("[Notibase] %@", String(describing: error))
            return
        }
        // A token cached from a previous launch → re-register now.
        if let cached = defaults.string(forKey: tokenKey) {
            registerTokenHex(cached)
        }
        // A device known from a previous launch can report its session now;
        // a brand-new install reports as soon as registration lands.
        reportLifecycle()
    }

    /// Call from didRegisterForRemoteNotificationsWithDeviceToken.
    public static func setAPNsToken(_ token: Data) {
        registerTokenHex(token.map { String(format: "%02x", $0) }.joined())
    }

    /// Hex-string variant (useful from cross-platform layers).
    public static func registerTokenHex(_ tokenHex: String) {
        guard let api = api else { return logNotConfigured() }
        defaults.set(tokenHex, forKey: tokenKey)
        queue.async {
            do {
                let deviceId = try api.registerDevice(
                    apnsTokenHex: tokenHex,
                    locale: Locale.current.identifier,
                    timezone: TimeZone.current.identifier)
                defaults.set(deviceId, forKey: deviceIdKey)
                NSLog("[Notibase] device registered: %@", deviceId)
                reportLifecycle()
            } catch {
                NSLog("[Notibase] device registration failed (will retry on next token refresh): %@",
                      String(describing: error))
            }
        }
    }

    /// Link this device to your user. When identity verification is enabled
    /// (recommended), pass the HMAC signature your backend minted.
    public static func identify(_ externalId: String, signature: String? = nil,
                                attributes: [String: Any] = [:],
                                completion: ((Bool) -> Void)? = nil) {
        guard let api = api else { return logNotConfigured() }
        queue.async {
            do {
                _ = try api.identify(externalId: externalId,
                                     deviceId: defaults.string(forKey: deviceIdKey),
                                     signature: signature, attributes: attributes)
                completion?(true)
            } catch {
                NSLog("[Notibase] identify failed: %@", String(describing: error))
                completion?(false)
            }
        }
    }

    /// Track a custom event (feeds segments + attribution, Arch §7.3).
    public static func track(_ name: String, properties: [String: Any] = [:]) {
        guard let api = api else { return logNotConfigured() }
        queue.async {
            do {
                try api.track(name: name, properties: properties,
                              deviceId: defaults.string(forKey: deviceIdKey))
            } catch {
                NSLog("[Notibase] track(%@) failed: %@", name, String(describing: error))
            }
        }
    }

    /// Record a purchase, with the revenue it earned.
    ///
    /// `purchase` is one of the three reserved event names, and its `value`
    /// is what the attribution report rolls up per campaign. Written out as
    /// a method because "which property does the money go in" is the sort of
    /// thing that gets guessed wrong once and then produces a revenue column
    /// of zeroes nobody can explain.
    ///
    ///   Notibase.trackPurchase(9.99, currency: "USD", productId: "pro_monthly")
    public static func trackPurchase(_ value: Double, currency: String = "USD",
                                     productId: String? = nil,
                                     properties: [String: Any] = [:]) {
        var props = properties
        props["value"] = value
        props["currency"] = currency
        if let productId = productId { props["product_id"] = productId }
        track("purchase", properties: props)
    }

    // MARK: - attribution

    /// Report `install` once and `session_start` on every cold start, so a
    /// campaign link can be credited with the installs it drove (Arch §7.3).
    /// Two events per launch at most. Set it before ``configure``.
    public static var autoTrackSessions: Bool = true

    private static let installKey = "nb_install_reported"
    private static let pendingClickKey = "nb_pending_click"
    /// The last click id acted on, kept forever.
    ///
    /// Separate from ``pendingClickKey``, and the difference is a real bug:
    /// the pending id is deleted as soon as it has been attached to an
    /// event, so de-duplicating against it stopped working at the exact
    /// moment it had done its job. A cold start from a campaign link
    /// delivers the URL twice — `continue userActivity` and the app's own
    /// router both see it — and each repeat reported another session and
    /// re-credited the campaign that produced the install.
    private static let lastClickKey = "nb_last_click"
    private static var sessionReported = false

    /// Hand Notibase a URL that opened your app — a Universal Link, or your
    /// own scheme. If it came from a Notibase campaign link it carries the
    /// click id that makes attribution deterministic rather than a guess from
    /// an IP and a time window.
    ///
    ///   func application(_ app: UIApplication, continue activity: NSUserActivity,
    ///       restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
    ///     Notibase.handleDeepLink(activity.webpageURL)
    ///     return false
    ///   }
    ///
    /// Or, in SwiftUI: `.onOpenURL { Notibase.handleDeepLink($0) }`.
    public static func handleDeepLink(_ url: URL?) {
        guard let click = clickId(from: url) else { return }
        // Against the id kept forever, never the pending one.
        if defaults.string(forKey: lastClickKey) == click { return }
        defaults.set(click, forKey: lastClickKey)
        defaults.set(click, forKey: pendingClickKey)
        // Report now rather than next launch: this is the moment the click id
        // exists, and the server's first-touch guard makes a repeat free.
        reportLifecycle(force: true)
    }

    /// The `nb_click` a Notibase campaign link put on a URL, or nil.
    ///
    /// Only digits are accepted — the value is a bigint primary key on its
    /// way to a parameterised query, and this is the one input a stranger can
    /// drive, since anyone can open the app with any URL they like.
    ///
    /// Public so it can be exercised off a device: a rule that can only be
    /// tested by installing an app is a rule nobody tests.
    public static func clickId(from url: URL?) -> String? {
        guard let url = url,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        for item in items where item.name == "nb_click" {
            guard let v = item.value, !v.isEmpty, v.count <= 19,
                  v.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return v
        }
        return nil
    }

    /// Report the install once, and a session on every cold start.
    ///
    /// A no-op until a device id exists, because an event with no device
    /// cannot be attributed to anything — so it runs again once registration
    /// lands. Calling it twice is cheap and calling it too early is silent,
    /// which is the right way round.
    private static func reportLifecycle(force: Bool = false) {
        guard autoTrackSessions, api != nil else { return }
        guard defaults.string(forKey: deviceIdKey) != nil else { return }

        let click = defaults.string(forKey: pendingClickKey)
        let props: [String: Any] = click.map { ["nb_click": $0] } ?? [:]

        if !defaults.bool(forKey: installKey) {
            defaults.set(true, forKey: installKey)
            track("install", properties: props)
        } else if force || !sessionReported {
            sessionReported = true
            track("session_start", properties: props)
        } else {
            return
        }
        // A click id belongs to the install it produced; keeping it would
        // re-attach it to every session for the life of the install.
        if click != nil { defaults.removeObject(forKey: pendingClickKey) }
    }

    // MARK: - setup test

    /// Check the integration and print what is wrong with it.
    ///
    /// Call it once from a debug build. Everything that usually goes wrong is
    /// invisible from inside the app — credentials that were never uploaded,
    /// an APNs key minted for a different bundle, a device that never
    /// actually registered — so this reports what the app can see and prints
    /// what the server makes of it, as a checklist, in the console.
    ///
    ///   #if DEBUG
    ///   Notibase.runSetupTest()
    ///   #endif
    ///
    /// Pass `completion` to render it yourself — an in-app debug screen, or a
    /// failing XCTest.
    public static func runSetupTest(completion: (([SetupCheck]) -> Void)? = nil) {
        guard let api = api else {
            logNotConfigured()
            completion?([])
            return
        }
        var report: [String: Any] = [
            "platform": "ios",
            "sdk": "notibase-ios",
            "sdk_version": NotibaseAPI.version,
            "has_push_token": defaults.string(forKey: tokenKey) != nil,
            "service_extension": hasNotificationServiceExtension(),
        ]
        if let deviceId = defaults.string(forKey: deviceIdKey) { report["device_id"] = deviceId }
        if let bundleId = Bundle.main.bundleIdentifier { report["bundle_id"] = bundleId }

        let send = {
            queue.async {
                do {
                    let checks = try api.setupTest(report: report)
                    NSLog("[Notibase] ── setup test ──")
                    for c in checks {
                        let mark = c.level == "pass" ? "✔" : (c.level == "warn" ? "!" : "✘")
                        NSLog("[Notibase] %@ %@", mark, c.title)
                        if let detail = c.detail { NSLog("[Notibase]     %@", detail) }
                    }
                    if !checks.contains(where: { $0.level == "fail" }) {
                        NSLog("[Notibase] ── nothing blocking ──")
                    }
                    completion?(checks)
                } catch {
                    // The one failure the server cannot report on: it was
                    // never reached. Say which of the two it was.
                    NSLog("[Notibase] setup test could not reach the API — check the API URL and this device's network: %@",
                          String(describing: error))
                    completion?([])
                }
            }
        }

        #if canImport(UserNotifications) && !os(Linux)
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional: report["push_permission"] = "granted"
            case .denied: report["push_permission"] = "denied"
            case .notDetermined: report["push_permission"] = "not_determined"
            // .ephemeral (App Clips, iOS 14) lands here rather than being
            // named: the package deploys to iOS 13, where the case does not
            // exist to compile against. "unknown" means the server says
            // nothing about permission, which beats guessing.
            @unknown default: report["push_permission"] = "unknown"
            }
            send()
        }
        #else
        send()
        #endif
    }

    /// Whether this app ships a Notification Service Extension.
    ///
    /// Without one, iOS drops images and action buttons from every message —
    /// silently, so a notification that looked right in the composer arrives
    /// plain and nothing reports a problem. Worth telling someone about
    /// before they find out from a customer.
    private static func hasNotificationServiceExtension() -> Bool {
        guard let plugins = Bundle.main.builtInPlugInsURL,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: plugins, includingPropertiesForKeys: nil)
        else { return false }
        for entry in entries where entry.pathExtension == "appex" {
            guard let bundle = Bundle(url: entry),
                  let extensionInfo = bundle.infoDictionary?["NSExtension"] as? [String: Any],
                  let point = extensionInfo["NSExtensionPointIdentifier"] as? String
            else { continue }
            if point == "com.apple.usernotifications.service" { return true }
        }
        return false
    }


    // MARK: - in-app messages

    #if canImport(UIKit) && !os(watchOS)
    private static var inAppEnabled = false
    private static var inAppRules: [InAppRule] = []
    private static var inAppShowing = false
    /// Values the host app has put in front of the SDK for rules to test.
    private static var inAppTriggers: [String: Any] = [:]
    /// Held while a message is on screen, and released when it closes.
    private static var inAppView: NotibaseInAppView?
    private static var foregroundObserver: NSObjectProtocol?

    /// Start showing in-app messages.
    ///
    /// Fetches the rules this device is eligible for and evaluates them now
    /// and on every foreground — which is what "app open" means here, and a
    /// moment no server ever hears about.
    @available(iOS 13.0, *)
    public static func enableInAppMessages() {
        if inAppEnabled { return }
        inAppEnabled = true
        // One per cold start. The trigger this feeds is "how many times has
        // this person been here", and a launch is the closest thing to that
        // question an app can answer without guessing.
        defaults.set(defaults.integer(forKey: inAppSessionsKey) + 1, forKey: inAppSessionsKey)
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { _ in refreshInAppMessages() }
        refreshInAppMessages()
    }

    /// Put a value in front of the SDK for messages to test against.
    ///
    /// `setTrigger("cart_value", 240)` and a campaign configured for
    /// `cart_value over 100` fires on the next evaluation, which happens
    /// here and now. It never leaves the device: a trigger is a local fact,
    /// not an event to report.
    @available(iOS 13.0, *)
    public static func setTrigger(_ key: String, _ value: Any) {
        onMain {
            inAppTriggers[key] = value
            if inAppEnabled { evaluateInAppMessages() }
        }
    }

    public static func removeTrigger(_ key: String) {
        onMain { inAppTriggers.removeValue(forKey: key) }
    }

    public static func clearTriggers() {
        onMain { inAppTriggers.removeAll() }
    }

    @available(iOS 13.0, *)
    private static func refreshInAppMessages() {
        guard let api = api, let deviceId = defaults.string(forKey: deviceIdKey) else { return }
        queue.async {
            do {
                let rules = try api.inAppRules(deviceId: deviceId)
                onMain {
                    inAppRules = rules
                    evaluateInAppMessages()
                }
            } catch {
                // A campaign that does not appear is not worth a log line on
                // every launch of somebody's app.
                NSLog("[Notibase] in-app rules could not be fetched: %@", String(describing: error))
            }
        }
    }

    /// Choose one and draw it, or do nothing. Main thread only.
    @available(iOS 13.0, *)
    private static func evaluateInAppMessages() {
        if inAppShowing { return }
        let memory = InAppMemory(
            load: { defaults.string(forKey: inAppStateKey) },
            save: { defaults.set($0, forKey: inAppStateKey) })
        let now = Date().timeIntervalSince1970 * 1000
        guard let rule = InAppPicker.choose(
            rules: inAppRules, memory: memory, triggers: inAppTriggers,
            sessions: max(1, defaults.integer(forKey: inAppSessionsKey)), now: now)
        else { return }
        guard let scene = activeScene() else { return }

        inAppShowing = true
        // Recorded before it is drawn. Somebody who kills the app the
        // instant a message appears has still seen it.
        memory.record(rule.id, now: now)
        reportInApp(rule.id, "shown", nil)

        let view = NotibaseInAppView(
            rule: rule,
            onAction: { action in
                inAppShowing = false
                inAppView = nil
                runInAppAction(rule.id, action)
            },
            onDismiss: {
                inAppShowing = false
                inAppView = nil
                reportInApp(rule.id, "dismissed", nil)
            })
        inAppView = view
        view.show(in: scene)
    }

    @available(iOS 13.0, *)
    private static func runInAppAction(_ ruleId: String, _ action: InAppAction) {
        reportInApp(ruleId, "clicked", action.kind == "tag_user" ? action.key : nil)
        switch action.kind {
        case "open_url":
            // Through the same guard a tapped notification goes through:
            // file:, javascript:, data: and about: turn data into local
            // capability and are refused there, so they are refused here.
            if let raw = action.url, let url = safeUrl(raw) { onMainOpen(url) }
        case "prompt_push":
            // The reason this feature earns its place. iOS gives an app one
            // permission dialog per install and the only way back is
            // Settings, so the person says yes to the message first and the
            // system is asked after.
            #if canImport(UserNotifications) && !os(Linux)
            registerForPushNotifications()
            #endif
        case "track":
            if let name = action.name { track(name, properties: ["in_app_message": ruleId]) }
        default:
            // tag_user is applied server-side from the campaign's own value,
            // and dismiss has already happened.
            break
        }
    }

    private static func reportInApp(_ id: String, _ event: String, _ tag: String?) {
        guard let api = api, let deviceId = defaults.string(forKey: deviceIdKey) else { return }
        queue.async {
            do { try api.inAppEvent(deviceId: deviceId, id: id, event: event, tag: tag) }
            catch { NSLog("[Notibase] in-app %@ not reported", event) }
        }
    }

    /// The scene a message would be drawn over, or nil if none is in front.
    @available(iOS 13.0, *)
    private static func activeScene() -> UIWindowScene? {
        for scene in UIApplication.shared.connectedScenes
        where scene.activationState == .foregroundActive {
            if let window = scene as? UIWindowScene { return window }
        }
        return nil
    }
    #endif

    /// Fetch the in-app inbox for the identified user behind this device.
    public static func inbox(limit: Int = 50, completion: @escaping ([InboxItem]?) -> Void) {
        guard let api = api else { logNotConfigured(); return completion(nil) }
        guard let deviceId = defaults.string(forKey: deviceIdKey) else { return completion(nil) }
        queue.async {
            do { completion(try api.inboxList(deviceId: deviceId, limit: limit)) }
            catch {
                NSLog("[Notibase] inbox fetch failed: %@", String(describing: error))
                completion(nil)
            }
        }
    }

    /// Mark inbox items read.
    public static func inboxMarkRead(_ ids: [String]) {
        guard let api = api, let deviceId = defaults.string(forKey: deviceIdKey) else { return }
        queue.async {
            do { try api.inboxMarkRead(deviceId: deviceId, ids: ids) }
            catch { NSLog("[Notibase] markRead failed: %@", String(describing: error)) }
        }
    }

    // MARK: - notification destinations

    /// Open the notification's `url` when one is tapped. On by default —
    /// a message composed with a URL should go there, the way it does on the
    /// web and on Android.
    ///
    /// Set it to `false` if you route every destination yourself and would
    /// rather Notibase never called `UIApplication.open`.
    public static var openNotificationUrls: Bool = true
    /// Handle notification destinations yourself — for in-app routing, a
    /// navigation stack, or a custom scheme your app resolves internally.
    ///
    /// Return `true` to say you handled it; Notibase then does nothing more.
    /// Return `false` (or leave this nil) and the URL is opened normally.
    ///
    ///   Notibase.notificationUrlHandler = { url in
    ///     guard url.host == "myapp.example" else { return false }
    ///     Router.shared.go(to: url)
    ///     return true
    ///   }
    public static var notificationUrlHandler: ((URL) -> Bool)?

    /// The destination a tap should go to: the tapped button's url when it has
    /// one, else the notification's.
    ///
    /// `actionId` is `UNNotificationResponse.actionIdentifier`, or nil for a
    /// tap on the notification body.
    ///
    /// Public so an app that keeps its own delegate can resolve a
    /// destination the same way the installed one does, rather than
    /// re-deriving the button-outranks-notification rule by hand.
    public static func destination(userInfo: [AnyHashable: Any], actionId: String?) -> URL? {
        var raw = userInfo["url"] as? String
        // A button that carries its own url outranks the notification's — the
        // whole point of "Read more" beside "Dismiss" is two destinations.
        if let actionId = actionId, let buttons = userInfo["nb_buttons"] as? [[String: Any]] {
            for b in buttons where (b["id"] as? String) == actionId {
                if let u = b["url"] as? String, !u.isEmpty { raw = u }
            }
        }
        guard let raw = raw else { return nil }
        return safeUrl(raw)
    }

    /**
     * A URL we are willing to hand to the system, or nil.
     *
     * Extracted when in-app messages grew a second caller: a message's
     * button destination is written in a console and a notification's is
     * written in a payload, and both are data rather than code. The rule
     * only works if it has one implementation — the day it has two, one of
     * them is the one nobody updated.
     */
    static func safeUrl(_ raw: String) -> URL? {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else { return nil }
        // Refuse the schemes that turn data into local capability.
        if ["file", "javascript", "data", "about"].contains(scheme) { return nil }
        return url
    }

    /// Send a tapped notification to its destination.
    ///
    /// ``installNotificationDelegate(showWhileForegrounded:)`` calls this;
    /// call it yourself only if you keep your own delegate.
    public static func openNotificationUrl(userInfo: [AnyHashable: Any], actionId: String? = nil) {
        guard let url = destination(userInfo: userInfo, actionId: actionId) else { return }
        if notificationUrlHandler?(url) == true { return }
        guard openNotificationUrls else { return }
        onMainOpen(url)
    }

    #if canImport(UIKit) && !os(watchOS)
    private static func onMainOpen(_ url: URL) {
        onMain { UIApplication.shared.open(url, options: [:], completionHandler: nil) }
    }
    #elseif canImport(AppKit)
    private static func onMainOpen(_ url: URL) {
        onMain { NSWorkspace.shared.open(url) }
    }
    #else
    private static func onMainOpen(_ url: URL) {
        NSLog("[Notibase] no way to open %@ on this platform — set Notibase.notificationUrlHandler",
              url.absoluteString)
    }
    #endif

    /// The stored Notibase device id, once registration has succeeded.
    /// Record a notification open.
    ///
    /// ``installNotificationDelegate(showWhileForegrounded:)`` calls this for
    /// you — reach for it directly only if you keep your own delegate and
    /// would rather not have ours wrap it.
    ///
    /// The payload's nb_m / nb_d / nb_o keys are placed there by the Notibase
    /// send pipeline; foreign notifications are ignored safely, so it is
    /// harmless to pass every notification your app receives.
    public static func trackNotificationOpen(userInfo: [AnyHashable: Any]) {
        guard let m = userInfo["nb_m"] as? String,
              let d = userInfo["nb_d"] as? String,
              let o = userInfo["nb_o"] as? String else { return }
        NotibaseAPI.postClick(origin: o, messageId: m, deviceId: d)
    }

    public static func deviceId() -> String? {
        defaults.string(forKey: deviceIdKey)
    }

    #if canImport(UserNotifications) && !os(Linux)
    /// Ask for notification permission. Call it from a user gesture, after a
    /// soft prompt of your own — iOS only lets you ask once.
    ///
    /// Prefer ``registerForPushNotifications(showWhileForegrounded:completion:)``,
    /// which does this and the two steps that have to follow it.
    public static func requestAuthorization(_ completion: ((Bool) -> Void)? = nil) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            completion?(granted)
        }
    }

    /// Record notification opens without writing a delegate.
    ///
    /// Wraps whatever delegate is already installed rather than replacing it,
    /// so an app with its own handling keeps all of it. Call this before the
    /// app finishes launching — a tap that cold-starts the app is delivered
    /// very soon after, and a delegate installed later misses it.
    ///
    /// ``registerForPushNotifications(showWhileForegrounded:completion:)``
    /// calls this for you; reach for it directly when you register with APNs
    /// yourself and only want the click tracking.
    public static func installNotificationDelegate(showWhileForegrounded: Bool = true) {
        onMain {
            let center = UNUserNotificationCenter.current()
            // Wrapping ourselves would build a chain that grows on every call
            // and forwards each open more than once.
            if center.delegate is NotibaseNotificationCenterDelegate { return }
            let proxy = NotibaseNotificationCenterDelegate(
                next: center.delegate, showWhileForegrounded: showWhileForegrounded)
            // Held here because `center.delegate` is weak: assigning a proxy
            // nothing else owns deallocates it immediately, and the app loses
            // notification handling with no error anywhere.
            notificationDelegate = proxy
            center.delegate = proxy
        }
    }

    /// Permission, APNs registration and open tracking in one call.
    ///
    /// The APNs token itself still arrives in your app delegate, because only
    /// your app delegate receives it — forward that one line:
    ///
    ///   func application(_ app: UIApplication,
    ///       didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
    ///     Notibase.setAPNsToken(token)
    ///   }
    ///
    /// [completion] reports whether the user granted permission.
    public static func registerForPushNotifications(
        showWhileForegrounded: Bool = true,
        completion: ((Bool) -> Void)? = nil
    ) {
        installNotificationDelegate(showWhileForegrounded: showWhileForegrounded)
        requestAuthorization { granted in
            guard granted else {
                completion?(false)
                return
            }
            onMain {
                #if canImport(UIKit) && !os(watchOS)
                UIApplication.shared.registerForRemoteNotifications()
                #elseif canImport(AppKit)
                NSApplication.shared.registerForRemoteNotifications()
                #else
                NSLog("[Notibase] no APNs registration on this platform — call setAPNsToken yourself")
                #endif
                completion?(true)
            }
        }
    }

    #endif

    /// UIKit and the notification centre both expect main-thread access, and
    /// `requestAuthorization` answers on an arbitrary queue.
    private static func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    private static func logNotConfigured() {
        NSLog("[Notibase] Notibase.configure(clientKey:) has not been called yet")
    }
}
