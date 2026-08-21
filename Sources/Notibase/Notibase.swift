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
 * Quickstart:
 *   Notibase.configure(clientKey: "ck_live_…")
 *   // in AppDelegate:
 *   func application(_ app: UIApplication,
 *       didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
 *     Notibase.setAPNsToken(token)
 *   }
 *   Notibase.identify("user-42", signature: sigFromYourBackend)
 *   Notibase.track("level_complete", properties: ["level": 3])
 */
import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

public enum Notibase {
    private static let queue = DispatchQueue(label: "com.notibase.sdk", qos: .utility)
    private static let defaults = UserDefaults.standard
    private static let deviceIdKey = "nb_device_id"
    private static let tokenKey = "nb_apns_token"

    private static var api: NotibaseAPI?

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

    /// The stored Notibase device id, once registration has succeeded.
    /// Record a notification open. Call from your notification delegate:
    ///
    ///   func userNotificationCenter(_ center: UNUserNotificationCenter,
    ///       didReceive response: UNNotificationResponse,
    ///       withCompletionHandler completion: @escaping () -> Void) {
    ///     Notibase.trackNotificationOpen(userInfo:
    ///         response.notification.request.content.userInfo)
    ///     completion()
    ///   }
    ///
    /// The payload's nb_m / nb_d / nb_o keys are placed there by the
    /// Notibase send pipeline; foreign notifications are ignored safely.
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
    /// Convenience: request notification permission, then register with APNs.
    /// Call from a user gesture (soft-prompt first — see docs/mobile).
    public static func requestAuthorization(_ completion: ((Bool) -> Void)? = nil) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            completion?(granted)
        }
    }
    #endif

    private static func logNotConfigured() {
        NSLog("[Notibase] Notibase.configure(clientKey:) has not been called yet")
    }
}
