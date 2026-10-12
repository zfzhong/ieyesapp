// The Screen Time monitor extension. iOS runs it, briefly, when time today on a ladder
// (one category, or all of them) reaches an armed threshold, and when the daily schedule
// starts or ends.

import DeviceActivity
import Foundation

final class EyesMonitor: DeviceActivityMonitor {

    private func log(_ kind: String, _ id: String, _ detail: [(String, Any)] = []) {
        Log.append([Log.row(kind, category: Categories.name(id) ?? id, detail: [("id", id)] + detail)])
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        guard let (id, minutes) = Monitor.parse(event) else { return }
        // Log only steps above what is already logged today (a re-arm can deliver an old step again).
        if minutes > Categories.reached(id) {
            Categories.setReached(id, minutes)
            log(id == Categories.total ? "total_threshold" : "category_threshold", id,
                [("minutes", minutes), ("step", Eyes.stepMinutes)])
        }
        do { try Monitor.arm(id) } catch { log("arm_error", id, [("error", error.localizedDescription)]) }
        // Try to send now; if the network is not allowed or not there, the app sends later.
        Server.upload(wait: 15)
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
        log("day_end", id, [("minutes", Categories.reached(id))])
    }
}
