/**
 * NotibaseAPI — pure-Foundation HTTP core (no UIKit, no dependencies).
 *
 * This file is deliberately platform-neutral: the SAME code that ships in
 * apps is compiled and e2e-tested against the real Notibase API on Linux
 * CI before every release (mirrors the Android SDK's harness).
 *
 * Security model (Arch §5.3): carries a ck_ ("client") key — public by
 * design. It can register devices, identify with an HMAC signature minted
 * by YOUR backend, track events, and read this device's inbox. Server
 * keys (sk_) are refused at init so nobody ships one inside an IPA.
 */
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum NotibaseError: Error, CustomStringConvertible {
    case invalidKey(String)
    case api(status: Int, message: String)
    case network(String)
    case badResponse(String)

    public var description: String {
        switch self {
        case .invalidKey(let m): return "NotibaseError.invalidKey: \(m)"
        case .api(let status, let message): return "NotibaseError.api(\(status)): \(message)"
        case .network(let m): return "NotibaseError.network: \(m)"
        case .badResponse(let m): return "NotibaseError.badResponse: \(m)"
        }
    }
}

public struct InboxItem {
    public let id: String
    public let content: [String: Any]
    public let readAt: String?
    public let createdAt: String
}

public final class NotibaseAPI {
    public static let version = "0.2.0"

    private let key: String
    private let apiUrl: String
    private let session: URLSession
    private let maxRetries = 2

    public init(clientKey: String, apiUrl: String = "https://api.notibase.com") throws {
        if clientKey.hasPrefix("sk_") {
            throw NotibaseError.invalidKey(
                "You passed a SERVER key (sk_…) to the iOS SDK. Server keys grant full "
                + "account access and must never ship inside an app — use your client "
                + "key (ck_…) from the Notibase dashboard instead.")
        }
        guard clientKey.hasPrefix("ck_") else {
            throw NotibaseError.invalidKey("Notibase client keys start with ck_")
        }
        self.key = clientKey
        self.apiUrl = apiUrl
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }

    /// POST /v1/devices → device id. Idempotent server-side per (app, token).
    public func registerDevice(apnsTokenHex: String, locale: String?, timezone: String?) throws -> String {
        var body: [String: Any] = ["platform": "ios", "token": apnsTokenHex]
        if let locale = locale { body["locale"] = locale }
        if let timezone = timezone { body["timezone"] = timezone }
        let res = try request(method: "POST", path: "/v1/devices", body: body)
        guard let id = res["id"] as? String else {
            throw NotibaseError.badResponse("no device id in response")
        }
        return id
    }

    /// POST /v1/identify → user id. `signature` = hex(hmac_sha256(identify_secret,
    /// externalId)), minted by YOUR backend — never computed in the app.
    public func identify(externalId: String, deviceId: String?,
                         signature: String?, attributes: [String: Any]) throws -> String {
        var body: [String: Any] = ["external_id": externalId, "attributes": attributes]
        if let deviceId = deviceId { body["device_id"] = deviceId }
        if let signature = signature { body["signature"] = signature }
        let res = try request(method: "POST", path: "/v1/identify", body: body)
        guard let id = res["id"] as? String else {
            throw NotibaseError.badResponse("no user id in response")
        }
        return id
    }

    /// POST /v1/events. Reserved names (install, session_start, purchase) feed attribution.
    public func track(name: String, properties: [String: Any], deviceId: String?) throws {
        var body: [String: Any] = ["name": name, "properties": properties]
        if let deviceId = deviceId { body["device_id"] = deviceId }
        _ = try request(method: "POST", path: "/v1/events", body: body)
    }

    /// GET /v1/inbox — messages for the identified user behind this device.
    public func inboxList(deviceId: String, limit: Int = 50) throws -> [InboxItem] {
        var comps = URLComponents(string: apiUrl + "/v1/inbox")!
        comps.queryItems = [
            URLQueryItem(name: "device_id", value: deviceId),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        let res = try request(method: "GET", url: comps.url!, body: nil)
        let items = res["items"] as? [[String: Any]] ?? []
        return items.compactMap { m in
            guard let id = m["id"] as? String else { return nil }
            return InboxItem(
                id: id,
                content: m["content"] as? [String: Any] ?? [:],
                readAt: m["read_at"] as? String,
                createdAt: m["created_at"] as? String ?? "")
        }
    }

    /// POST /v1/inbox/read — mark items read.
    public func inboxMarkRead(deviceId: String, ids: [String]) throws {
        if ids.isEmpty { return }
        _ = try request(method: "POST", path: "/v1/inbox/read",
                        body: ["device_id": deviceId, "ids": ids])
    }

    // ── plumbing ────────────────────────────────────────────
    /// Notification-click beacon — unauthenticated by design (the server only
    /// counts pairs it delivered, once). Fire-and-forget: never throws, never
    /// blocks a notification tap.
    public static func postClick(origin: String, messageId: String, deviceId: String) {
        guard let url = URL(string: "\(origin)/v1/push/click") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 5
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("notibase-ios/\(version)", forHTTPHeaderField: "user-agent")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["m": messageId, "d": deviceId])
        URLSession.shared.dataTask(with: req).resume()
    }

    private func request(method: String, path: String, body: [String: Any]?) throws -> [String: Any] {
        guard let url = URL(string: apiUrl + path) else {
            throw NotibaseError.network("bad url \(apiUrl + path)")
        }
        return try request(method: method, url: url, body: body)
    }

    private func request(method: String, url: URL, body: [String: Any]?) throws -> [String: Any] {
        var lastError: NotibaseError = .network("request failed")
        for attempt in 0...maxRetries {
            if attempt > 0 {
                // 500ms, 2s — jittered; the SDK must never hammer a struggling API.
                let base = 0.5 * pow(4.0, Double(attempt - 1))
                Thread.sleep(forTimeInterval: base + Double.random(in: 0...(base * 0.25)))
            }
            do {
                return try requestOnce(method: method, url: url, body: body)
            } catch let err as NotibaseError {
                switch err {
                case .api(let status, _) where status == 429 || status >= 500:
                    lastError = err // retry what retrying can fix
                case .network:
                    lastError = err
                default:
                    throw err // 4xx are ours — never retried
                }
            }
        }
        throw lastError
    }

    private func requestOnce(method: String, url: URL, body: [String: Any]?) throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        req.setValue("notibase-ios/\(Self.version)", forHTTPHeaderField: "user-agent")
        if let body = body {
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        // Synchronous by design: callers run on the SDK's background queue
        // (Notibase.swift), and iOS 13 support rules out async URLSession.
        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultResponse: HTTPURLResponse?
        var resultError: Error?
        let task = session.dataTask(with: req) { data, response, error in
            resultData = data
            resultResponse = response as? HTTPURLResponse
            resultError = error
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        if let error = resultError {
            throw NotibaseError.network(String(describing: error))
        }
        guard let http = resultResponse else {
            throw NotibaseError.network("no response")
        }
        let data = resultData ?? Data()
        if http.statusCode >= 400 {
            var message = String(data: data.prefix(200), encoding: .utf8) ?? ""
            if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let err = obj["error"] as? String {
                message = err
            }
            throw NotibaseError.api(status: http.statusCode, message: message)
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return [:]
        }
        return obj
    }
}
