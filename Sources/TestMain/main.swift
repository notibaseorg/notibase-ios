/**
 * Linux/macOS e2e for the iOS SDK core — run by apps/api/scripts/
 * e2e-ios-core.mjs against the REAL Notibase API (buildServer on PGlite).
 * Mirrors the Android TestMain: hard assertions, exit non-zero on failure.
 */
import Foundation
import Crypto
import Notibase
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

func check(_ cond: Bool, _ label: String) {
    if cond { print("  ✔ \(label)") }
    else { FileHandle.standardError.write("  ✘ \(label)\n".data(using: .utf8)!); exit(1) }
}

func env(_ name: String) -> String {
    guard let v = ProcessInfo.processInfo.environment[name] else {
        FileHandle.standardError.write("missing env \(name)\n".data(using: .utf8)!); exit(2)
    }
    return v
}

func hmacHex(secret: String, data: String) -> String {
    let mac = HMAC<SHA256>.authenticationCode(
        for: Data(data.utf8), using: SymmetricKey(data: Data(secret.utf8)))
    return mac.map { String(format: "%02x", $0) }.joined()
}

/// Raw sk_ call — TestMain doubles as "your backend" for the send step.
func serverPost(apiUrl: String, serverKey: String, path: String, json: [String: Any]) -> [String: Any] {
    var req = URLRequest(url: URL(string: apiUrl + path)!)
    req.httpMethod = "POST"
    req.setValue("Bearer \(serverKey)", forHTTPHeaderField: "authorization")
    req.setValue("application/json", forHTTPHeaderField: "content-type")
    req.httpBody = try! JSONSerialization.data(withJSONObject: json)
    let sem = DispatchSemaphore(value: 0)
    var out: [String: Any] = [:]
    var status = 0
    URLSession.shared.dataTask(with: req) { data, response, _ in
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let d = data, let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] { out = o }
        sem.signal()
    }.resume()
    sem.wait()
    check(status < 400, "server POST \(path) → \(status)")
    return out
}

let apiUrl = env("NB_API_URL")
let clientKey = env("NB_CLIENT_KEY")
let serverKey = env("NB_SERVER_KEY")
let identifySecret = env("NB_IDENTIFY_SECRET")

print("[swift] key hygiene")
do {
    _ = try NotibaseAPI(clientKey: "sk_live_oops")
    check(false, "sk_ key must be refused")
} catch let e as NotibaseError {
    check(String(describing: e).contains("SERVER key"), "sk_ key refused with teaching error")
} catch { check(false, "wrong error type for sk_ key") }
do {
    _ = try NotibaseAPI(clientKey: "random")
    check(false, "non-ck key must be refused")
} catch { check(true, "non-ck key refused") }

let badApi = try! NotibaseAPI(clientKey: "ck_live_definitely_not_valid_0000000000", apiUrl: apiUrl)
do {
    _ = try badApi.registerDevice(apnsTokenHex: "deadbeef", locale: nil, timezone: nil)
    check(false, "invalid ck key must 401")
} catch let e as NotibaseError {
    if case .api(let status, _) = e { check(status == 401, "invalid ck key → 401") }
    else { check(false, "expected api error, got \(e)") }
} catch { check(false, "unexpected error type") }

print("[swift] device registration")
let api = try! NotibaseAPI(clientKey: clientKey, apiUrl: apiUrl)
let tokenHex = "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90"
let deviceId = try! api.registerDevice(apnsTokenHex: tokenHex, locale: "en_US", timezone: "Asia/Kathmandu")
check(deviceId.count == 36, "device id is a uuid: \(deviceId)")
let deviceId2 = try! api.registerDevice(apnsTokenHex: tokenHex, locale: nil, timezone: nil)
check(deviceId2 == deviceId, "re-registering same token is idempotent")

print("[swift] identify — HMAC verification enforced")
let externalId = "ios-user-1"
do {
    _ = try api.identify(externalId: externalId, deviceId: deviceId, signature: nil, attributes: [:])
    check(false, "unsigned identify must 403")
} catch let e as NotibaseError {
    if case .api(let status, _) = e { check(status == 403, "identify without signature → 403") }
    else { check(false, "expected api error") }
} catch { check(false, "unexpected error type") }
do {
    _ = try api.identify(externalId: externalId, deviceId: deviceId,
                         signature: hmacHex(secret: "wrong-secret", data: externalId), attributes: [:])
    check(false, "forged signature must 403")
} catch let e as NotibaseError {
    if case .api(let status, _) = e { check(status == 403, "forged signature → 403") }
    else { check(false, "expected api error") }
} catch { check(false, "unexpected error type") }
let userId = try! api.identify(externalId: externalId, deviceId: deviceId,
                               signature: hmacHex(secret: identifySecret, data: externalId),
                               attributes: ["tier": "gold"])
check(userId.count == 36, "signed identify → user id")

print("[swift] track")
try! api.track(name: "session_start", properties: [:], deviceId: deviceId)
try! api.track(name: "level_complete", properties: ["level": 3, "boss": true], deviceId: deviceId)

print("[swift] send → inbox → markRead (full loop)")
_ = serverPost(apiUrl: apiUrl, serverKey: serverKey, path: "/v1/messages", json: [
    "audience": ["all": true],
    "content": [
        "title": "Hello iOS",
        "inapp": ["title": "Hello iOS", "body": "from the e2e", "url": "https://notibase.com"],
    ],
])
var items: [InboxItem] = []
for _ in 1...25 {
    items = try! api.inboxList(deviceId: deviceId)
    if !items.isEmpty { break }
    Thread.sleep(forTimeInterval: 0.2)
}
check(items.count == 1, "inbox has the inapp message")
check(items[0].content["title"] as? String == "Hello iOS", "inbox content title intact")
check(items[0].readAt == nil, "item starts unread")
try! api.inboxMarkRead(deviceId: deviceId, ids: [items[0].id])
let after = try! api.inboxList(deviceId: deviceId)
check(after[0].readAt != nil, "markRead reflected on next list")

print("[swift] ALL PASSED")
