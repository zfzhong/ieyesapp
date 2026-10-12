import BackgroundTasks
import SwiftUI

@main
struct IEyesApp: App {
    @Environment(\.scenePhase) private var phase
    static let refreshTask = "com.zfzhong.ieyesapp.refresh"

    init() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTask, using: nil) { task in
            Self.backgroundRun(task as! BGAppRefreshTask)
        }
    }

    var body: some Scene {
        WindowGroup { ContentView() }
            .onChange(of: phase) { _, p in
                if p == .background { Self.schedule() }
            }
    }

    /// Ask iOS for the next background run. iOS decides when (often 15-60 minutes later);
    /// we ask for no earlier than the group's interval.
    static func schedule() {
        let minutes = max(10, Eyes.defaults.integer(forKey: "tick_minutes"))
        let r = BGAppRefreshTaskRequest(identifier: refreshTask)
        r.earliestBeginDate = Date().addingTimeInterval(Double(minutes) * 60)
        try? BGTaskScheduler.shared.submit(r)
    }

    static func heartbeat(_ reason: String) {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        let state = UIDevice.current.batteryState
        Log.append([Log.row("heartbeat", detail: [
            ("reason", reason),
            ("battery", level >= 0 ? Int(level * 100) : -1),
            ("charging", state == .charging || state == .full ? 1 : 0),
            ("categories", Categories.picked.count),
            ("monitoring", Monitor.monitoring.count),
            ("app", "ios-\(Eyes.appVersion)"),
        ])])
    }

    static func backgroundRun(_ task: BGAppRefreshTask) {
        schedule()
        let work = Task.detached {
            heartbeat("background")
            let ok = Server.upload(wait: 25)
            task.setTaskCompleted(success: ok)
        }
        task.expirationHandler = { work.cancel() }
    }
}
