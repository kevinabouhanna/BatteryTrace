import Foundation

/// The conversation between Battery Trace and its optional root helper.
///
/// The helper is started as `sudo -n <helperPath> serve` and talks over its
/// own stdin and stdout, one line per message. Nothing else can reach it: there
/// is no socket and no Mach service, so the only process that can use a
/// running helper is the one that started it. When that process quits or
/// crashes, stdin closes and the helper exits.
///
/// Requests (app → helper):
///
///     power <seq>                 a powermetrics sample since the previous one
///     rusage <seq> <pid> <pid>…   proc_pid_rusage for these PIDs
///
/// Replies (helper → app) echo the sequence number, so a reply that arrives
/// after the app gave up waiting is recognised and dropped:
///
///     power <seq> <elapsed ns> <cpu mJ> <gpu mJ> <ane mJ>
///     power <seq> -               no sample (powermetrics missing or slow)
///     rusage <seq> <record> <record>…
///     error <reason>
///
/// Here, in the module both sides link, so the two cannot disagree.
public enum HelperProtocol {
    /// Bump whenever the helper gains a request, changes what one returns, or
    /// its sudoers rule changes. The app uses only a helper of exactly its own
    /// version, and offers to update an older one.
    ///
    /// - 1: `status`, `serve` with `power` and `rusage`.
    public static let version = 1

    public static let helperName = "app.batterytrace.helper"
    public static let helperPath = "/Library/PrivilegedHelperTools/\(helperName)"
    /// No dot in the file name: `sudo`'s `#includedir` skips any file in
    /// `sudoers.d` whose name contains one, and would silently grant nothing.
    public static let sudoersPath = "/etc/sudoers.d/batterytrace"

    /// The most PIDs one `rusage` request may name.
    public static let maxPIDsPerRequest = 4096
}

/// What `<helper> status` prints, as one line of JSON.
public struct HelperStatus: Codable, Equatable, Sendable {
    public var version: Int
    /// Whether it ran as root, i.e. the sudoers rule worked.
    public var root: Bool

    public init(version: Int, root: Bool) {
        self.version = version
        self.root = root
    }

    public var line: String {
        "{\"version\":\(version),\"root\":\(root)}"
    }

    public static func parse(_ text: String) -> HelperStatus? {
        guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(HelperStatus.self, from: data)
    }
}

public enum HelperRequest: Equatable, Sendable {
    case power(seq: UInt32)
    case rusage(seq: UInt32, pids: [Int32])

    public var seq: UInt32 {
        switch self {
        case .power(let seq), .rusage(let seq, _): seq
        }
    }

    public var line: String {
        switch self {
        case .power(let seq):
            "power \(seq)"
        case .rusage(let seq, let pids):
            pids.isEmpty ? "rusage \(seq)" : "rusage \(seq) " + pids.map(String.init).joined(separator: " ")
        }
    }

    /// Strict: anything but the two shapes above, or more PIDs than allowed,
    /// is nil. This runs as root, on input from another process.
    public static func parse<S: StringProtocol>(_ line: S) -> HelperRequest? {
        let words = line.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count >= 2, let seq = UInt32(words[1]) else { return nil }
        switch words[0] {
        case "power":
            return words.count == 2 ? .power(seq: seq) : nil
        case "rusage":
            guard words.count - 2 <= HelperProtocol.maxPIDsPerRequest else { return nil }
            var pids: [Int32] = []
            pids.reserveCapacity(words.count - 2)
            for word in words.dropFirst(2) {
                guard let pid = Int32(word), pid >= 0 else { return nil }
                pids.append(pid)
            }
            return .rusage(seq: seq, pids: pids)
        default:
            return nil
        }
    }
}

/// One `powermetrics` sample: energy since the previous one.
public struct PowerReading: Equatable, Sendable {
    public var elapsedNS: UInt64
    public var cpuMillijoules: Double
    public var gpuMillijoules: Double
    public var aneMillijoules: Double

    public init(elapsedNS: UInt64, cpuMillijoules: Double, gpuMillijoules: Double, aneMillijoules: Double) {
        self.elapsedNS = elapsedNS
        self.cpuMillijoules = cpuMillijoules
        self.gpuMillijoules = gpuMillijoules
        self.aneMillijoules = aneMillijoules
    }

    public var elapsedSeconds: Double { Double(elapsedNS) / 1e9 }
}

/// `proc_pid_rusage` for one process, as the helper read it. Times are in
/// Mach absolute-time units, as the kernel gives them.
public struct RootRusage: Equatable, Sendable {
    public var pid: Int32
    public var startAbstime: UInt64
    public var energyNJ: UInt64
    public var userTime: UInt64
    public var systemTime: UInt64
    public var interruptWakeups: UInt64
    public var idleWakeups: UInt64
    public var diskReadBytes: UInt64
    public var diskWriteBytes: UInt64
    public var footprintBytes: UInt64

