// Code shared by the app and the Screen Time monitor extension.
//
// iOS gives no per-app events. What it does give: a callback when the time spent in a
// category of apps reaches a threshold. iEyesApp sets a 5-minute ladder per category
// (5, 10, 15 ... minutes today) and logs each step it reaches. The log uses the same CSV
// columns, numbered gzip chunks and upload protocol as EyesApp on Android, so
// eyes.geosketch.art takes it unchanged.

import CryptoKit
import Compression
import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings
#if canImport(UIKit)
import UIKit
#endif

enum Eyes {
    static let appGroup = "group.com.zfzhong.ieyesapp"
    static let defaultServer = "https://eyes.geosketch.art"
    static let stepMinutes = 5
    static let lookahead = 3            // thresholds armed ahead, in case a callback is missed

    /// Names offered when the participant labels a picked category (Apple's Screen Time categories).
    static let categories = ["Social", "Games", "Entertainment", "Creativity", "Education", "Health & Fitness",
                             "Information & Reading", "Productivity & Finance", "Shopping & Food", "Travel",
                             "Utilities", "Other"]

    static var container: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)!
    }
    static var defaults: UserDefaults { UserDefaults(suiteName: appGroup)! }


    static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
    }

    static var deviceId: String {
        if let id = defaults.string(forKey: "device_id") { return id }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: "device_id")
        return id
    }
}

/// One lock across the app and the extension (they are separate processes).
func withEyesLock<T>(_ body: () throws -> T) rethrows -> T {
    let path = Eyes.container.appendingPathComponent("eyes.lock").path
    let fd = open(path, O_CREAT | O_RDWR, 0o644)
    if fd >= 0 { flock(fd, LOCK_EX) }
    defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
    return try body()
}

// MARK: - Log rows

enum Log {
    static let header = "app_package_name,app_class_name,interaction_type,event_timestamp,timezone,tz_offset," +
        "event_action,event_category,type_code,source,collected_at,detail"

    static var current: URL { Eyes.container.appendingPathComponent("current.csv") }

    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: ",", with: " ").replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\"", with: " ")
    }

    static func tzOffset(_ tz: TimeZone, _ date: Date) -> String {
        let m = tz.secondsFromGMT(for: date) / 60
        let sign = m >= 0 ? "+" : "-"
        let a = abs(m)
        return a % 60 == 0 ? "GMT\(sign)\(a / 60)" : String(format: "GMT%@%d:%02d", sign, a / 60, a % 60)
    }

    /// interaction_type = kind; event_category = the Screen Time category (when there is one);
    /// detail = key=value;key=value.
    static func row(_ kind: String, at date: Date = Date(), category: String = "", detail: [(String, Any)] = []) -> String {
        let tz = TimeZone.current
        let ms = Int64(date.timeIntervalSince1970 * 1000)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let d = detail.map { "\($0.0)=\(clean("\($0.1)").replacingOccurrences(of: ";", with: " ").replacingOccurrences(of: "=", with: " "))" }
            .joined(separator: ";")
        return ",,\(kind),\(ms),\(tz.identifier),\(tzOffset(tz, date)),,\(clean(category)),,ios,\(now),\(d)"
    }

    static func append(_ rows: [String]) {
        guard !rows.isEmpty else { return }
        withEyesLock {
            let data = (rows.joined(separator: "\n") + "\n").data(using: .utf8)!
            if let h = try? FileHandle(forWritingTo: current) {
                h.seekToEndOfFile()
                h.write(data)
                try? h.synchronize()
                try? h.close()
            } else {
                try? data.write(to: current, options: .atomic)
            }
        }
    }
}

// MARK: - Chunks (numbered gzip files, kept until the server confirms them)

enum Chunks {
    static var outbox: URL { dir("outbox") }
    static var sent: URL { dir("sent") }

