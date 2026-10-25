import AppKit
import PowerSources

/// Runs Settings › Calibrate… off the main thread and reports progress.
@MainActor
final class DisplayCalibrationController: ObservableObject {
    enum State: Equatable {
        case idle
        case running(step: Int, of: Int)
        case finished(DisplayCalibration)
        case tooNoisy
        case failed
    }

    @Published private(set) var state: State = .idle
    let isAvailable: Bool
    private let settings: SettingsStore
    private let cancelFlag = CancelFlag()

    init(settings: SettingsStore) {
        self.settings = settings
        isAvailable = DisplayCalibrator() != nil
    }

    /// Confirms first: it changes the display's brightness for a minute.
    func start() {
        let alert = NSAlert()
        alert.messageText = "Calibrate the display estimate?"
        alert.informativeText = "For under two minutes, the built-in display dims and brightens while Battery Trace watches the Mac's power. "
            + "Leave the Mac idle until it's done. Your brightness is put back afterwards."
        alert.addButton(withTitle: "Calibrate")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        cancelFlag.isCancelled = false
        state = .running(step: 0, of: DisplayCalibrator.levels.count)
        let flag = cancelFlag
        DispatchQueue.global(qos: .userInitiated).async {
            let result = DisplayCalibrator()?.run(
                progress: { step, steps in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self.state = .running(step: step, of: steps) } }
                },
                cancelled: { flag.isCancelled })
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if flag.isCancelled {
                        self.state = .idle
                    } else if let result, result.isTrustworthy {
                        self.settings.displayCalibration = result
                        self.state = .finished(result)
                    } else {
                        self.state = result == nil ? .failed : .tooNoisy
                    }
                }
            }
        }
    }

    func cancel() { cancelFlag.isCancelled = true }

    func reset() {
        settings.displayCalibration = nil
        state = .idle
    }
}

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
