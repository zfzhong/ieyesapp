// Why iEyesApp stops (0.10, David 10-18). On 10-17 keep-running stopped three times on a test
// iPhone (a dead battery once, and twice with the phone in use), and the log could not say why.
// These rows give every stop a cause:
//
//   app_launch      how this run began: on screen (fg), or in the background, and whether a
//                   location event relaunched it (location=1); restarted=1 when the phone restarted
//                   since keep-running was last alive.
//   app_terminate   the person swiped iEyesApp away (iOS calls applicationWillTerminate for an app
//                   running in the background). iOS ending the app gives no callback, so a stop with
//                   no app_terminate row was iOS.
//   memory_warning  iOS asked the app to free memory (it often ends apps soon after); mem_mb is our
//                   own footprint and mem_left_mb how much more iOS would allow.
//   exit_reasons    iOS's own count of how the app ended (MetricKit, delivered about once a day for
//                   the previous day): bg_memory_pressure (ended to free memory for other apps),
//                   bg_memory_limit (our own use too high), bg_cpu_limit, bg_watchdog,
//                   bg_task_timeout, bg_locked_file, bg_bad_access / bg_illegal_instruction /
//                   bg_abnormal (crashes), bg_normal; the same fg_* while on screen.
//   app_crash       a crash report from MetricKit (exception type and signal), if iEyesApp crashed.

import MetricKit
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate, MXMetricManagerSubscriber {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let restarted = Proc.restartedSince(LiveMotion.aliveUptimeKey) ?? false
        Log.append([Log.row("app_launch", detail: [
            ("state", application.applicationState == .background ? "bg" : "fg"),
            ("location", launchOptions?[.location] != nil ? 1 : 0),
            ("restarted", restarted ? 1 : 0),
            ("uptime_s", Int(ProcessInfo.processInfo.systemUptime)),
        ])])
        MXMetricManager.shared.add(self)
        // Reports iOS delivered while the app was not running.
        didReceive(MXMetricManager.shared.pastPayloads)
        didReceive(MXMetricManager.shared.pastDiagnosticPayloads)
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        Log.append([Log.row("app_terminate", detail: [
            ("state", application.applicationState == .background ? "bg" : "fg"),
            ("keepalive", LiveMotion.shared.running ? 1 : 0),
            ("mem_mb", Proc.memoryMB),
        ])])
    }

    private var lastWarning: TimeInterval = 0

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        let now = Date().timeIntervalSince1970
        guard now - lastWarning > 60 else { return }        // at most one row a minute
        lastWarning = now
        Log.append([Log.row("memory_warning", detail: [
            ("state", application.applicationState == .background ? "bg" : "fg"),
            ("mem_mb", Proc.memoryMB), ("mem_left_mb", Proc.memoryLeftMB),
        ])])
    }

    // MARK: MetricKit

    private static let doneKey = "metrics_logged_through"

    func didReceive(_ payloads: [MXMetricPayload]) {
        var through = Eyes.defaults.double(forKey: Self.doneKey)
        var rows: [String] = []
        for p in payloads.sorted(by: { $0.timeStampEnd < $1.timeStampEnd }) {
            let end = p.timeStampEnd.timeIntervalSince1970
            guard end > through, let exits = p.applicationExitMetrics else { continue }
            through = end
            let b = exits.backgroundExitData
            let f = exits.foregroundExitData
            rows.append(Log.row("exit_reasons", at: p.timeStampEnd, detail: [
                ("from_ms", Int64(p.timeStampBegin.timeIntervalSince1970 * 1000)),
                ("to_ms", Int64(end * 1000)),
                ("app", p.latestApplicationVersion),
                ("bg_memory_pressure", b.cumulativeMemoryPressureExitCount),
                ("bg_memory_limit", b.cumulativeMemoryResourceLimitExitCount),
                ("bg_cpu_limit", b.cumulativeCPUResourceLimitExitCount),
                ("bg_watchdog", b.cumulativeAppWatchdogExitCount),
                ("bg_task_timeout", b.cumulativeBackgroundTaskAssertionTimeoutExitCount),
                ("bg_locked_file", b.cumulativeSuspendedWithLockedFileExitCount),
                ("bg_bad_access", b.cumulativeBadAccessExitCount),
                ("bg_illegal_instruction", b.cumulativeIllegalInstructionExitCount),
                ("bg_abnormal", b.cumulativeAbnormalExitCount),
                ("bg_normal", b.cumulativeNormalAppExitCount),
                ("fg_memory_limit", f.cumulativeMemoryResourceLimitExitCount),
                ("fg_watchdog", f.cumulativeAppWatchdogExitCount),
                ("fg_bad_access", f.cumulativeBadAccessExitCount),
                ("fg_illegal_instruction", f.cumulativeIllegalInstructionExitCount),
                ("fg_abnormal", f.cumulativeAbnormalExitCount),
                ("fg_normal", f.cumulativeNormalAppExitCount),
            ]))
        }
        Log.append(rows)
        Eyes.defaults.set(through, forKey: Self.doneKey)
    }

    private static let crashKey = "crashes_logged_through"

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        var through = Eyes.defaults.double(forKey: Self.crashKey)
        var rows: [String] = []
        for p in payloads.sorted(by: { $0.timeStampEnd < $1.timeStampEnd }) {
            let end = p.timeStampEnd.timeIntervalSince1970
            guard end > through else { continue }
            through = end
            for c in p.crashDiagnostics ?? [] {
                rows.append(Log.row("app_crash", at: p.timeStampEnd, detail: [
                    ("exception_type", c.exceptionType?.intValue ?? -1),
                    ("signal", c.signal?.intValue ?? -1),
                    ("reason", c.terminationReason ?? ""),
                    ("app", c.applicationVersion),
                ]))
            }
        }
        Log.append(rows)
        Eyes.defaults.set(through, forKey: Self.crashKey)
    }
}
