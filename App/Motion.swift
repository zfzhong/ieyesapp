// Accelerometer for iEyesApp (the recorder; see LiveMotion.swift for the keep-running mode).
//
// iOS keeps only one motion sensor running while an app is not on screen: CMSensorRecorder
// records the accelerometer at about 50 Hz for up to 12 hours per request and keeps the
// samples for 3 days. iEyesApp asks for 12 more hours whenever it runs, reads the samples
// back whenever it runs (on screen, or a background refresh), thins them, and writes them as
// sensor chunks in the same format as Android EyesApp:
//
//   timestamp_ms,sensor,x,y,z      sensor = accel, x/y/z in m/s²
//
// Units and sign follow Android: a phone lying face up reads z ≈ +9.81. (Core Motion reports
// g with the opposite sign, so values are multiplied by -9.80665.)
//
// Thinning: about 5 samples a second while the phone is moving and 1 a second while it is
// still. "Moving" = the size of the acceleration changed by more than 0.02 g since the last
// kept sample.

import CoreMotion
import Foundation

enum Motion {
    static let header = "timestamp_ms,sensor,x,y,z"
    static let recordHours: Double = 12
    static let keepDays: Double = 3                 // what iOS keeps
    static let latency: TimeInterval = 5 * 60       // samples show up a few minutes late
    static let maxRowsPerChunk = 6_000            // David: 6,000 records per motion file

    static var openFile: URL { Eyes.container.appendingPathComponent("sensor_open.csv") }
    private static let busy = NSLock()

    static var available: Bool { CMSensorRecorder.isAccelerometerRecordingAvailable() }
    static var authorized: Bool { CMSensorRecorder.authorizationStatus() == .authorized }
    static var denied: Bool {
        let s = CMSensorRecorder.authorizationStatus()
        return s == .denied || s == .restricted
    }
    static var enabled: Bool { !Eyes.defaults.bool(forKey: "motion_off") }

    static var recordingUntil: Date? {
        let t = Eyes.defaults.double(forKey: "accel_recording_until")
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }
    static var fetchedThrough: Date? {
        let t = Eyes.defaults.double(forKey: "accel_fetched_through")
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// Keeps the recorder running: asks for another 12 hours when less than 6 remain, or when the
    /// phone has restarted since the last request (0.10: a restart ends the recording; on a test
    /// iPhone 10-17 it recorded only 2 of the 185 minutes after a restart).
    /// The first call shows the Motion & Fitness permission prompt.
    static func keepRecording() {
        guard enabled, available, !denied else { return }
        let now = Date()
        let restarted = Proc.restartedSince("accel_record_uptime") ?? false
        if !restarted, let until = recordingUntil, until.timeIntervalSince(now) > 6 * 3600 { return }
        CMSensorRecorder().recordAccelerometer(forDuration: recordHours * 3600)
        Proc.noteUptime("accel_record_uptime")
        Eyes.defaults.set(now.addingTimeInterval(recordHours * 3600).timeIntervalSince1970,
                          forKey: "accel_recording_until")
        if Eyes.defaults.double(forKey: "accel_fetched_through") == 0 {
            Eyes.defaults.set(now.timeIntervalSince1970, forKey: "accel_fetched_through")
        }
        Log.append([Log.row("accel_record", detail: [("hours", Int(recordHours)),
                                                    ("reason", restarted ? "restart" : "renew")])])
    }

    /// Reads recorded samples (oldest first, an hour at a time) until `budget` seconds are used,
    /// and turns them into sensor chunks. Returns the number of rows written.
    @discardableResult
    static func collect(budget: TimeInterval) -> Int {
        guard enabled, available, authorized else { return 0 }
        guard busy.try() else { return 0 }
        defer { busy.unlock() }
        let start = Date()
        let end = start.addingTimeInterval(-latency)
        var from = fetchedThrough ?? end
        let oldest = start.addingTimeInterval(-keepDays * 86400 + 600)
        if from < oldest {
            Log.append([Log.row("accel_gap", detail: [("from", Int64(from.timeIntervalSince1970 * 1000)),
                                                     ("to", Int64(oldest.timeIntervalSince1970 * 1000))])])
            from = oldest
        }
        let recorder = CMSensorRecorder()
        var total = 0
        var thin = Thinner()
        while from < end && Date().timeIntervalSince(start) < budget {
            let to = min(end, from.addingTimeInterval(3600))
            var rows: [String] = []
            var last = from
            if let list = recorder.accelerometerData(from: from, to: to) {
                var it = NSFastEnumerationIterator(list)
                while let o = it.next() {
                    guard let s = o as? CMRecordedAccelerometerData else { continue }
                    last = max(last, s.startDate)
                    if let r = thin.take(s) { rows.append(r) }
                }
            }
            if !rows.isEmpty { append(rows) }
            total += rows.count
            // Done with [from, to): move on even when the hour was empty (not recording then).
            from = to
            Eyes.defaults.set(from.timeIntervalSince1970, forKey: "accel_fetched_through")
            closeChunks(force: false)
        }
        closeChunks(force: true)
        if total > 0 { Eyes.defaults.set(Date().timeIntervalSince1970, forKey: "accel_last_collect") }
        return total
    }

    /// Thins 50 Hz samples to 5 Hz while moving and 1 Hz while still.
    struct Thinner {
        var lastMs: Int64 = 0
        var lastMag: Double = -1
        var maxDev: Double = 0

        mutating func take(_ s: CMRecordedAccelerometerData) -> String? {
            let a = s.acceleration
            let mag = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
            let ms = Int64(s.startDate.timeIntervalSince1970 * 1000)
            if lastMag >= 0 { maxDev = max(maxDev, abs(mag - lastMag)) }
            let dt = ms - lastMs
            guard lastMag < 0 || (dt >= 180 && maxDev > 0.02) || dt >= 900 else { return nil }
            lastMs = ms
            lastMag = mag
            maxDev = 0
            let k = -9.80665
            return String(format: "%lld,accel,%.4f,%.4f,%.4f", ms, a.x * k, a.y * k, a.z * k)
        }
    }

    /// Rows from the live sensors (keep-running mode).
    static func appendLive(_ rows: [String]) {
        append(rows)
        closeChunks(force: false)
    }

    /// The live sensors cover time up to `date`: the recorder need not be read for it.
    static func markLiveThrough(_ date: Date) {
        let t = date.timeIntervalSince1970
        if t > Eyes.defaults.double(forKey: "accel_fetched_through") {
            Eyes.defaults.set(t, forKey: "accel_fetched_through")
        }
    }

    /// Closes whatever is in the open motion file into chunks.
    static func closeOpen() { closeChunks(force: true) }

    private static func append(_ rows: [String]) {
        withEyesLock {
            let data = (rows.joined(separator: "\n") + "\n").data(using: .utf8)!
            if let h = try? FileHandle(forWritingTo: openFile) {
                h.seekToEndOfFile()
                h.write(data)
                try? h.close()
            } else {
                try? data.write(to: openFile, options: .atomic)
            }
        }
    }

    /// Closes the open sensor file into chunks of at most 6,000 rows. Without `force`, only
    /// full chunks are closed and the rest stays open.
    private static func closeChunks(force: Bool) {
        withEyesLock {
            guard let text = try? String(contentsOf: openFile, encoding: .utf8) else { return }
            var rows = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            while rows.count >= maxRowsPerChunk || (force && !rows.isEmpty) {
                let part = Array(rows.prefix(maxRowsPerChunk))
                guard Chunks.write(rows: part, header: header, kind: "sensor", timeField: 0) != nil else { return }
                rows.removeFirst(part.count)
                if rows.isEmpty { try? FileManager.default.removeItem(at: openFile) }
                else { try? (rows.joined(separator: "\n") + "\n").write(to: openFile, atomically: true, encoding: .utf8) }
            }
        }
    }
}


// MARK: - Activity (iOS's own motion activity: automotive, walking, running, cycling, stationary)
//
// David 10-14: "use the phones' own vehicle detection as the main signal". iOS classifies the
// phone's motion itself (from the motion coprocessor, cheap on battery) and keeps 7 days of history,
// so it can be read back at each heartbeat even for times iEyesApp was not running. Same Motion &
// Fitness permission as the accelerometer recorder. One row per change:
//   motion_activity  (event_timestamp = when the activity began)
//     activity = automotive | cycling | running | walking | stationary | unknown   (the main one)
//     flags    = every flag iOS set (automotive+stationary = in a car at a light)
//     confidence = low | medium | high
enum Activity {
    static let keepDays: Double = 7
    private static let manager = CMMotionActivityManager()
    private static let queue: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = 1; return q }()
    private static let busy = NSLock()

