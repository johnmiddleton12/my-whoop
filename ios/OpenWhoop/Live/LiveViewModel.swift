import Foundation
import Combine
import WhoopProtocol

/// Owns the LiveState + BLEManager and exposes intent methods for the LiveView.
@MainActor
public final class LiveViewModel: ObservableObject {
    public let state: LiveState
    private let ble: BLEManager
    private let batteryAlerts = BatteryAlertMonitor()
    private var cancellables = Set<AnyCancellable>()

    /// One-line storage summary for the UI; refreshed periodically from LiveView.
    @Published public var storageSummary: String = "stored: —"

    public init(deviceId: String = "my-whoop") {
        let s = LiveState()
        self.state = s
        self.ble = BLEManager(state: s, deviceId: deviceId)
        // Drive battery alerts off every reading (foreground or background, while the process lives).
        s.onBatteryUpdate = { [batteryAlerts] pct in batteryAlerts.handle(battery: pct) }
        // Request notification permission for all local notifications in one pass — sync nudge and
        // morning recovery. iOS only prompts the user once (subsequent calls are no-ops after the
        // user has decided), so calling both here keeps all auth in one place.
        SyncNudge.requestAuthorization()
        RecoveryNotifier.requestAuthorization()
        s.$lastSyncedAt
            .compactMap { $0 }
            .sink { _ in SyncNudge.reschedule() }
            .store(in: &cancellables)
    }

    /// Wire a callback that fires after a historical offload has been written and local
    /// sleep/daily metrics recomputed. AppRoot uses this to reload MetricsRepository.
    func onHistoricalOffloadComplete(_ handler: @escaping () -> Void) {
        ble.onBackfillComplete = handler
    }

    public func connect()  { ble.connect() }
    public func disconnect() { ble.disconnect() }
    public func startRealtimeHR() { ble.send(.toggleRealtimeHR, payload: [0x01]) }
    public func stopRealtimeHR()  { ble.send(.toggleRealtimeHR, payload: [0x00]) }
    public func getBattery()      { ble.send(.getBatteryLevel,  payload: [0x00]) }

    /// Fire a preset haptic pattern on the strap (makes it buzz). `pattern` indexes the device's
    /// preset patterns; `loops` is the repeat count. Confirmed write so the strap acks it.
    public func runHaptic(pattern: UInt8, loops: UInt8) {
        ble.send(.runHapticsPattern, payload: [pattern, loops, 0, 0, 0], writeType: .withResponse)
    }
    public func stopHaptics() { ble.send(.stopHaptics, payload: [0x00], writeType: .withResponse) }

    /// Fire an immediate alarm-pattern buzz on the strap for testing (M6).
    /// Uses runHapticsPattern(patternId=2, loops=3) + runAlarm — same as the official WHOOP app.
    /// Cannot be verified in the simulator (no strap motor); test on-device only.
    public func testAlarmBuzz() { ble.testAlarmBuzz() }

    /// On-demand bounded raw-accel capture (type-43 IMU) for `seconds`, then auto-stop + upload.
    /// Works even when the research toggle is off — that's the point: a one-off activity sample.
    public func captureActivitySample(seconds: TimeInterval = 30) { ble.captureRawAccel(seconds: seconds) }

    // MARK: - Alarm passthroughs (M6)
    // These delegate directly to the private BLEManager so alarm UI never needs a raw
    // BLEManager reference. SmartAlarmController.schedule() still receives the BLEManager
    // directly (it holds it weakly); we hand it ours via armStrapAlarm(at:).

    /// Arm the strap's firmware alarm for `date`. Also returns the BLEManager so
    /// SmartAlarmController can hold a weak reference to the shared instance.
    @discardableResult
    public func armStrapAlarm(at date: Date) -> BLEManager {
        ble.armStrapAlarm(at: date)
        return ble
    }

    /// Disarm the currently-armed firmware alarm.
    public func disableStrapAlarm() { ble.disableStrapAlarm() }

    /// Request the current alarm time from the strap.
    public func getStrapAlarm() { ble.getStrapAlarm() }

    // MARK: - Lifecycle

    /// Apply raw-outbox retention when the app backgrounds (wired via scenePhase).
    public func onEnterBackground() {
        ble.pruneRaw()
        SyncNudge.reschedule()
    }

    /// App became active — opportunistically sync (rate-limited; won't hammer on rapid toggles).
    public func enterForeground() { ble.requestSync(.foreground) }
    /// User tapped "Sync now" — force an offload regardless of the periodic floor.
    public func syncNow() { ble.requestSync(.manual) }

    /// Refresh the storage summary line from the store (polled every few seconds by LiveView).
    public func refreshStorage() {
        Task { @MainActor in
            guard let s = await ble.storageStats() else { storageSummary = "stored: —"; return }
            let mb = Double(s.rawBytes) / (1024 * 1024)
            storageSummary = String(format: "stored: %d samples · %d raw batches · %.1f MB",
                                    s.decodedRows, s.rawBatches, mb)
        }
    }
}
