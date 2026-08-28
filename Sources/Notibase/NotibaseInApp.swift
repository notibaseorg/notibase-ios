/**
 * In-app messages: the decisions, with no UIKit in them.
 *
 * An in-app message is a rule, not a send. The API hands over the ones this
 * device is eligible for — already filtered by status, display window and
 * segment — and everything left is a question only the device can answer:
 * has the trigger fired, has this person seen it enough times, has the gap
 * elapsed.
 *
 * Those three answers are the whole feature and the part that breaks, so
 * they live here, in Foundation only. That means this file compiles and is
 * exercised on Linux by the same e2e harness that checks the HTTP core,
 * before any of it reaches a phone. Drawing the message is
 * NotibaseInAppView.swift, which is guarded by `canImport(UIKit)` and
 * compiles to nothing on Linux.
 *
 * The rules match the web and Android SDKs exactly, including their refusal
 * to compare across types. A customer who writes "cart_value over 100" in
 * one console must get one answer on every platform.
 */
import Foundation

/// What a button does. `kind` is closed; an unknown one does nothing.
public struct InAppAction {
    public let kind: String
    public let url: String?
    public let key: String?
    public let value: Any?
    public let name: String?
}

public enum InAppBlock {
    case text(text: String, size: Int, bold: Bool, align: String, color: String?)
    case image(url: String, alt: String, height: Int?)
    case button(label: String, action: InAppAction, bg: String?, color: String?, radius: Int)
    case spacer(height: Int)
}

public struct InAppStyle {
    public let bg: String
    public let radius: Int
    public let padding: Int
}

public struct InAppRule {
    public let id: String
    /// top | center | bottom | full
    public let layout: String
    public let blocks: [InAppBlock]
    public let style: InAppStyle
    public let dismissible: Bool
    public let trigger: [String: Any]
    /// Nil is unlimited.
    public let maxDisplays: Int?
    public let minGapSeconds: Int
}

public enum InAppParse {

    /// One rule off the wire, or nil if it is a shape we do not understand.
    public static func rule(_ raw: Any?) -> InAppRule? {
        guard let m = raw as? [String: Any],
              let id = m["id"] as? String,
              let content = m["content"] as? [String: Any],
              let rawBlocks = content["blocks"] as? [[String: Any]] else { return nil }
        let blocks = rawBlocks.compactMap { block($0) }
        if blocks.isEmpty { return nil }
        let style = content["style"] as? [String: Any]
        return InAppRule(
            id: id,
            layout: m["layout"] as? String ?? "center",
            blocks: blocks,
            style: InAppStyle(
                bg: style?["bg"] as? String ?? "#ffffff",
                radius: int(style?["radius"]) ?? 16,
                padding: int(style?["padding"]) ?? 24),
            // Absent means dismissible. A message that loses its close
            // button to a parsing gap is one somebody cannot escape.
            dismissible: content["dismissible"] as? Bool ?? true,
            trigger: m["trigger"] as? [String: Any] ?? ["kind": "app_open"],
            maxDisplays: int(m["max_displays"]),
            minGapSeconds: int(m["min_gap_seconds"]) ?? 0)
    }

    private static func block(_ m: [String: Any]) -> InAppBlock? {
        switch m["type"] as? String {
        case "text":
            guard let text = m["text"] as? String else { return nil }
            return .text(
                text: text,
                size: int(m["size"]) ?? 16,
                bold: (m["weight"] as? String) == "bold",
                align: m["align"] as? String ?? "center",
                color: m["color"] as? String)
        case "image":
            guard let url = m["url"] as? String else { return nil }
            return .image(url: url, alt: m["alt"] as? String ?? "", height: int(m["height"]))
        case "button":
            guard let label = m["label"] as? String else { return nil }
            return .button(
                label: label,
                action: action(m["action"]) ?? InAppAction(
                    kind: "dismiss", url: nil, key: nil, value: nil, name: nil),
                bg: m["bg"] as? String,
                color: m["color"] as? String,
                radius: int(m["radius"]) ?? 8)
        case "spacer":
            return .spacer(height: int(m["height"]) ?? 12)
        default:
            // A block type from a console newer than this SDK. Dropped
            // rather than guessed: a placeholder for something we cannot
            // draw puts a hole in somebody's campaign.
            return nil
        }
    }

    private static func action(_ raw: Any?) -> InAppAction? {
        guard let m = raw as? [String: Any], let kind = m["kind"] as? String else { return nil }
        return InAppAction(
            kind: kind,
            url: m["url"] as? String,
            key: m["key"] as? String,
            value: m["value"],
            name: m["name"] as? String)
    }

    /// JSON integers arrive as NSNumber; a Bool is one too and is not this.
    public static func int(_ v: Any?) -> Int? {
        if v is Bool { return nil }
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        return nil
    }
}

public enum InAppTriggers {

    /**
     * A number, or nothing.
     *
     * The Bool check comes first and is the whole reason this helper
     * exists: a JSON `true` is an NSNumber, so without it `true` would
     * compare as 1 and a boolean trigger would satisfy "greater than 0".
     */
    static func numeric(_ v: Any?) -> Double? {
        guard let v = v else { return nil }
        if v is Bool { return nil }
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        return nil
    }