    public init(pid: Int32, startAbstime: UInt64, energyNJ: UInt64, userTime: UInt64, systemTime: UInt64,
                interruptWakeups: UInt64, idleWakeups: UInt64, diskReadBytes: UInt64, diskWriteBytes: UInt64,
                footprintBytes: UInt64) {
        self.pid = pid
        self.startAbstime = startAbstime
        self.energyNJ = energyNJ
        self.userTime = userTime
        self.systemTime = systemTime
        self.interruptWakeups = interruptWakeups
        self.idleWakeups = idleWakeups
        self.diskReadBytes = diskReadBytes
        self.diskWriteBytes = diskWriteBytes
        self.footprintBytes = footprintBytes
    }

    /// `pid:start:energy:user:system:interrupt:idle:read:write:footprint`
    var field: String {
        "\(pid):\(startAbstime):\(energyNJ):\(userTime):\(systemTime):\(interruptWakeups):\(idleWakeups):\(diskReadBytes):\(diskWriteBytes):\(footprintBytes)"
    }

    init?<S: StringProtocol>(field: S) {
        let parts = field.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 10, let pid = Int32(parts[0]) else { return nil }
        var values: [UInt64] = []
        values.reserveCapacity(9)
        for part in parts.dropFirst() {
            guard let value = UInt64(part) else { return nil }
            values.append(value)
        }
        self.init(pid: pid, startAbstime: values[0], energyNJ: values[1], userTime: values[2], systemTime: values[3],
                  interruptWakeups: values[4], idleWakeups: values[5], diskReadBytes: values[6],
                  diskWriteBytes: values[7], footprintBytes: values[8])
    }
}

public enum HelperReply: Equatable, Sendable {
    case power(seq: UInt32, PowerReading?)
    case rusage(seq: UInt32, [RootRusage])
    case error(String)

    public var seq: UInt32? {
        switch self {
        case .power(let seq, _), .rusage(let seq, _): seq
        case .error: nil
        }
    }

    public var line: String {
        switch self {
        case .power(let seq, nil):
            return "power \(seq) -"
        case .power(let seq, let reading?):
            return "power \(seq) \(reading.elapsedNS) \(reading.cpuMillijoules) \(reading.gpuMillijoules) \(reading.aneMillijoules)"
        case .rusage(let seq, let records):
            return records.isEmpty ? "rusage \(seq)" : "rusage \(seq) " + records.map(\.field).joined(separator: " ")
        case .error(let reason):
            return "error " + reason.replacingOccurrences(of: "\n", with: " ")
        }
    }

    public static func parse<S: StringProtocol>(_ line: S) -> HelperReply? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("error ") { return .error(String(trimmed.dropFirst(6))) }
        let words = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count >= 2, let seq = UInt32(words[1]) else { return nil }
        switch words[0] {
        case "power":
            if words.count == 3, words[2] == "-" { return .power(seq: seq, nil) }
            guard words.count == 6, let elapsed = UInt64(words[2]),
                  let cpu = Double(words[3]), let gpu = Double(words[4]), let ane = Double(words[5]),
                  [cpu, gpu, ane].allSatisfy({ $0.isFinite && $0 >= 0 })
            else { return nil }
            return .power(seq: seq, PowerReading(elapsedNS: elapsed, cpuMillijoules: cpu, gpuMillijoules: gpu, aneMillijoules: ane))
        case "rusage":
            var records: [RootRusage] = []
            records.reserveCapacity(words.count - 2)
            for word in words.dropFirst(2) {
                guard let record = RootRusage(field: word) else { return nil }
                records.append(record)
            }
            return .rusage(seq: seq, records)
        default:
            return nil
        }
    }
}

/// Reads one sample of `powermetrics -f plist` output.
public enum PowermetricsPlist {
    /// One NUL-separated sample (the separator already removed). Nil if it
    /// isn't a sample, or has no CPU figure.
    public static func reading(from data: Data) -> PowerReading? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let elapsed = number(plist["elapsed_ns"]), elapsed > 0,
              let processor = plist["processor"] as? [String: Any]
        else { return nil }
        let seconds = elapsed / 1e9
        // Energy in mJ where powermetrics gives it; otherwise its average
        // power (mW) over the sample.
        func energy(_ name: String) -> Double? {
            if let mJ = number(processor["\(name)_energy"]) { return mJ }
            return number(processor["\(name)_power"]).map { $0 * seconds }
        }
        guard let cpu = energy("cpu"), cpu >= 0 else { return nil }
        return PowerReading(elapsedNS: UInt64(elapsed), cpuMillijoules: cpu,
                            gpuMillijoules: max(0, energy("gpu") ?? 0), aneMillijoules: max(0, energy("ane") ?? 0))
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber: n.doubleValue
        case let d as Double: d
        case let i as Int: Double(i)
        default: nil
        }
    }
}
