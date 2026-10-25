import BatteryTraceCore
import Foundation
import IOKit

/// The battery: charge, health, and the gauge's averaged power telemetry.
///
/// Reads `AppleSmartBattery` in the IORegistry. The keys are undocumented but
/// readable by anyone; they vary by model and OS, so each is optional. On a
/// desktop there is no such service and the source is unavailable.
///
/// The gauge refreshes its registry entry about once a minute. Its
/// `PowerTelemetryData` keeps running sums of system load, sampled about once
/// a second, so two readings a refresh apart give the true average over that
/// minute. That average is Battery Trace's ground truth for totals.
public final class BatteryGaugeSource: SnapshotSource, TelemetrySource {
    public let sourceName = "Battery gauge"
    public private(set) var isAvailable = false
    public private(set) var diagnostics: [String] = []

    private let service: io_registry_entry_t
    private let smc: SMCConnection?

    // Created on the first reading of a battery, so a desktop never runs system_profiler.
    private lazy var macOSHealth = MacOSBatteryHealth()
    private var slowFields = SlowFields()
    private var slowFieldsReadAt: UInt64 = 0
    private static let slowFieldsTTL: UInt64 = 300 * 1_000_000_000

    private var lastTelemetry: Telemetry?

    private struct SlowFields {
        var cycleCount: Int?
        var designCapacity: Int?
        var nominalCapacity: Int?
    }

    private struct Telemetry {
        var systemLoadSum: Int64
        var systemLoadCount: Int64
        var batteryPowerSum: Int64?
        var batteryPowerCount: Int64?
        var updateTime: Int64?
    }

    /// - Parameter smc: for battery temperature, which macOS 27 no longer
    ///   puts in the registry. Shared with the live power source.
    init(smc: SMCConnection?) {
        self.smc = smc
        service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else {
            diagnostics.append("no AppleSmartBattery (a desktop Mac?)")
            return
        }
        isAvailable = (number("BatteryInstalled")?.boolValue ?? true)
        if telemetry() != nil {
            diagnostics.append("PowerTelemetryData present: system load is measured on AC and battery")
        } else {
            diagnostics.append("no PowerTelemetryData: totals come from voltage × current on battery only")
        }
    }

    public convenience init(sharing live: SMCSystemPowerSource?) {
        self.init(smc: live?.connection ?? SMCConnection())
    }

    deinit {
        if service != 0 { IOObjectRelease(service) }
    }

    // MARK: SnapshotSource

    /// Everything but charge and plug state is re-read at most this often:
    /// the gauge itself refreshes about once a minute.
    private static let fullReadTTL: UInt64 = 20 * 1_000_000_000
    /// The SMC's battery temperature sensors.
    private static let temperatureKeys = [SMCConnection.fourCC("TB0T"), SMCConnection.fourCC("TB1T"), SMCConnection.fourCC("TB2T")]
    private var lastFullRead: UInt64 = 0
    private var cached = BatterySnapshot()

    public func update(_ snapshot: inout SystemSnapshot) {
        guard isAvailable else { return }
        let now = Clock.uptimeNS()
        var battery = cached
        battery.isPresent = true
        // Cheap and visible at once in the menu bar: every tick.
        if let current = number("CurrentCapacity")?.doubleValue, let max = number("MaxCapacity")?.doubleValue, max > 0 {
            battery.percent = min(100, current / max * 100)
        }
        let wasOnExternalPower = battery.isOnExternalPower
        battery.isOnExternalPower = number("ExternalConnected")?.boolValue ?? false
        battery.isCharging = number("IsCharging")?.boolValue ?? false

        if lastFullRead == 0 || now &- lastFullRead > Self.fullReadTTL || wasOnExternalPower != battery.isOnExternalPower {
            lastFullRead = now
            readFull(into: &battery, now: now)
        }
        // A cached figure, read in the background: as cheap as a lock.
        battery.macOSMaximumCapacityPercent = macOSHealth.maximumCapacityPercent
        cached = battery
        snapshot.battery = battery
    }

