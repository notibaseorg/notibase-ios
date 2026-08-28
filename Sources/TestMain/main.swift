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

// ── pure decisions, exercised where a device is not needed ────────────
// Both of these run on paths a stranger can drive: anyone can open the app
// with any URL, and a push payload arrives from the network.
print("[swift] deep-link click ids")
func url(_ s: String) -> URL? { URL(string: s) }
check(Notibase.clickId(from: url("https://darlivo.test/launch?nb_click=1742")) == "1742",
      "reads the click id")
check(Notibase.clickId(from: url("darlivo://open?utm_source=x&nb_click=9&z=1")) == "9",
      "finds it among other parameters")
check(Notibase.clickId(from: url("https://x.test/a?NB_CLICK=9")) == nil,
      "the parameter name is exact, not fuzzy")
check(Notibase.clickId(from: url("https://x.test/a#nb_click=9")) == nil,
      "a fragment is not a query string")
check(Notibase.clickId(from: url("https://x.test/a")) == nil, "no query, no click id")
check(Notibase.clickId(from: nil) == nil, "no url, no click id")
check(Notibase.clickId(from: url("https://x.test/a?nb_click=")) == nil, "an empty value is not an id")
check(Notibase.clickId(from: url("https://x.test/a?nb_click=abc")) == nil,
      "a click id is digits or it is nothing")
check(Notibase.clickId(from: url("https://x.test/a?nb_click=-1")) == nil, "not even a negative one")

print("[swift] notification destinations")
let plain: [AnyHashable: Any] = ["url": "https://darlivo.test/drop/9"]
check(Notibase.destination(userInfo: plain, actionId: nil)?.absoluteString
        == "https://darlivo.test/drop/9", "the notification's url")
let withButtons: [AnyHashable: Any] = [
    "url": "https://darlivo.test/drop/9",
    "nb_buttons": [["id": "more", "text": "Read more", "url": "https://darlivo.test/blog/9"],
                   ["id": "later", "text": "Later"]],
]
check(Notibase.destination(userInfo: withButtons, actionId: "more")?.absoluteString
        == "https://darlivo.test/blog/9", "a button's own url outranks the notification's")
check(Notibase.destination(userInfo: withButtons, actionId: "later")?.absoluteString
        == "https://darlivo.test/drop/9", "a button without one falls back")
check(Notibase.destination(userInfo: ["url": "file:///etc/passwd"], actionId: nil) == nil,
      "file: would read local storage with the host app's permissions")
check(Notibase.destination(userInfo: ["url": "javascript:alert(1)"], actionId: nil) == nil,
      "javascript: is not a destination")
check(Notibase.destination(userInfo: ["title": "no url here"], actionId: nil) == nil,
      "no url, nowhere to go")


// ── in-app messages: the three decisions the device owns ──────────────
//
// The API hands over rules it has already filtered. What is left is the
// part no server can answer — has the trigger fired, has this person seen
// it enough, has the gap elapsed — and it has to give the same answers the
// web and Android SDKs give, or one campaign means two things.
print("[swift] in-app triggers")
check(InAppTriggers.compare(240, "gt", 100), "240 is over 100")
check(!InAppTriggers.compare(40, "gt", 100), "40 is not")
check(InAppTriggers.compare(100.0, "eq", 100), "100.0 and 100 are the same number")
check(!InAppTriggers.compare("240", "gt", 100),
      "a string is not compared against a number — the same refusal the other SDKs make")
check(!InAppTriggers.compare(true, "gt", 0),
      "a boolean is not the number one, however NSNumber feels about it")
check(!InAppTriggers.compare(nil, "gt", 100), "an unset value satisfies nothing")
check(InAppTriggers.compare("x", "exists", nil), "exists is about presence")
check(!InAppTriggers.compare(nil, "exists", nil), "and absence fails it")

check(InAppTriggers.satisfied(["kind": "app_open"], values: [:], sessions: 1),
      "app_open always fires")
check(InAppTriggers.satisfied(
        ["kind": "session_count", "op": "gte", "value": 3], values: [:], sessions: 3),
      "the third session satisfies >= 3")
check(!InAppTriggers.satisfied(
        ["kind": "session_count", "op": "gte", "value": 3], values: [:], sessions: 2),
      "the second does not")
check(InAppTriggers.satisfied(
        ["kind": "event", "key": "cart_value", "op": "gt", "value": 100],
        values: ["cart_value": 240], sessions: 1),
      "an event trigger reads the value the app set")
check(!InAppTriggers.satisfied(["kind": "phase_of_moon"], values: [:], sessions: 1),
      "a trigger kind from a newer console does not fire")

print("[swift] in-app frequency")
var iamStore: String?
func iamMemory() -> InAppMemory {
    InAppMemory(load: { iamStore }, save: { iamStore = $0 })
}
let ruleJson = """
{"id":"m1","layout":"center","content":{"blocks":[
 {"type":"text","text":"hi","size":16,"weight":"bold","align":"center"}],
 "style":{"bg":"#fff","radius":16,"padding":24},"dismissible":true},
 "trigger":{"kind":"app_open"},"max_displays":2,"min_gap_seconds":3600}
"""
let ruleObj = try! JSONSerialization.jsonObject(with: ruleJson.data(using: .utf8)!)
guard let iamRule = InAppParse.rule(ruleObj) else {
    FileHandle.standardError.write("  ✘ a rule parses off the wire\n".data(using: .utf8)!)
    exit(1)
}
check(iamRule.blocks.count == 1 && iamRule.dismissible, "its content came with it")
let iamRules = [iamRule]

var iamNow: Double = 1_000_000_000_000
check(InAppPicker.choose(rules: iamRules, memory: iamMemory(), triggers: [:],
                         sessions: 1, now: iamNow)?.id == "m1", "shows the first time")
iamMemory().record("m1", now: iamNow)
check(InAppPicker.choose(rules: iamRules, memory: iamMemory(), triggers: [:],
                         sessions: 1, now: iamNow) == nil, "and not again inside the gap")
iamNow += 3_600_001
check(InAppPicker.choose(rules: iamRules, memory: iamMemory(), triggers: [:],
                         sessions: 1, now: iamNow)?.id == "m1",
      "but it does once the gap has passed")
iamMemory().record("m1", now: iamNow)
iamNow += 10 * 3_600_000
check(InAppPicker.choose(rules: iamRules, memory: iamMemory(), triggers: [:],
                         sessions: 1, now: iamNow) == nil,
      "the display limit holds however long you wait")
// The state survives the process, which is the whole point of writing it
// down: an app reopened tomorrow must remember it showed this.
check(iamMemory().count("m1") == 2, "the count is read back from storage")

print("[swift] in-app content")
let emptyRule = try! JSONSerialization.jsonObject(
    with: #"{"id":"x","content":{"blocks":[]}}"#.data(using: .utf8)!)
check(InAppParse.rule(emptyRule) == nil, "a rule with nothing to draw is not a rule")
let weirdJson = #"""
{"id":"x","layout":"top","content":{"blocks":[{"type":"hologram"},
 {"type":"text","text":"still here","size":14}]},"trigger":{"kind":"app_open"}}
"""#
let weird = InAppParse.rule(try! JSONSerialization.jsonObject(with: weirdJson.data(using: .utf8)!))
check(weird?.blocks.count == 1, "a block type we cannot draw is dropped, not guessed")
check(weird?.dismissible == true, "a message with no dismissible field keeps its close button")

print("[swift] ALL PASSED")
