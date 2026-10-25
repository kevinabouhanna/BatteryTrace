import Foundation

/// The battery as the gauge reports it. Every field is optional because
/// desktops have no battery and the gauge's keys vary by model.
public struct BatterySnapshot: Sendable, Hashable, Codable {
    public var isPresent = false
    public var percent: Double?
    public var isCharging = false
    public var isOnExternalPower = false
    public var isFullyCharged = false
    public var minutesToEmpty: Int?
    public var minutesToFull: Int?
    public var cycleCount: Int?
    public var designCapacityMAh: Int?
    /// What the battery holds when full today, as macOS rates it.
    public var nominalCapacityMAh: Int?
    public var temperatureC: Double?
    public var voltageV: Double?
    /// Negative while discharging.
    public var amperageA: Double?

    public init() {}

    /// Capacity relative to new. Matches "Maximum Capacity" in System Settings.
    public var healthPercent: Double? {
        guard let design = designCapacityMAh, design > 0, let nominal = nominalCapacityMAh else { return nil }
        return Double(nominal) / Double(design) * 100
    }

    /// Battery voltage × current while discharging. The gauge refreshes about
    /// once a minute, so this lags sudden changes.
    public var dischargeWatts: Double? {
        guard isPresent, !isOnExternalPower, let v = voltageV, let a = amperageA, a < 0 else { return nil }
        return v * -a
    }
}

/// One averaging window from the battery gauge's power telemetry.
///
/// The gauge samples system load about once a second and keeps a running
/// sum. Two readings of that sum, a refresh apart, give the true average
/// over the window. That average is the ground truth for totals.
public struct TelemetryWindow: Sendable, Hashable, Codable {
    /// When the window ended, on the engine's uptime clock.
    public var endUptimeNS: UInt64
    public var durationSeconds: Double
    /// Everything the Mac consumed, whether from the adapter or the battery.
    public var systemLoadWatts: Double
    /// Power out of the battery. 0 on AC.
    public var batteryWatts: Double?

    public init(endUptimeNS: UInt64, durationSeconds: Double, systemLoadWatts: Double, batteryWatts: Double?) {
        self.endUptimeNS = endUptimeNS
        self.durationSeconds = durationSeconds
        self.systemLoadWatts = systemLoadWatts
        self.batteryWatts = batteryWatts
    }

    public var startUptimeNS: UInt64 { endUptimeNS &- UInt64(durationSeconds * 1e9) }
}

public enum MemoryPressure: UInt8, Sendable, Codable {
    case normal, warning, critical
}

public struct MemorySnapshot: Sendable, Hashable, Codable {
    public var totalBytes: UInt64 = 0
    /// Activity Monitor's "Memory Used": app memory + wired + compressed.
    public var usedBytes: UInt64 = 0
    public var appBytes: UInt64 = 0
    public var wiredBytes: UInt64 = 0
    public var compressedBytes: UInt64 = 0
    public var swapUsedBytes: UInt64 = 0
    public var pressure: MemoryPressure = .normal

    public init() {}
}

public enum ThermalLevel: UInt8, Sendable, Codable {
    case nominal, fair, serious, critical

    public var label: String {
        switch self {
        case .nominal: "Normal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        }
    }
}

public struct CPULoadSnapshot: Sendable, Hashable, Codable {
    /// Busy fraction per logical core, 0…1, over the last interval.
    public var perCore: [Double] = []
    public init(perCore: [Double] = []) { self.perCore = perCore }
    public var average: Double { perCore.isEmpty ? 0 : perCore.reduce(0, +) / Double(perCore.count) }
}

public struct DisplaySnapshot: Sendable, Hashable, Codable {
    /// The brightness slider, 0…1. Perceptual, not linear in light or power.
    public var brightness: Double?
    /// Backlight current as a fraction of its maximum, 0…1. Roughly linear in light.
    public var backlightFraction: Double?
    /// Our model's backlight power. Always an estimate.
    public var estimatedBacklightWatts: Double?
    /// Whether the model was measured on this Mac rather than scaled from
    /// the reference panel.
    public var calibratedOnThisMac = false

    public init(brightness: Double? = nil, backlightFraction: Double? = nil, estimatedBacklightWatts: Double? = nil) {
        self.brightness = brightness
        self.backlightFraction = backlightFraction
        self.estimatedBacklightWatts = estimatedBacklightWatts
    }
}

/// Everything about the system that isn't energy, for the System section.
public struct SystemSnapshot: Sendable, Hashable, Codable {
    public var battery = BatterySnapshot()
    public var cpuLoad = CPULoadSnapshot()
    public var memory = MemorySnapshot()
    public var display = DisplaySnapshot()
    public var thermal: ThermalLevel = .nominal
    public var lowPowerMode = false
    /// Live system power in watts, when a sensor gives it.
    public var liveSystemWatts: Double?

    public init() {}
}

/// What the menu bar shows, read every few seconds.
public struct LiveReading: Sendable, Hashable, Codable {
    public var uptimeNS: UInt64
    public var date: Date
    /// Whole-system power right now, when a sensor gives it.
    public var systemWatts: Double?
    public var battery: BatterySnapshot

    public init(uptimeNS: UInt64, date: Date, systemWatts: Double?, battery: BatterySnapshot) {
        self.uptimeNS = uptimeNS
        self.date = date
        self.systemWatts = systemWatts
        self.battery = battery
    }
}