    /// 100 and 100.0 are the same number; "100" is not that number.
    static func same(_ left: Any?, _ right: Any?) -> Bool {
        if let a = numeric(left), let b = numeric(right) { return a == b }
        if let a = left as? String, let b = right as? String { return a == b }
        if let a = left as? Bool, let b = right as? Bool { return a == b }
        return false
    }

    /**
     * The same comparison the web and Android SDKs make, deliberately
     * including what it refuses to do.
     *
     * A trigger set to the string "100" does not satisfy `over 100`. A
     * customer whose values sometimes arrive as strings should find that
     * out from a message that did not fire, not from one that fired for the
     * wrong people — and two SDKs disagreeing about it would be worse than
     * either answer.
     */
    public static func compare(_ left: Any?, _ op: String, _ right: Any?) -> Bool {
        if op == "exists" { return left != nil }
        if left == nil { return false }
        if op == "eq" { return same(left, right) }
        if op == "neq" { return !same(left, right) }
        guard let a = numeric(left), let b = numeric(right) else { return false }
        switch op {
        case "gt": return a > b
        case "gte": return a >= b
        case "lt": return a < b
        case "lte": return a <= b
        default: return false
        }
    }

    public static func satisfied(
        _ trigger: [String: Any], values: [String: Any], sessions: Int
    ) -> Bool {
        switch trigger["kind"] as? String {
        case "app_open":
            return true
        case "session_count":
            return compare(sessions, trigger["op"] as? String ?? "", trigger["value"])
        case "event":
            return compare(
                values[trigger["key"] as? String ?? ""],
                trigger["op"] as? String ?? "",
                trigger["value"])
        default:
            // A kind authored by a console newer than this SDK. Not showing
            // it is the only safe reading — showing it would mean ignoring
            // a condition somebody deliberately set.
            return false
        }
    }
}

/**
 * How often each message has been shown on THIS device.
 *
 * Device-local on purpose, and the cost is worth writing down: a reinstall
 * forgets, and two devices belonging to one person count separately. Both
 * err towards showing a message again, which a person can dismiss — where
 * asking a server on every launch would put a network call in front of
 * every cold start, and an app opened on a plane would show nothing.
 *
 * Reading and writing are closures so this file stays free of UserDefaults
 * as much as of UIKit, and the harness can drive it with a dictionary.
 */
public final class InAppMemory {
    private let load: () -> String?
    private let save: (String) -> Void
    private var counts: [String: Int] = [:]
    private var lastAt: [String: Double] = [:]
    private var loaded = false

    public init(load: @escaping () -> String?, save: @escaping (String) -> Void) {
        self.load = load
        self.save = save
    }

    private func hydrate() {
        if loaded { return }
        loaded = true
        guard let raw = load(), let data = raw.data(using: .utf8),
              let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        for (id, v) in parsed {
            guard let m = v as? [String: Any] else { continue }
            counts[id] = InAppParse.int(m["n"]) ?? 0
            lastAt[id] = (m["at"] as? Double) ?? 0
        }
    }

    public func count(_ id: String) -> Int {
        hydrate()
        return counts[id] ?? 0
    }

    public func lastShownAt(_ id: String) -> Double {
        hydrate()
        return lastAt[id] ?? 0
    }

    /**
     * Recorded before the message is drawn, never after.
     *
     * Somebody who kills the app the instant a message appears has still
     * seen it. A counter that only advances on a clean dismissal shows the
     * same message every launch to whoever closes it fastest.
     */
    public func record(_ id: String, now: Double) {
        hydrate()
        counts[id] = (counts[id] ?? 0) + 1
        lastAt[id] = now
        var out: [String: Any] = [:]
        for (key, n) in counts { out[key] = ["n": n, "at": lastAt[key] ?? 0] }
        if let data = try? JSONSerialization.data(withJSONObject: out),
           let text = String(data: data, encoding: .utf8) {
            save(text)
        }
    }
}

public enum InAppPicker {

    /**
     * The first rule this device may show, or none.
     *
     * First, not all of them: two messages stacked on each other is the
     * failure mode this feature has, and "the newest wins" is a rule nobody
     * could predict from the console. The API returns them oldest first, so
     * the oldest eligible campaign shows and the rest wait for the next
     * open.
     */
    public static func choose(
        rules: [InAppRule],
        memory: InAppMemory,
        triggers: [String: Any],
        sessions: Int,
        now: Double
    ) -> InAppRule? {
        for rule in rules {
            if let cap = rule.maxDisplays, memory.count(rule.id) >= cap { continue }
            if rule.minGapSeconds > 0,
               now - memory.lastShownAt(rule.id) < Double(rule.minGapSeconds) * 1000 { continue }
            if !InAppTriggers.satisfied(rule.trigger, values: triggers, sessions: sessions) { continue }
            return rule
        }
        return nil
    }
}
