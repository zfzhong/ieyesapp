// "Keep running in background": the opt-in mode that lets iEyesApp work like EyesApp on Android.
//
// iOS lets an app keep running in the background while it receives location updates. In this
// mode iEyesApp asks for coarse location (about 3 km; Wi-Fi and cell towers, not GPS) only to
// stay running; it never stores a location. While running it:
//   - reads the accelerometer, gyroscope and magnetometer: 5 samples a second while the phone
//     is unlocked, 1 a second while it is locked;
//   - writes them as motion files of at most 6,000 rows;
//   - uploads every 10 minutes, like Android.
// If iOS stops the app (reboot, swiped away, location turned off), a significant location
// change relaunches it; samples missed meanwhile are filled from the accelerometer recorder
// (CMSensorRecorder), so accel has no gaps, gyro and mag do.
//
// Units and sign follow Android: accel m/s² (face up z ≈ +9.81), gyro rad/s, mag µT (raw,
// not calibrated for hard-iron bias).

import CoreLocation
import CoreMotion
import Foundation
import UIKit

final class LiveMotion: NSObject, CLLocationManagerDelegate {
    static let shared = LiveMotion()

    static var wanted: Bool {
        get { Eyes.defaults.bool(forKey: "keep_alive") }
        set { Eyes.defaults.set(newValue, forKey: "keep_alive") }
    }

