/**
 * Notibase Notification Service Extension.
 *
 * Two things iOS refuses to do from a push payload alone, and both need an
 * extension running between APNs and the notification being shown:
 *
 *   1. ATTACHMENTS. An image must be downloaded to a local file first. The
 *      send pipeline already sets `mutable-content: 1` whenever a message
 *      carries media, which is what wakes this extension — but without an
 *      extension in the app, that flag does nothing and the image silently
 *      never appears.
 *
 *   2. ACTION BUTTONS. iOS cannot declare buttons in a payload. It draws the
 *      actions of a *category* the app registered ahead of time — which is
 *      useless for buttons composed after the app shipped. The way out is to
 *      register the category here, at delivery time, from `nb_buttons`, and
 *      point the notification at it. The extension and the app share one
 *      notification centre, so a category registered here is live by the time
 *      the notification is presented.
 *
 * Add it once, in Xcode:
 *   File → New → Target → Notification Service Extension
 *   Add the `NotibaseNotificationService` product to that target
 *   Replace the generated class with:
 *
 *       import NotibaseNotificationService
 *       class NotificationService: NotibaseNotificationService {}
 *
 * Nothing else. Subclass and override `didReceive` only if you need to modify
 * the content yourself — call `super` and you keep media and buttons.
 */

#if canImport(UserNotifications)

import Foundation
import UserNotifications

open class NotibaseNotificationService: UNNotificationServiceExtension {

    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?

    override open func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        self.bestAttempt = content

        let info = content.userInfo
        let group = DispatchGroup()
        // The two pieces of work below finish on different queues and both
        // mutate `content`. One serial queue for every write keeps that from
        // being a data race that only shows up on a slow network.
        let edits = DispatchQueue(label: "com.notibase.nse.edits")

        // ── action buttons ────────────────────────────────────────────
        // Skipped when the payload names a category of its own: the app
        // registered that one deliberately and overriding it would replace
        // buttons the developer wrote with buttons the composer guessed.
        if content.categoryIdentifier.isEmpty,
           let buttons = Self.parseButtons(info["nb_buttons"]), !buttons.isEmpty {
            group.enter()
            Self.registerCategory(for: buttons) { identifier in
                edits.async {
                    content.categoryIdentifier = identifier
                    group.leave()
                }
            }
        }

        // ── media attachment ──────────────────────────────────────────
        if let media = info["nb_media"] as? String, let url = URL(string: media) {
            group.enter()
            Self.attach(url) { attachment in
                edits.async {
                    if let attachment = attachment { content.attachments = [attachment] }
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) { contentHandler(content) }
    }

    /**
     * iOS gives an extension roughly 30 seconds and then takes the
     * notification back. Delivering what we have beats delivering nothing:
     * a notification with no image is a minor disappointment, a notification
     * that never arrives is a bug report.
     */
    override open func serviceExtensionTimeWillExpire() {
        if let handler = contentHandler, let content = bestAttempt {
            handler(content)
        }
    }

    // MARK: - buttons

    public struct Button {
        public let id: String
        public let text: String
    }

    /** `nb_buttons` arrives as a real JSON array — APNs payloads are JSON, so
     *  unlike FCM there is no string encoding to undo. */
    static func parseButtons(_ raw: Any?) -> [Button]? {
        guard let items = raw as? [[String: Any]] else { return nil }
        let buttons: [Button] = items.compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty,
                  let text = item["text"] as? String, !text.isEmpty else { return nil }
            return Button(id: id, text: text)
        }
        // iOS shows a couple of buttons inline and the rest on a long press,
        // so there is no hard cap worth enforcing here.
        return buttons
    }

    /**
     * Categories are keyed by identity, not by name: two messages with the
     * same buttons must reuse one category, or every send would add another
     * and the set would grow without bound for the life of the install.
     */
    static func categoryIdentifier(for buttons: [Button]) -> String {
        // Deliberately NOT String.hashValue: Swift seeds that per process, so
        // the identifier would change on every launch and the app would
        // accumulate a new category for the same buttons forever. FNV-1a is
        // boring, stable, and good enough to key a category on.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in buttons.map({ "\($0.id)=\($0.text)" }).joined(separator: "|").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return "nb_" + String(hash, radix: 36)
    }

    static func registerCategory(for buttons: [Button], completion: @escaping (String) -> Void) {
        let identifier = categoryIdentifier(for: buttons)
        let actions = buttons.map {
            UNNotificationAction(identifier: $0.id, title: $0.text, options: [.foreground])
        }
        let category = UNNotificationCategory(
            identifier: identifier, actions: actions,
            intentIdentifiers: [], options: [.customDismissAction]
        )
        let centre = UNUserNotificationCenter.current()
        // Read-modify-write: setNotificationCategories REPLACES the whole set,
        // so writing ours directly would delete every category the app
        // registered at launch — including the ones its own code depends on.
        centre.getNotificationCategories { existing in
            var merged = existing.filter { $0.identifier != identifier }
            merged.insert(category)
            centre.setNotificationCategories(merged)
            completion(identifier)
        }
    }

    // MARK: - media

    static func attach(_ url: URL, completion: @escaping (UNNotificationAttachment?) -> Void) {
        let task = URLSession.shared.downloadTask(with: url) { temp, response, _ in
            guard let temp = temp else { return completion(nil) }
            // The downloaded file has no extension, and UNNotificationAttachment
            // decides the type from one — so an image with no suffix is dropped
            // without a word. Take it from the URL, then the MIME type.
            let ext = Self.fileExtension(url: url, response: response)
            let dest = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(UUID().uuidString + ext)
            do {
                try FileManager.default.moveItem(at: temp, to: dest)
                completion(try UNNotificationAttachment(identifier: "nb_media", url: dest, options: nil))
            } catch {
                completion(nil)
            }
        }
        task.resume()
    }

    static func fileExtension(url: URL, response: URLResponse?) -> String {
        let fromPath = url.pathExtension
        if !fromPath.isEmpty { return "." + fromPath }
        let type = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if type.contains("png") { return ".png" }
        if type.contains("gif") { return ".gif" }
        if type.contains("mp4") || type.contains("mpeg") { return ".mp4" }
        return ".jpg"
    }
}

#endif
