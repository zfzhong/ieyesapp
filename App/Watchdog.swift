// Watchdog notification and power/thermal records (10-12, after iOS stopped iEyesApp on
// another test iPhone for 101 minutes with no record of why).
//
// Watchdog: while "Keep running in background" is on, every 10-minute tick replaces a local
// notification set 30 minutes ahead. While iEyesApp runs it never fires; if iOS stops the
// app, it fires: "iEyesApp stopped recording — tap to resume". Tapping opens the app, which
// restarts background running. Taps are logged (watchdog_tap) so we can count stops.
//
// Power: Low Power Mode and the thermal state are in every heartbeat (Heartbeat.write), and
// each change is logged as it happens (low_power, thermal).

import Foundation
import UserNotifications

enum Watchdog {
    static let id = "eyes.watchdog"
    static let after: TimeInterval = 30 * 60

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
            Log.append([Log.row("watchdog_permission", detail: [("granted", ok ? 1 : 0)])])
        }
    }

    /// Replaces the pending watchdog with one 30 minutes from now.
    static func push() {
        let c = UNMutableNotificationContent()
        c.title = "iEyesApp stopped recording"
        c.body = "iOS stopped iEyesApp in the background. Tap to resume."
        c.sound = .default
        let req = UNNotificationRequest(identifier: id, content: c,
                                        trigger: UNTimeIntervalNotificationTrigger(timeInterval: after, repeats: false))
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.add(req)
    }

    static func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }
}

/// Logs taps on the watchdog and keeps it out of sight while the app is on screen.
final class NotificationHandler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationHandler()

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let rid = response.notification.request.identifier
        if rid == Watchdog.id || rid == "eyes.nudge" {           // eyes.nudge: from the Screen Time extension (0.9)
            let fired = response.notification.date
            Log.append([Log.row(rid == Watchdog.id ? "watchdog_tap" : "nudge_tap",
                                detail: [("fired_ms", Int64(fired.timeIntervalSince1970 * 1000))])])
        }
        done()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([])        // app is running: nothing to warn about
    }
}

enum PowerWatch {
    static func thermalName(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static var started = false

    static func start() {
        guard !started else { return }
        started = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil) { _ in
            Log.append([Log.row("low_power", detail: [("on", ProcessInfo.processInfo.isLowPowerModeEnabled ? 1 : 0)])])
        }
        nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { _ in
            Log.append([Log.row("thermal", detail: [("state", thermalName(ProcessInfo.processInfo.thermalState))])])
        }
    }
}