    static var available: Bool { CMMotionActivityManager.isActivityAvailable() }

    static func main(_ a: CMMotionActivity) -> String {
        if a.automotive { return "automotive" }
        if a.cycling { return "cycling" }
        if a.running { return "running" }
        if a.walking { return "walking" }
        if a.stationary { return "stationary" }
        return "unknown"
    }

    static func flags(_ a: CMMotionActivity) -> String {
        var f: [String] = []
        if a.automotive { f.append("automotive") }
        if a.cycling { f.append("cycling") }
        if a.running { f.append("running") }
        if a.walking { f.append("walking") }
        if a.stationary { f.append("stationary") }
        if a.unknown { f.append("unknown") }
        return f.joined(separator: "+")
    }

    static func confidence(_ c: CMMotionActivityConfidence) -> String {
        switch c { case .low: return "low"; case .medium: return "medium"; case .high: return "high"; @unknown default: return "?" }
    }

    /// Reads the activity history since the last read (at most 7 days back) and logs the changes.
    static func collect() {
        guard Motion.enabled, available, CMMotionActivityManager.authorizationStatus() == .authorized else { return }
        guard busy.try() else { return }
        let now = Date()
        let t = Eyes.defaults.double(forKey: "activity_through")
        let from = max(t > 0 ? Date(timeIntervalSince1970: t) : now.addingTimeInterval(-keepDays * 86400),
                       now.addingTimeInterval(-keepDays * 86400 + 600))
        manager.queryActivityStarting(from: from, to: now, to: queue) { list, error in
            defer { busy.unlock() }
            if let error = error {
                Log.append([Log.row("motion_activity_error", detail: [("error", "\(error.localizedDescription)")])])
                return
            }
            var last = Eyes.defaults.string(forKey: "activity_last") ?? ""
            var rows: [String] = []
            for a in list ?? [] where a.startDate >= from {
                let key = "\(flags(a))/\(confidence(a.confidence))"
                if key == last { continue }
                last = key
                rows.append(Log.row("motion_activity", at: a.startDate, detail: [
                    ("activity", main(a)), ("flags", flags(a)), ("confidence", confidence(a.confidence))]))
            }
            Log.append(rows)
            Eyes.defaults.set(last, forKey: "activity_last")
            Eyes.defaults.set(now.timeIntervalSince1970, forKey: "activity_through")
        }
    }
}