    private static func dir(_ name: String) -> URL {
        let u = Eyes.container.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func files(in dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasSuffix(".csv.gz") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static var lastSeq: Int {
        let onDisk = (files(in: outbox) + files(in: sent))
            .compactMap { Int($0.lastPathComponent.replacingOccurrences(of: ".csv.gz", with: "")) }.max() ?? 0
        return max(onDisk, Eyes.defaults.integer(forKey: "next_seq") - 1)
    }

    /// Turns the rows logged so far into the next numbered chunk. Returns its number, or nil
    /// when there was nothing to close.
    @discardableResult
    static func close(kind: String = "live") -> Int? {
        withEyesLock {
            guard let text = try? String(contentsOf: Log.current, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let rows = text.split(separator: "\n", omittingEmptySubsequences: true)
            let body = Log.header + "\n" + rows.joined(separator: "\n") + "\n"
            guard let gz = Gzip.compress(Data(body.utf8)) else { return nil }
            let seq = lastSeq + 1
            let name = String(format: "%08d", seq)
            let times = rows.compactMap { r -> Int64? in
                let f = r.split(separator: ",", omittingEmptySubsequences: false)
                return f.count > 3 ? Int64(f[3]) : nil
            }
            let meta: [String: Any] = [
                "device": Eyes.deviceId, "seq": seq, "kind": kind,
                "from_ms": times.min() ?? 0, "to_ms": times.max() ?? 0, "rows": rows.count,
                "bytes": gz.count, "sha256": SHA256.hash(data: gz).map { String(format: "%02x", $0) }.joined(),
            ]
            do {
                let tmp = outbox.appendingPathComponent("\(name).csv.gz.tmp")
                try gz.write(to: tmp, options: .atomic)
                try JSONSerialization.data(withJSONObject: meta).write(
                    to: outbox.appendingPathComponent("\(name).json"), options: .atomic)
                try FileManager.default.moveItem(at: tmp, to: outbox.appendingPathComponent("\(name).csv.gz"))
                try FileManager.default.removeItem(at: Log.current)
                Eyes.defaults.set(seq + 1, forKey: "next_seq")
                return seq
            } catch {
                return nil
            }
        }
    }
}

/// gzip = 10-byte header + raw DEFLATE (Apple's COMPRESSION_ZLIB) + CRC-32 + size.
enum Gzip {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    static func compress(_ input: Data) -> Data? {
        let capacity = input.count + 1024
        var out = [UInt8](repeating: 0, count: capacity)
        let n = input.withUnsafeBytes { src -> Int in
            compression_encode_buffer(&out, capacity, src.bindMemory(to: UInt8.self).baseAddress!, input.count,
                                      nil, COMPRESSION_ZLIB)
        }
        guard n > 0 || input.isEmpty else { return nil }
        var gz = Data([0x1F, 0x8B, 0x08, 0, 0, 0, 0, 0, 0, 0xFF])
        gz.append(contentsOf: out[0..<n])
        var crc = crc32(input).littleEndian
        var size = UInt32(truncatingIfNeeded: input.count).littleEndian
        gz.append(Data(bytes: &crc, count: 4))
        gz.append(Data(bytes: &size, count: 4))
        return gz
    }
}

// MARK: - Screen Time: the picked categories and the 5-minute ladders

/// The participant selects all categories in one pass through Apple's picker. Apple returns
/// anonymous tokens with no order, so each gets a stable id on this device (c1, c2 ...,
/// sorted by the token's bytes). Naming them ("Social") is an optional second step: the app
/// shows each token's real name on screen, and the participant taps the matching name.
/// "all" is one more ladder: total time across every picked category.
enum Categories {
    static let total = "all"

    private static func encode(_ t: ActivityCategoryToken) -> Data? { try? JSONEncoder().encode(t) }

    /// Version 0.1 kept one token per named category ("token.social" ...). Carry those over
    /// once, names included, so a participant who already picked them need not pick again.
    static func migrateNamedTokens() {
        let d = Eyes.defaults
        guard d.array(forKey: "category_tokens") == nil else { return }
        var pairs: [(String, Data)] = []
        for name in Eyes.categories {
            let key = "token." + name.lowercased().filter { $0.isLetter || $0.isNumber }
            if let data = d.data(forKey: key) { pairs.append((name, data)) }
        }
        guard !pairs.isEmpty else { return }
        pairs.sort { $0.1.base64EncodedString() < $1.1.base64EncodedString() }
        d.set(pairs.map(\.1), forKey: "category_tokens")
        for (i, p) in pairs.enumerated() { d.set(p.0, forKey: "name.c\(i + 1)") }
    }

    /// Picked tokens, keyed by id, in id order.
    static var picked: [(id: String, token: ActivityCategoryToken)] {
        guard let arr = Eyes.defaults.array(forKey: "category_tokens") as? [Data] else { return [] }
        return arr.enumerated().compactMap { i, d in
            (try? JSONDecoder().decode(ActivityCategoryToken.self, from: d)).map { ("c\(i + 1)", $0) }
        }
    }

    static func setPicked(_ tokens: Set<ActivityCategoryToken>) {
        let data = tokens.compactMap(encode).sorted { $0.base64EncodedString() < $1.base64EncodedString() }
        let old = Eyes.defaults.array(forKey: "category_tokens") as? [Data] ?? []
        if old != data {
            // New set of ids: names given to the old ids no longer apply.
            for i in 1...max(1, old.count) { Eyes.defaults.removeObject(forKey: "name.c\(i)") }
        }
        Eyes.defaults.set(data, forKey: "category_tokens")
    }

    static func token(_ id: String) -> ActivityCategoryToken? { picked.first { $0.id == id }?.token }
    static var allTokens: Set<ActivityCategoryToken> { Set(picked.map(\.token)) }

    /// Optional name for an id (one of Eyes.categories), set by the participant.
    static func name(_ id: String) -> String? {
        id == total ? "All categories" : Eyes.defaults.string(forKey: "name.\(id)")
    }
    static func setName(_ n: String?, for id: String) { Eyes.defaults.set(n, forKey: "name.\(id)") }

    /// The ids that get a ladder: every picked category, plus the total.
    static var ladders: [String] { picked.isEmpty ? [] : picked.map(\.id) + [total] }

    private static var today: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    /// Minutes reached today on a ladder (0 after midnight).
    static func reached(_ id: String) -> Int {
        guard Eyes.defaults.string(forKey: "reached_day.\(id)") == today else { return 0 }
        return Eyes.defaults.integer(forKey: "reached.\(id)")
    }

    static func setReached(_ id: String, _ minutes: Int) {
        Eyes.defaults.set(today, forKey: "reached_day.\(id)")
        Eyes.defaults.set(minutes, forKey: "reached.\(id)")
    }
}

enum Monitor {
    static let center = DeviceActivityCenter()

    static var schedule: DeviceActivitySchedule {
        DeviceActivitySchedule(intervalStart: DateComponents(hour: 0, minute: 0),
                               intervalEnd: DateComponents(hour: 23, minute: 59, second: 59), repeats: true)
    }

    static func activity(_ id: String) -> DeviceActivityName { DeviceActivityName("cat.\(id)") }
    static func id(of activity: DeviceActivityName) -> String { String(activity.rawValue.dropFirst("cat.".count)) }

    static func eventName(_ id: String, _ minutes: Int) -> DeviceActivityEvent.Name {
        DeviceActivityEvent.Name("\(id).\(minutes)")
    }

    /// (ladder id, minutes) from an event name such as "c3.15" or "all.60".
    static func parse(_ event: DeviceActivityEvent.Name) -> (String, Int)? {
        let parts = event.rawValue.split(separator: ".")
        guard parts.count == 2, let m = Int(parts[1]) else { return nil }
        return (String(parts[0]), m)
    }

    /// Arms the next few 5-minute steps above what the ladder reached today. Counting includes
    /// earlier use today, so re-arming during the day loses nothing.
    static func arm(_ id: String) throws {
        let tokens: Set<ActivityCategoryToken> = id == Categories.total
            ? Categories.allTokens : Set([Categories.token(id)].compactMap { $0 })
        guard !tokens.isEmpty else { return }
        let base = Categories.reached(id)
        var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
        for k in 1...Eyes.lookahead {
            let m = base + k * Eyes.stepMinutes
            events[eventName(id, m)] = DeviceActivityEvent(
                applications: [], categories: tokens, webDomains: [],
                threshold: DateComponents(hour: m / 60, minute: m % 60), includesPastActivity: true)
        }
        center.stopMonitoring([activity(id)])
        try center.startMonitoring(activity(id), during: schedule, events: events)
    }

    static func armAll() -> [String] {
        Eyes.defaults.set(false, forKey: "monitoring_stopped")
        // Drop ladders for categories no longer picked.
        let keep = Set(Categories.ladders.map(activity))
        center.stopMonitoring(center.activities.filter { !keep.contains($0) })
        var errors: [String] = []
        for id in Categories.ladders {
            do { try arm(id) } catch { errors.append("\(id): \(error.localizedDescription)") }
        }
        return errors
    }

    static var monitoring: [DeviceActivityName] { center.activities }

    /// Every picked category and the total have a ladder running.
    static var isActive: Bool {
        let want = Set(Categories.ladders.map(activity))
        return !want.isEmpty && want.isSubset(of: Set(center.activities))
    }

    static func stopAll() {
        Eyes.defaults.set(true, forKey: "monitoring_stopped")
        center.stopMonitoring()
    }
}

// MARK: - Server

enum Server {
    static var url: String { Eyes.defaults.string(forKey: "server") ?? Eyes.defaultServer }
    static var token: String? { Eyes.defaults.string(forKey: "token") }
    static var enrolled: Bool { token != nil }

    static func note(error: String = "", uploaded: Bool = false) {
        Eyes.defaults.set(error, forKey: "last_error")
        if uploaded { Eyes.defaults.set(Date().timeIntervalSince1970, forKey: "last_upload") }
    }

    private static func request(_ path: String, method: String = "GET") -> URLRequest {
        var r = URLRequest(url: URL(string: url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path)!)
        r.httpMethod = method
        r.timeoutInterval = 30
        if let t = token { r.setValue(t, forHTTPHeaderField: "X-Eyes-Token") }
        return r
    }

    /// Runs an async request and waits for it (the monitor extension has no run loop to return to).
    private static func send(_ r: URLRequest, body: Data? = nil, wait: TimeInterval) -> (Int, [String: Any]?) {
        var result: (Int, [String: Any]?) = (0, nil)
        let sem = DispatchSemaphore(value: 0)
        let task: URLSessionTask
        let done: @Sendable (Data?, URLResponse?, Error?) -> Void = { data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            result = (code, json)
            sem.signal()
        }
        if let body { task = URLSession.shared.uploadTask(with: r, from: body, completionHandler: done) }
        else { task = URLSession.shared.dataTask(with: r, completionHandler: done) }
        task.resume()
        if sem.wait(timeout: .now() + wait) == .timedOut { task.cancel(); return (0, nil) }
        return result
    }

    /// Joins the group behind a code from eyes.geosketch.art. Returns nil on success, or a message.
    static func enroll(code: String, deviceName: String) -> String? {
        var info = utsname()
        uname(&info)
        let model = withUnsafeBytes(of: &info.machine) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        #if canImport(UIKit)
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let os = "iOS \(UIDevice.current.systemVersion)"
        #else
        let isPad = false
        let os = "iOS"
        #endif
        let body: [String: Any] = [
            "code": code.trimmingCharacters(in: .whitespaces), "device_id": Eyes.deviceId,
            "name": deviceName, "device_type": isPad ? "tablet" : "phone", "manufacturer": "Apple",
            "model": model, "android": os, "app_version": "ios-\(Eyes.appVersion)",
        ]
        var r = request("/enroll/", method: "POST")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (code, json) = send(r, body: try? JSONSerialization.data(withJSONObject: body), wait: 30)
        guard code == 200, let json, let token = json["token"] as? String else {
            return (json?["error"] as? String) ?? (code == 0 ? "Could not reach \(url)" : "Server answered \(code)")
        }
        let d = Eyes.defaults
        d.set(token, forKey: "token")
        d.set(json["group"] as? String ?? "", forKey: "group")
        d.set(json["label"] as? String ?? "", forKey: "label")
        Log.append([Log.row("enrolled", detail: [("group", json["group"] ?? ""), ("label", json["label"] ?? "")])])
        return nil
    }

    /// Closes the current log into a chunk, sends every waiting chunk oldest first, then fills
    /// any holes the server reports. Same rules as Android: a chunk leaves outbox/ only after
    /// "stored" or "duplicate".
    @discardableResult
    static func upload(wait: TimeInterval = 25) -> Bool {
        guard let token else { return true }
        _ = token
        Chunks.close()
        let deadline = Date().addingTimeInterval(wait)
        var ledger: [String: Any]?
        for f in Chunks.files(in: Chunks.outbox) {
            guard Date() < deadline else { return false }
            guard let r = sendChunk(f, wait: deadline.timeIntervalSinceNow) else { return false }
            ledger = r
        }
        if let ledger {
            let phoneMax = Chunks.lastSeq
            let wanted = Set(((ledger["missing"] as? [Int]) ?? []) + ((ledger["resend"] as? [Int]) ?? []))
            for seq in wanted.sorted() where seq <= phoneMax {
                guard Date() < deadline else { return false }
                let name = String(format: "%08d.csv.gz", seq)
                if let f = [Chunks.outbox, Chunks.sent].map({ $0.appendingPathComponent(name) })
                    .first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                    if sendChunk(f, wait: deadline.timeIntervalSinceNow) == nil { return false }
                } else {
                    var r = request("/lost/", method: "POST")
                    r.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    let b: [String: Any] = ["seq": seq, "reason": "not on the device", "phone_max_seq": phoneMax]
                    _ = send(r, body: try? JSONSerialization.data(withJSONObject: b), wait: 10)
                }
            }
            Eyes.defaults.set(ledger["have_through"] as? Int ?? 0, forKey: "have_through")
            if let s = ledger["settings"] as? [String: Any], let tick = s["tick_minutes"] as? Int {
                Eyes.defaults.set(tick, forKey: "tick_minutes")
            }
        }
        note(uploaded: true)
        return true
    }

    private static func sendChunk(_ gz: URL, wait: TimeInterval) -> [String: Any]? {
        let base = gz.lastPathComponent.replacingOccurrences(of: ".csv.gz", with: "")
        guard let seq = Int(base), let data = try? Data(contentsOf: gz) else { return nil }
        let metaURL = gz.deletingLastPathComponent().appendingPathComponent("\(base).json")
        let meta = (try? Data(contentsOf: metaURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let fields: [(String, String)] = [
            ("seq", "\(seq)"), ("sha256", sha), ("kind", meta["kind"] as? String ?? "live"),
            ("from_ms", "\(meta["from_ms"] ?? "")"), ("to_ms", "\(meta["to_ms"] ?? "")"),
            ("rows", "\(meta["rows"] ?? "")"), ("phone_max_seq", "\(Chunks.lastSeq)"),
            ("app_version", "ios-\(Eyes.appVersion)"),
        ]
        let boundary = "eyes" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var body = Data()
        for (k, v) in fields {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(gz.lastPathComponent)\"\r\nContent-Type: application/gzip\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        var r = request("/upload/", method: "POST")
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (code, json) = send(r, body: body, wait: max(5, wait))
        let status = json?["status"] as? String ?? ""
        switch code {
        case 200 where status == "stored" || status == "duplicate":
            if gz.deletingLastPathComponent().lastPathComponent != "sent" {
                try? FileManager.default.moveItem(at: metaURL, to: Chunks.sent.appendingPathComponent(metaURL.lastPathComponent))
                try? FileManager.default.moveItem(at: gz, to: Chunks.sent.appendingPathComponent(gz.lastPathComponent))
            }
            return json
        case 409:
            try? FileManager.default.moveItem(at: gz, to: gz.deletingLastPathComponent().appendingPathComponent("\(base).conflict.gz"))
            return json
        case 401:
            for k in ["token", "group", "label"] { Eyes.defaults.removeObject(forKey: k) }
            note(error: "The server no longer accepts this device. Join again with a new code.")
            return nil
        default:
            note(error: code == 0 ? "No network" : "File \(seq): server answered \(code)")
            return nil
        }
    }
}
