import Foundation

/// macOS's own "Maximum Capacity": the battery health figure System Settings
/// and System Information show.
///
/// It isn't the gauge's capacity over its design capacity. Apple works it out
/// from battery data that macOS 27 no longer puts in the registry for apps.
/// On the test Mac it said 80% where `NominalChargeCapacity / DesignCapacity`
/// gave 76%. The function System Information calls for it
/// (`IOPSCopyPowerSourcesByTypePrecise`) answers "not privileged" to anything
/// without Apple's entitlement, so this asks `system_profiler` itself: about
/// 0.3 s, 0.1 s of CPU, at launch and then every 6 hours, never on the caller's
/// thread. Until it answers, or where it has no figure, it's nil.
public final class MacOSBatteryHealth: @unchecked Sendable {
    public static let refreshInterval: TimeInterval = 6 * 3600

    private let lock = NSLock()
    private var percent: Int?
    private var readAt: Date?
    private var reading = false

    /// Starts the first read at once, so the figure is there within a second.
    public init() {
        _ = maximumCapacityPercent
    }

    /// The last figure read, and a background read if it's due.
    public var maximumCapacityPercent: Int? {
        lock.lock()
        defer { lock.unlock() }
        if !reading, readAt.map({ Date().timeIntervalSince($0) >= Self.refreshInterval }) ?? true {
            reading = true
            DispatchQueue.global(qos: .utility).async { [self] in
                let fresh = Self.read()
                lock.lock()
                if let fresh { percent = fresh }
                readAt = Date()
                reading = false
                lock.unlock()
            }
        }
        return percent
    }

    /// Runs `system_profiler SPPowerDataType` and reads the figure from it.
    static func read() -> Int? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPPowerDataType", "-xml", "-detailLevel", "mini"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // It answers in well under a second; one that hangs is left behind.
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15, execute: killer)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return parse(data)
    }

    /// The `sppower_battery_health_maximum_capacity` value ("80%"), wherever
    /// it sits in `system_profiler`'s XML.
    static func parse(_ data: Data) -> Int? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return nil }
        return find(in: plist)
    }

    private static func find(in value: Any) -> Int? {
        switch value {
        case let dictionary as [String: Any]:
            if let text = dictionary["sppower_battery_health_maximum_capacity"] as? String {
                let digits = text.filter(\.isNumber)
                if let percent = Int(digits), (1...150).contains(percent) { return percent }
            }
            for nested in dictionary.values { if let found = find(in: nested) { return found } }
        case let array as [Any]:
            for item in array { if let found = find(in: item) { return found } }
        default:
            break
        }
        return nil
    }
}
