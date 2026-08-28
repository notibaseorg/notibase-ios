/**
 * Automatic notification-open tracking.
 *
 * Every app used to write the same UNUserNotificationCenterDelegate method
 * just to call `Notibase.trackNotificationOpen`. Apps that already had a
 * delegate had to remember to add one line to it; apps that did not had to
 * create one, which meant most of them simply had no click data and no
 * indication that anything was missing.
 *
 * This installs a delegate that records the open and then forwards every
 * callback to whatever delegate was already there, so adding it cannot take
 * behaviour away from an app that had its own.
 *
 * Three details in here are load-bearing rather than incidental:
 *
 *  - `UNUserNotificationCenter.delegate` is a WEAK property. A proxy created
 *    and assigned in one expression is deallocated immediately and the app
 *    silently loses notification handling entirely. Notibase holds it.
 *  - The delegate we replace is held STRONG. It is often the AppDelegate,
 *    which the system retains anyway, but it can be a standalone object whose
 *    only owner was the notification centre — and dropping that would break
 *    the host app's own handling.
 *  - A completion handler must be called exactly once. If the previous
 *    delegate implements the method it owns the handler; if it does not, we
 *    call it. Getting this wrong either hangs the notification or crashes.
 */
#if canImport(UserNotifications) && !os(Linux)
import Foundation
import UserNotifications

public final class NotibaseNotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate {
    /// Deliberately strong — see the note above.
    private let next: UNUserNotificationCenterDelegate?
    private let showWhileForegrounded: Bool

    internal init(next: UNUserNotificationCenterDelegate?, showWhileForegrounded: Bool) {
        self.next = next
        self.showWhileForegrounded = showWhileForegrounded
        super.init()
    }

    /// The user tapped the notification, or one of its action buttons.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        Notibase.trackNotificationOpen(userInfo: userInfo)

        // A dismissal is not a destination. Everything else — the body, and
        // every action button — is a tap the person expects to go somewhere.
        if response.actionIdentifier != UNNotificationDismissActionIdentifier {
            let action = response.actionIdentifier == UNNotificationDefaultActionIdentifier
                ? nil : response.actionIdentifier
            Notibase.openNotificationUrl(userInfo: userInfo, actionId: action)
        }

        // Optional protocol requirement: the call returns nil when the next
        // delegate does not implement it, which is exactly how we know whether
        // the completion handler has been handed on or is still ours to call.
        let forwarded: Void? = next?.userNotificationCenter?(
            center, didReceive: response, withCompletionHandler: completionHandler)
        if forwarded == nil { completionHandler() }
    }

    /// A notification arrived while the app was in the foreground.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let forwarded: Void? = next?.userNotificationCenter?(
            center, willPresent: notification, withCompletionHandler: completionHandler)
        if forwarded != nil { return }

        // iOS shows nothing for a foreground notification unless a delegate
        // asks it to. Apps are nearly always surprised by that, so the default
        // is to show it — and `showWhileForegrounded: false` opts out.
        guard showWhileForegrounded else { return completionHandler([]) }
        if #available(iOS 14.0, macOS 11.0, tvOS 14.0, watchOS 7.0, *) {
            completionHandler([.banner, .list, .sound])
        } else {
            completionHandler([.alert, .sound])
        }
    }

    /// Forwarded so an app that shows notification settings in-app keeps
    /// working. The method is optional, so doing nothing when the previous
    /// delegate did not implement it is the correct behaviour.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        openSettingsFor notification: UNNotification?
    ) {
        next?.userNotificationCenter?(center, openSettingsFor: notification)
    }
}
#endif
