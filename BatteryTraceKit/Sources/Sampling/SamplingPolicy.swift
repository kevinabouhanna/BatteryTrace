/// How often to sample, given what the Mac and the user are doing. Pure.
///
/// Every counter Battery Trace reads is cumulative, so sampling less often
/// costs time resolution, not energy: the next reading picks up everything
/// in between. That is what lets it back off hard when nobody is looking.
///
/// Two cadences:
/// - **live**: the total and battery state for the menu bar. Cheap.
/// - **attribution**: every source, split across apps. While the popover is
///   closed this runs once a minute, which is also how often the battery
///   gauge refreshes.
public struct SamplingPolicy: Sendable, Equatable, Codable {
    /// Live readings while the popover is closed (the "Sampling interval"
    /// setting).
    public var closedInterval: Double = 5
    /// While the popover is open, live and attribution both run this often.
    public var openInterval: Double = 2
    /// Attribution while the popover is closed.
    public var closedAttributionInterval: Double = 60
    /// Low Power Mode stretches the closed interval by this much.
    public var lowPowerFactor: Double = 2
    /// While every screen is asleep: just enough to keep history.
    public var screensAsleepInterval: Double = 60

    public init(closedInterval: Double = 5, openInterval: Double = 2) {
        self.closedInterval = closedInterval
        self.openInterval = openInterval
    }

    public struct Conditions: Sendable, Equatable {
        public var popoverVisible = false
        public var lowPowerMode = false
        public var screensAsleep = false
        public var systemAsleep = false
        public init(popoverVisible: Bool = false, lowPowerMode: Bool = false, screensAsleep: Bool = false, systemAsleep: Bool = false) {
            self.popoverVisible = popoverVisible
            self.lowPowerMode = lowPowerMode
            self.screensAsleep = screensAsleep
            self.systemAsleep = systemAsleep
        }
    }

    public struct Schedule: Sendable, Equatable {
        /// Seconds between timer fires. Each fire is a live reading.
        public var interval: Double
        /// How late the kernel may fire the timer, so it can batch our
        /// wakeup with others.
        public var leeway: Double
        /// Every this many fires, run attribution too. 1 = every fire.
        public var attributeEvery: Int
        /// Whether to refresh the System section's detail (per-core load,
        /// memory, brightness), which only the visible popover shows.
        public var detailed: Bool

        public var attributionInterval: Double { interval * Double(attributeEvery) }
    }

    /// Nil: don't sample at all.
    public func schedule(for conditions: Conditions) -> Schedule? {
        if conditions.systemAsleep { return nil }
        let interval: Double
        let attributionInterval: Double
        if conditions.screensAsleep {
            interval = screensAsleepInterval
            attributionInterval = screensAsleepInterval
        } else if conditions.popoverVisible {
            interval = openInterval
            attributionInterval = openInterval
        } else {
            interval = closedInterval * (conditions.lowPowerMode ? lowPowerFactor : 1)
            attributionInterval = max(interval, closedAttributionInterval)
        }
        let clamped = max(0.5, interval)
        return Schedule(
            interval: clamped,
            leeway: max(0.1, clamped * 0.1),
            attributeEvery: max(1, Int((attributionInterval / clamped).rounded())),
            detailed: conditions.popoverVisible && !conditions.screensAsleep
        )
    }
}
