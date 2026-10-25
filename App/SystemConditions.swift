import AppKit
import Sampling

/// Tells the engine what the Mac is doing, so it can slow down or stop:
/// system sleep, display sleep, Low Power Mode. All event-driven, no polling.
@MainActor
final class SystemConditions {
    private let engine: SamplingEngine
    private let history: HistoryService
    private var observers: [NSObjectProtocol] = []

    init(engine: SamplingEngine, history: HistoryService) {
        self.engine = engine
        self.history = history
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { [history] in
            engine.update { $0.systemAsleep = true }
            history.flushNow()
        }
        observe(workspace, NSWorkspace.didWakeNotification) {
            engine.update { $0.systemAsleep = false }
        }
        observe(workspace, NSWorkspace.screensDidSleepNotification) {
            engine.update { $0.screensAsleep = true }
        }
        observe(workspace, NSWorkspace.screensDidWakeNotification) {
            engine.update { $0.screensAsleep = false }
        }
        observe(NotificationCenter.default, .NSProcessInfoPowerStateDidChange) {
            let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            engine.update { $0.lowPowerMode = lowPower }
        }
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        engine.update { $0.lowPowerMode = lowPower }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @Sendable () -> Void) {
        observers.append(center.addObserver(forName: name, object: nil, queue: nil) { _ in action() })
    }
}
