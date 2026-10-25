import AppKit
import Attribution
import BatteryTraceCore
import Combine
import Sampling

enum HistoryWindow: String, CaseIterable, Identifiable {
    case fiveMinutes, hour, day

    var id: String { rawValue }
    var seconds: TimeInterval {
        switch self {
        case .fiveMinutes: 300
        case .hour: 3600
        case .day: 86400
        }
    }
    var label: String {
        switch self {
        case .fiveMinutes: "5 min"
        case .hour: "1 hour"
        case .day: "24 hours"
        }
    }
}

/// Everything the menu bar and popover show.
///
/// The menu bar reading is kept current always: it is one small struct. The
/// popover's state (the latest report, the window's summary, sparklines) is
/// filled in only while the popover is visible and dropped when it closes, so
/// a closed popover costs no UI work and holds no memory.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var reading: LiveReading?
    @Published private(set) var report: IntervalReport?
    @Published private(set) var summary: WindowSummary?
    @Published private(set) var totalSeries: [Double] = []
    @Published private(set) var componentSeries: [ComponentID: [Double]] = [:]
    @Published var window: HistoryWindow = .fiveMinutes {
        didSet { if window != oldValue { refreshHistory() } }
    }

    let settings: SettingsStore
    let engine: SamplingEngine
    let history: HistoryService

    /// Called whenever the menu bar text may have changed.
    var onMenuBarChange: (() -> Void)?
    /// Every attribution, popover open or not (for notifications).
    var onReport: ((IntervalReport) -> Void)?

    private(set) var isPopoverVisible = false
    private var recentWatts: [Double] = []
    private var reportsSinceRefresh = 0
    private var subscriptions: Set<AnyCancellable> = []

    init(settings: SettingsStore) {
        self.settings = settings
        engine = SamplingEngine(policy: settings.policy)
        engine.setCountsBilledEnergy(settings.countsBilledEnergy)
        history = HistoryService(url: HistoryService.defaultURL)
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                engine.setPolicy(self.settings.policy)
                engine.setCountsBilledEnergy(self.settings.countsBilledEnergy)
                onMenuBarChange?()
            }
            .store(in: &subscriptions)
    }

    func start() {
        let history = history
        engine.start(
            onLive: { [weak self] reading in
                history.record(reading)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(reading) } }
            },
            onReport: { [weak self] report in
                history.record(report)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(report) } }
            }
        )
    }

    // MARK: Popover

    func popoverWillShow() {
        isPopoverVisible = true
        engine.update { $0.popoverVisible = true }
        refreshHistory()
        // Opening forces a fresh report; refresh again as soon as it's recorded.
        reportsSinceRefresh = 4
    }

    func popoverDidClose() {
        isPopoverVisible = false
        engine.update { $0.popoverVisible = false }
        report = nil
        summary = nil
        totalSeries = []
        componentSeries = [:]
    }

    // MARK: Updates from the sampling queue

    private func receive(_ reading: LiveReading) {
        self.reading = reading
        if let watts = reading.systemWatts {
            recentWatts.append(watts)
            if recentWatts.count > 3 { recentWatts.removeFirst() }
        }
        onMenuBarChange?()
    }

    private func receive(_ report: IntervalReport) {
        onReport?(report)
        guard isPopoverVisible else { return }
        self.report = report
        reportsSinceRefresh += 1
        // The window's totals move slowly; refresh them every ~10 s.
        if reportsSinceRefresh >= 5 { refreshHistory() }
    }

    func refreshHistory() {
        reportsSinceRefresh = 0
        guard isPopoverVisible else { return }
        let window = window
        history.summary(since: Date().addingTimeInterval(-window.seconds)) { [weak self] summary in
            MainActor.assumeIsolated {
                guard let self, self.isPopoverVisible, self.window == window else { return }
                self.summary = summary
            }
        }
        history.sparklines(since: Date().addingTimeInterval(-3600), components: SystemSection.sparklineComponents) { [weak self] total, components in
            MainActor.assumeIsolated {
                guard let self, self.isPopoverVisible else { return }
                self.totalSeries = total
                self.componentSeries = components
            }
        }
    }

    // MARK: Menu bar

    /// Live watts, smoothed over the last three readings so the menu bar
    /// doesn't flicker between 4.1 and 4.3.
    var smoothedWatts: Double? {
        recentWatts.isEmpty ? nil : recentWatts.reduce(0, +) / Double(recentWatts.count)
    }

    var menuBarText: String {
        switch settings.menuBarStyle {
        case .batteryPercent:
            if let percent = reading?.battery.percent { return "\(Int(percent.rounded()))%" }
            fallthrough
        case .watts:
            return smoothedWatts.map(Units.menuBarWatts) ?? "–"
        }
    }
}
