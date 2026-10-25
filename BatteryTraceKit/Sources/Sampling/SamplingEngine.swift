import BatteryTraceCore
import Dispatch
import PowerSources
import Foundation

/// Runs the pipeline on a timer, on its own utility-QoS serial queue.
///
/// One `DispatchSourceTimer` with leeway: no run loop, no busy loop, no
/// per-second work while hidden. The app tells it what's going on
/// (popover open, screens asleep, Low Power Mode) and it re-arms the timer
/// from `SamplingPolicy`. Both handlers are called on the sampling queue; the
/// app decides whether anything visible needs them.
public final class SamplingEngine: @unchecked Sendable {
    public typealias ReportHandler = @Sendable (IntervalReport) -> Void
    public typealias LiveHandler = @Sendable (LiveReading) -> Void

    private let queue = DispatchQueue(label: "app.batterytrace.sampling", qos: .utility)
    // Everything below is touched only on `queue`.
    private let makePipeline: @Sendable () -> SamplingPipeline
    private var pipeline: SamplingPipeline?
    private var timer: DispatchSourceTimer?
    private var policy: SamplingPolicy
    private var conditions = SamplingPolicy.Conditions()
    private var schedule: SamplingPolicy.Schedule?
    private var firesSinceAttribution = 0
    private var onReport: ReportHandler?
    private var onLive: LiveHandler?
    private var countsBilledEnergy = true
    private var displayCalibration: DisplayCalibration?
    private var usesHelper = false

    public init(policy: SamplingPolicy = SamplingPolicy(), makePipeline: @escaping @Sendable () -> SamplingPipeline = { .standard() }) {
        self.policy = policy
        self.makePipeline = makePipeline
    }

    /// Starts sampling. The pipeline is built on the sampling queue, so the
    /// app's launch never waits on IOKit.
    public func start(onLive: @escaping LiveHandler, onReport: @escaping ReportHandler) {
        queue.async {
            self.onLive = onLive
            self.onReport = onReport
            if self.pipeline == nil { self.pipeline = self.makePipeline() }
            self.pipeline?.countsBilledEnergy = self.countsBilledEnergy
            self.pipeline?.display?.use(self.displayCalibration)
            self.pipeline?.privileged?.usesHelper = self.usesHelper
            _ = self.pipeline?.tick(detailed: false) // primes every baseline
            if let reading = self.pipeline?.quickTick() { onLive(reading) }
            self.reschedule()
        }
    }

    public func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.schedule = nil
        }
    }

    public func setPolicy(_ policy: SamplingPolicy) {
        queue.async {
            guard self.policy != policy else { return }
            self.policy = policy
            self.reschedule()
        }
    }

    /// This Mac's measured display curve, or nil for the scaled reference.
    public func setDisplayCalibration(_ calibration: DisplayCalibration?) {
        queue.async {
            self.displayCalibration = calibration
            self.pipeline?.display?.use(calibration)
        }
    }

    /// Whether energy macOS services spend on an app's behalf counts for the app.
    public func setCountsBilledEnergy(_ counts: Bool) {
        queue.async {
            self.countsBilledEnergy = counts
            self.pipeline?.countsBilledEnergy = counts
        }
    }

    /// Whether to use the privileged helper when it is installed. `restart`
    /// starts it afresh, e.g. after it was replaced by a newer version.
    public func setUsesHelper(_ uses: Bool, restart: Bool = false) {
        queue.async {
            self.usesHelper = uses
            guard let privileged = self.pipeline?.privileged else { return }
            if restart { privileged.usesHelper = false }
            privileged.usesHelper = uses
        }
    }

    public func update(_ change: @escaping @Sendable (inout SamplingPolicy.Conditions) -> Void) {
        queue.async {
            var next = self.conditions
            change(&next)
            guard next != self.conditions else { return }
            let woke = self.conditions.systemAsleep && !next.systemAsleep
            let opened = !self.conditions.popoverVisible && next.popoverVisible
            self.conditions = next
            if woke { self.pipeline?.resetBaselines() }
            self.reschedule()
            // Opening the popover deserves fresh numbers now, not in 2 s.
            if opened { self.fire(forceAttribution: true) }
        }
    }

    /// Runs `body` on the sampling queue with the pipeline, e.g. to read a
    /// snapshot for the popover's first frame.
    public func withPipeline(_ body: @escaping @Sendable (SamplingPipeline) -> Void) {
        queue.async {
            if self.pipeline == nil { self.pipeline = self.makePipeline() }
            if let pipeline = self.pipeline { body(pipeline) }
        }
    }

    private func reschedule() {
        let next = policy.schedule(for: conditions)
        guard next != schedule || timer == nil else { return }
        schedule = next
        timer?.cancel()
        timer = nil
        guard let next else { return }
        let source = DispatchSource.makeTimerSource(flags: [], queue: queue)
        let nanoseconds = { (seconds: Double) in DispatchTimeInterval.nanoseconds(Int(seconds * 1e9)) }
        source.schedule(deadline: .now() + nanoseconds(next.interval), repeating: nanoseconds(next.interval), leeway: nanoseconds(next.leeway))
        source.setEventHandler { [weak self] in self?.fire(forceAttribution: false) }
        source.activate()
        timer = source
    }

    private func fire(forceAttribution: Bool) {
        guard let pipeline, let schedule else { return }
        firesSinceAttribution += 1
        if forceAttribution || firesSinceAttribution >= schedule.attributeEvery {
            firesSinceAttribution = 0
            if let report = pipeline.tick(detailed: schedule.detailed) {
                onLive?(LiveReading(uptimeNS: report.endUptimeNS, date: report.endDate,
                                    systemWatts: report.system.liveSystemWatts, battery: report.system.battery))
                onReport?(report)
            } else {
                onLive?(pipeline.quickTick()) // first tick after a reset only primes
            }
        } else {
            onLive?(pipeline.quickTick())
        }
    }
}