    private func readFull(into battery: inout BatterySnapshot, now: UInt64) {
        battery.isFullyCharged = number("FullyCharged")?.boolValue ?? false
        battery.voltageV = number("Voltage").flatMap { $0.int64Value > 0 ? Double($0.int64Value) / 1000 : nil }
        battery.amperageA = (number("InstantAmperage") ?? number("Amperage")).map { Double($0.int64Value) / 1000 }

        func minutes(_ key: String) -> Int? {
            guard let value = number(key)?.intValue, value > 0, value < 65535 else { return nil }
            return value
        }
        battery.minutesToEmpty = battery.isOnExternalPower ? nil : (minutes("TimeRemaining") ?? minutes("AvgTimeToEmpty"))
        battery.minutesToFull = battery.isOnExternalPower && battery.isCharging ? minutes("AvgTimeToFull") : nil

        if slowFieldsReadAt == 0 || now &- slowFieldsReadAt > Self.slowFieldsTTL {
            slowFields = readSlowFields()
            slowFieldsReadAt = now
        }
        battery.cycleCount = slowFields.cycleCount
        battery.designCapacityMAh = slowFields.designCapacity
        battery.nominalCapacityMAh = slowFields.nominalCapacity

        battery.temperatureC = nil
        if let centi = number("Temperature")?.doubleValue, centi > 0 {
            battery.temperatureC = centi / 100
        } else if let smc {
            let readings = Self.temperatureKeys.compactMap { smc.readFloat($0) }.filter { $0 > 0 && $0 < 100 }
            if let hottest = readings.max() { battery.temperatureC = Double(hottest) }
        }
    }

    private func readSlowFields() -> SlowFields {
        var fields = SlowFields()
        fields.cycleCount = number("CycleCount")?.intValue
        let data = property("BatteryData") as? NSDictionary
        fields.designCapacity = (data?["DesignCapacity"] as? NSNumber ?? number("DesignCapacity"))?.intValue
        fields.nominalCapacity = (data?["NominalChargeCapacity"] as? NSNumber ?? number("NominalChargeCapacity") ?? number("AppleRawMaxCapacity"))?.intValue
        return fields
    }

    // MARK: TelemetrySource

    public func resetBaseline() { lastTelemetry = nil }

    public func readTelemetryWindow(nowUptimeNS: UInt64) -> TelemetryWindow? {
        guard isAvailable, let reading = telemetry() else { return nil }
        defer { lastTelemetry = reading }
        guard let last = lastTelemetry else { return nil }

        let samples = reading.systemLoadCount - last.systemLoadCount
        // Zero: not refreshed yet. Negative: the gauge reset; rebase.
        guard samples > 0 else { return nil }
        let averageMilliwatts = Double(reading.systemLoadSum - last.systemLoadSum) / Double(samples)
        guard averageMilliwatts >= 0, averageMilliwatts < 500_000 else { return nil }

        var duration = Double(samples)
        var ageSeconds = 0.0
        if let end = reading.updateTime, let start = last.updateTime, end > start, end - start < 3600 {
            duration = Double(end - start)
            ageSeconds = max(0, Date().timeIntervalSince1970 - Double(end))
        }
        var batteryWatts: Double?
        if let sum = reading.batteryPowerSum, let count = reading.batteryPowerCount,
           let lastSum = last.batteryPowerSum, let lastCount = last.batteryPowerCount {
            batteryWatts = count > lastCount ? Double(sum - lastSum) / Double(count - lastCount) / 1000 : 0
        }
        let endUptime = nowUptimeNS &- UInt64(min(ageSeconds, 120) * 1e9)
        return TelemetryWindow(endUptimeNS: endUptime, durationSeconds: duration,
                               systemLoadWatts: averageMilliwatts / 1000, batteryWatts: batteryWatts)
    }

    private func telemetry() -> Telemetry? {
        guard let data = property("PowerTelemetryData") as? NSDictionary,
              let sum = (data["AccumulatedSystemLoad"] as? NSNumber)?.int64Value,
              let count = (data["SystemLoadAccumulatorCount"] as? NSNumber)?.int64Value
        else { return nil }
        return Telemetry(
            systemLoadSum: sum,
            systemLoadCount: count,
            batteryPowerSum: (data["AccumulatedBatteryPower"] as? NSNumber)?.int64Value,
            batteryPowerCount: (data["BatteryPowerAccumulatorCount"] as? NSNumber)?.int64Value,
            updateTime: number("UpdateTime")?.int64Value
        )
    }

    // MARK: Registry

    private func property(_ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private func number(_ key: String) -> NSNumber? { property(key) as? NSNumber }
}