    private let location = CLLocationManager()
    private let motion = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "eyes.motion"
        return q
    }()
    private var rows: [String] = []                 // touched only on `queue`
    private var session: AnyObject?                 // CLBackgroundActivitySession (iOS 17+)
    private var timer: Timer?
    private var flushTimer: Timer?
    private(set) var running = false
    private var unlocked = true

    var authorization: CLAuthorizationStatus { location.authorizationStatus }

    override init() {
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        location.distanceFilter = kCLDistanceFilterNone
        location.pausesLocationUpdatesAutomatically = false
        location.activityType = .other
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setUnlocked(true)
        }
        nc.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setUnlocked(false)
        }
    }

    /// Called at launch and when the switch changes.
    func apply() {
        if Self.wanted { start() } else { stop() }
    }

    private func start() {
        switch location.authorizationStatus {
        case .notDetermined:
            location.requestAlwaysAuthorization()
            return                                   // continues in the delegate callback
        case .denied, .restricted:
            Log.append([Log.row("keepalive_denied")])
            return
        default:
            break
        }
        if location.authorizationStatus == .authorizedWhenInUse {
            location.requestAlwaysAuthorization()    // upgrade; works meanwhile while in use
        }
        guard !running else { return }
        running = true
        location.allowsBackgroundLocationUpdates = true
        // Since iOS 16.4, iOS may suspend an app that uses coarse background location together
        // with significant-change monitoring unless the blue location indicator is shown
        // (Apple DTS, developer forums thread 726945). The indicator also tells the
        // participant that iEyesApp is running.
        location.showsBackgroundLocationIndicator = true
        if #available(iOS 17.0, *), session == nil { session = CLBackgroundActivitySession() }
        location.startUpdatingLocation()
        location.startMonitoringSignificantLocationChanges()   // relaunches the app if iOS ends it

        // Fill the gap since the last run from the accelerometer recorder first.
        Motion.collect(budget: 20)
        unlocked = UIApplication.shared.isProtectedDataAvailable
        startSensors()

        Watchdog.requestPermission()
        Watchdog.push()
        flushTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.flush() }
        timer = Timer.scheduledTimer(withTimeInterval: 10 * 60, repeats: true) { [weak self] _ in self?.tick() }
        Log.append([Log.row("keepalive_start", detail: [("location", Self.authName(location.authorizationStatus)),
                                                       ("state", UIApplication.shared.applicationState == .active ? "fg" : "bg"),
                                                       ("gyro", motion.isGyroAvailable ? 1 : 0),
                                                       ("mag", motion.isMagnetometerAvailable ? 1 : 0)])])
        Self.noteDown()
        IEyesApp.heartbeat("keepalive_start")
        Self.markAlive()
        Categories.logNames("start")
    }

    // Outages (0.9, 10-14: iEyesApp stopped on a test iPhone 13:40-17:09, likely swiped away; iOS says
    // nothing about why). Each tick records when keep-running mode was last alive; when keep-running
    // starts again more than downAfter later, an app_down row gives the stretch the app was not running,
    // and whether the phone restarted inside it (uptime shorter than the stretch).
    static let aliveKey = "keepalive_alive_ms"
    static let downAfter: Double = 20 * 60 * 1000

    static func markAlive() {
        Eyes.defaults.set(Date().timeIntervalSince1970 * 1000, forKey: aliveKey)
    }

    static func noteDown() {
        let last = Eyes.defaults.double(forKey: aliveKey)
        let now = Date().timeIntervalSince1970 * 1000
        guard last > 0, now - last > downAfter else { return }
        let uptime = ProcessInfo.processInfo.systemUptime * 1000
        Log.append([Log.row("app_down", detail: [("from_ms", Int64(last)), ("to_ms", Int64(now)),
                                                 ("minutes", Int((now - last) / 60000)),
                                                 ("rebooted", uptime < now - last ? 1 : 0),
                                                 ("uptime_s", Int(uptime / 1000))])])
    }

    private func stop() {
        guard running else { return }
        running = false
        motion.stopAccelerometerUpdates()
        motion.stopGyroUpdates()
        motion.stopMagnetometerUpdates()
        location.stopUpdatingLocation()
        location.stopMonitoringSignificantLocationChanges()
        location.allowsBackgroundLocationUpdates = false
        if #available(iOS 17.0, *) { (session as? CLBackgroundActivitySession)?.invalidate() }
        session = nil
        timer?.invalidate(); timer = nil
        flushTimer?.invalidate(); flushTimer = nil
        flush()
        Watchdog.cancel()
        Eyes.defaults.removeObject(forKey: Self.aliveKey)   // turned off on purpose: not an outage
        Log.append([Log.row("keepalive_stop")])
    }

    // MARK: sensors

    private var interval: TimeInterval { unlocked ? 0.2 : 1.0 }

    private func setUnlocked(_ on: Bool) {
        guard on != unlocked else { return }
        unlocked = on
        if running { startSensors() }
    }

    private func startSensors() {
        motion.stopAccelerometerUpdates()
        motion.stopGyroUpdates()
        motion.stopMagnetometerUpdates()
        let dt = interval
        // CMLogItem.timestamp is seconds since boot, the same clock as systemUptime.
        let bootToWall = { (t: TimeInterval) -> Int64 in
            Int64((Date().timeIntervalSince1970 - (ProcessInfo.processInfo.systemUptime - t)) * 1000)
        }
        if motion.isAccelerometerAvailable {
            motion.accelerometerUpdateInterval = dt
            motion.startAccelerometerUpdates(to: queue) { [weak self] d, _ in
                guard let d else { return }
                let k = -9.80665
                self?.add(bootToWall(d.timestamp), "accel", d.acceleration.x * k, d.acceleration.y * k, d.acceleration.z * k)
            }
        }
        if motion.isGyroAvailable {
            motion.gyroUpdateInterval = dt
            motion.startGyroUpdates(to: queue) { [weak self] d, _ in
                guard let d else { return }
                self?.add(bootToWall(d.timestamp), "gyro", d.rotationRate.x, d.rotationRate.y, d.rotationRate.z)
            }
        }
        if motion.isMagnetometerAvailable {
            motion.magnetometerUpdateInterval = dt
            motion.startMagnetometerUpdates(to: queue) { [weak self] d, _ in
                guard let d else { return }
                self?.add(bootToWall(d.timestamp), "mag", d.magneticField.x, d.magneticField.y, d.magneticField.z)
            }
        }
        Log.append([Log.row("motion_rate", detail: [("hz", Int((1 / dt).rounded())), ("unlocked", unlocked ? 1 : 0)])])
    }

    /// Runs on `queue`.
    private func add(_ ms: Int64, _ sensor: String, _ x: Double, _ y: Double, _ z: Double) {
        rows.append(String(format: "%lld,%@,%.4f,%.4f,%.4f", ms, sensor, x, y, z))
        if rows.count >= Motion.maxRowsPerChunk { writeRows() }
    }

    /// Runs on `queue`: hands the buffered rows to the open motion file.
    private func writeRows() {
        guard !rows.isEmpty else { return }
        let batch = rows
        rows.removeAll(keepingCapacity: true)
        Motion.appendLive(batch)
    }

    /// Every minute (main thread): the lock state read straight from iOS. If the lock
    /// notifications were missed (seen on a test iPhone, 10-13), log it and fix the rate.
    private func checkLock() {
        let now = UIApplication.shared.isProtectedDataAvailable
        guard now != unlocked else { return }
        Log.append([Log.row("lock_missed", detail: [("unlocked", now ? 1 : 0)])])
        setUnlocked(now)
    }

    /// Every minute: buffered rows to disk, and the recorder no longer needs to cover this time.
    private func flush() {
        if Thread.isMainThread && running { checkLock() }
        queue.addOperation { [weak self] in
            self?.writeRows()
            Motion.markLiveThrough(Date())
        }
    }

    private var lastTick = Date()

    /// Every 10 minutes: heartbeat, close files, upload.
    private func tick() {
        let late = Date().timeIntervalSince(lastTick) - 600
        lastTick = Date()
        if late > 60 { Log.append([Log.row("keepalive_late", detail: [("late_s", Int(late))])]) }
        Watchdog.push()                      // still alive: move the "stopped" warning 30 min ahead
        Self.markAlive()
        flush()
        queue.addOperation {
            // Upload off the sensor queue so samples keep flowing while it runs.
            DispatchQueue.global(qos: .utility).async {
                DispatchQueue.main.sync { _ = Monitor.ensureArmed("keepalive") }
                IEyesApp.heartbeat("keepalive")
                Motion.closeOpen()
                Server.upload(wait: 60, force: false)
            }
        }
    }

    // MARK: location (used only to keep running; never stored)

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Log.append([Log.row("location_auth", detail: [("status", Self.authName(manager.authorizationStatus))])])
        if Self.wanted { start() }
        NotificationCenter.default.post(name: .eyesStateChanged, object: nil)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    static func authName(_ s: CLAuthorizationStatus) -> String {
        switch s {
        case .authorizedAlways: return "always"
        case .authorizedWhenInUse: return "when_in_use"
        case .denied: return "denied"
        case .restricted: return "restricted"
        default: return "not_asked"
        }
    }
}

extension Notification.Name {
    static let eyesStateChanged = Notification.Name("eyesStateChanged")
}
