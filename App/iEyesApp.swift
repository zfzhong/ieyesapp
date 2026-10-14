import BackgroundTasks
import FamilyControls
import SwiftUI
import UserNotifications

@main
struct IEyesApp: App {
    @Environment(\.scenePhase) private var phase
    static let refreshTask = "com.zfzhong.ieyesapp.refresh"

    init() {
        UNUserNotificationCenter.current().delegate = NotificationHandler.shared
        PowerWatch.start()
        Categories.migrateNamedTokens()
        // Keep the ladders armed whenever the app starts (also stops version 0.1's ladders).
        if AuthorizationCenter.shared.authorizationStatus == .approved && !Categories.picked.isEmpty
            && !Eyes.defaults.bool(forKey: "monitoring_stopped") {
            _ = Monitor.armAll()
        }
        Self.motionRun()
        LiveMotion.shared.apply()
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTask, using: nil) { task in
            Self.backgroundRun(task as! BGAppRefreshTask)
        }
    }

    var body: some Scene {
        WindowGroup { ContentView() }
            .onChange(of: phase) { _, p in
                if p == .background { Self.schedule() }
                if p == .active { Monitor.ensureArmed("foreground"); Self.motionRun(); LiveMotion.shared.apply() }
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

    /// 1 when iOS has locked the protected files (phone locked), read straight from iOS.
    /// Added in 0.7 because the lock notifications rarely arrived on a test iPhone (10-13).
    static func lockedNow() -> Int {
        let read = { UIApplication.shared.isProtectedDataAvailable ? 0 : 1 }
        return Thread.isMainThread ? read() : DispatchQueue.main.sync(execute: read)
    }

    static func heartbeat(_ reason: String) {
        Heartbeat.write(reason, extra: [
            ("locked", lockedNow()),
            ("accel", Motion.authorized ? (Motion.enabled ? 1 : 0) : (Motion.denied ? -1 : 0)),
            ("keepalive", LiveMotion.shared.running ? 1 : 0),
            ("location", LiveMotion.authName(LiveMotion.shared.authorization)),
        ])
        Activity.collect()           // iOS's own motion activity (automotive ...) since the last heartbeat
    }

    /// On screen: keep the accelerometer recorder going and read what it has, then upload.
    static func motionRun() {
        guard !Eyes.defaults.bool(forKey: "monitoring_stopped"), !Categories.picked.isEmpty else { return }
        Motion.keepRecording()
        if LiveMotion.shared.running { return }    // live sensors cover it; their tick uploads
        Task.detached(priority: .utility) {
            if Motion.collect(budget: 60) > 0 { _ = Server.upload(wait: 60) }
        }
    }

    static func backgroundRun(_ task: BGAppRefreshTask) {
        schedule()
        let work = Task.detached {
            await MainActor.run { _ = Monitor.ensureArmed("background") }
            heartbeat("background")
            if !Eyes.defaults.bool(forKey: "monitoring_stopped") { Motion.keepRecording() }
            Motion.collect(budget: 12)
            let ok = Server.upload(wait: 25)
            task.setTaskCompleted(success: ok)
        }
        task.expirationHandler = { work.cancel() }
    }
}
