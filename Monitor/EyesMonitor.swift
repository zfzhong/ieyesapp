// The Screen Time monitor extension. iOS runs it, briefly, when time today on a ladder
// (one category, or all of them) reaches an armed threshold, and when the daily schedule
// starts or ends.

import DeviceActivity
import Foundation
import UserNotifications

final class EyesMonitor: DeviceActivityMonitor {

    private func log(_ kind: String, _ id: String, _ detail: [(String, Any)] = []) {
        Log.append([Log.row(kind, category: Categories.name(id) ?? id, detail: [("id", id)] + detail)])
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        guard let (id, minutes) = Monitor.parse(event) else { return }
        // Log only steps above what is already logged today (a re-arm can deliver an old step again).
        if minutes > Categories.reached(id) {
            let since = Monitor.sinceArmed(id)
            Categories.setReached(id, minutes)
            log(id == Categories.total ? "total_threshold" : "category_threshold", id,
                [("minutes", minutes), ("step", Eyes.stepMinutes),
                 ("catchup", since < Monitor.catchUpSeconds ? 1 : 0), ("since_arm_s", Int(since))])
        }
        do { try Monitor.arm(id) } catch { log("arm_error", id, [("error", error.localizedDescription)]) }
        // Send what is waiting; the open file is closed only once it is 15 min old or large.
        Heartbeat.write("monitor", minGap: 5 * 60)
        nudgeIfStopped()
        Server.upload(wait: 15, force: false)
    }

    /// 0.9 (10-14): iEyesApp is often swiped away (a test iPhone, 13:40-17:09, 153 min of use while it was not
    /// running). This extension keeps running, and a threshold means the phone is being used, so if the
    /// app's keep-running mode has not been alive for 20 minutes, ask the person to open it (at most every
    /// 30 minutes). LiveMotion.aliveKey is set at every 10-minute tick and removed when keep-running is
    /// turned off on purpose.
    private func nudgeIfStopped() {
        let d = Eyes.defaults
        guard !d.bool(forKey: "monitoring_stopped") else { return }
        let last = d.double(forKey: "keepalive_alive_ms")
        let now = Date().timeIntervalSince1970 * 1000
        guard last > 0, now - last > 20 * 60 * 1000, now - d.double(forKey: "nudge_ms") > 30 * 60 * 1000 else { return }
        d.set(now, forKey: "nudge_ms")
        let c = UNMutableNotificationContent()
        c.title = "iEyesApp is not running"
        c.body = "It was closed. Tap to resume recording."
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "eyes.nudge", content: c, trigger: nil))
        Log.append([Log.row("nudge", detail: [("down_min", Int((now - last) / 60000))])])
    }

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        // Also called when monitoring is (re)started mid-day; reached() resets by date, so only
        // note a new day once per ladder and arm it from zero.
        let id = Monitor.id(of: activity)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let today = f.string(from: Date())
        if Eyes.defaults.string(forKey: "day_logged.\(id)") != today {
            Eyes.defaults.set(today, forKey: "day_logged.\(id)")
            log("day_start", id)
            try? Monitor.arm(id)
        }
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        let id = Monitor.id(of: activity)
        // arm() stops and restarts a ladder, and iOS reports that stop as an interval end.
        // Log only a real end: the daily schedule closing at midnight.
        if Monitor.rearming(id) { return }
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        if c.hour == 23 && (c.minute ?? 0) >= 58 || c.hour == 0 && (c.minute ?? 0) <= 1 {
            log("day_end", id, [("minutes", Categories.reached(id))])
        }
    }
}
