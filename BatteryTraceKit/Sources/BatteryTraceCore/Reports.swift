import Foundation

/// What one row in the Apps list stands for, stable across launches.
///
/// - `app:<bundle path>` for anything inside an `.app` bundle, helpers included
/// - `proc:<executable path>` for a daemon or command-line tool
/// - `name:<command>` when the path is unreadable
/// - `kernel` for `kernel_task`
public struct AppKey: RawRepresentable, Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static func bundle(_ path: String) -> AppKey { AppKey(rawValue: "app:" + path) }
    public static func executable(_ path: String) -> AppKey { AppKey(rawValue: "proc:" + path) }
    public static func command(_ name: String) -> AppKey { AppKey(rawValue: "name:" + name) }
    public static let kernel = AppKey(rawValue: "kernel")

    public var bundlePath: String? { rawValue.hasPrefix("app:") ? String(rawValue.dropFirst(4)) : nil }
    public var executablePath: String? { rawValue.hasPrefix("proc:") ? String(rawValue.dropFirst(5)) : nil }

    public var description: String { rawValue }
    public static func < (a: AppKey, b: AppKey) -> Bool { a.rawValue < b.rawValue }
}

public enum AppKind: UInt8, Sendable, Codable {
    /// Something the user launched: has an `.app` bundle outside /System.
    case app
    /// An Apple app, daemon or agent.
    case system
    case kernel
    /// A tool or daemon from somewhere else.
    case other
}

public struct AppIdentity: Sendable, Hashable, Codable {
    public var key: AppKey
    public var name: String
    public var kind: AppKind
    public var bundleID: String?

    public init(key: AppKey, name: String, kind: AppKind, bundleID: String? = nil) {
        self.key = key
        self.name = name
        self.kind = kind
        self.bundleID = bundleID
    }
}

/// One process's share of an app's CPU energy.
public struct ProcessShare: Sendable, Hashable, Codable {
    public var name: String
    /// Nil for the synthetic "other processes" row.
    public var pid: Int32?
    public var cpuJoules: Double

    public init(name: String, pid: Int32?, cpuJoules: Double) {
        self.name = name
        self.pid = pid
        self.cpuJoules = cpuJoules
    }

    /// Name of the row that holds energy from processes `proc_pid_rusage`
    /// can't read (other users') and from helpers that exited mid-interval.
    public static let otherProcessesName = "Other or exited processes"
}

/// One app's estimated energy over one interval.
public struct AppEnergy: Sendable, Hashable, Codable {
    public var identity: AppIdentity
    /// The raw kernel counters for this app over the interval.
    public var usage: UsageCounters
    public var cpuJoules: Double = 0
    public var gpuJoules: Double = 0
    public var aneJoules: Double = 0
    /// Where this app's CPU energy went, largest first. Empty when unknown.
    public var processes: [ProcessShare] = []
    /// The kernel coalitions merged into this app, for diagnostics and for
    /// matching `powermetrics --show-process-coalition` output.
    public var coalitionIDs: [UInt64] = []

    public init(identity: AppIdentity, usage: UsageCounters, cpuJoules: Double = 0, gpuJoules: Double = 0, aneJoules: Double = 0, processes: [ProcessShare] = [], coalitionIDs: [UInt64] = []) {
        self.identity = identity
        self.usage = usage
        self.coalitionIDs = coalitionIDs
        self.cpuJoules = cpuJoules
        self.gpuJoules = gpuJoules
        self.aneJoules = aneJoules
        self.processes = processes
    }

    public var joules: Double { cpuJoules + gpuJoules + aneJoules }
}

/// Everything known about one sampling interval, attributed.
///
/// Invariant (tested): `apps.joules + systemJoules == totalJoules` whenever a
/// measured total exists. `systemJoules` holds every non-app component,
/// whatever part of CPU, GPU and ANE no app claimed, and Unattributed.
public struct IntervalReport: Sendable, Codable {
    public var endUptimeNS: UInt64
    public var endDate: Date
    public var durationSeconds: Double
    public var onExternalPower: Bool

    /// Measured whole-system energy over the interval, when a sensor gave one.
    public var measuredJoules: Double?
    public var measuredSource: TotalSource?

    public var components: [ComponentEnergy]
    /// Sorted by energy, largest first.
    public var apps: [AppEnergy]
    /// CPU, GPU or ANE energy that no app's counters accounted for.
    public var unclaimedJoules: Double
    /// Measured total minus every component. Wi-Fi, SSD, audio, power conversion.
    /// Nil without a measured total. Never negative: see `overshootJoules`.
    public var unattributedJoules: Double?
    /// How far the components overshot the measured total, when they did.
    /// Reported for validation; the UI shows the total as measured.
    public var overshootJoules: Double

    public var system: SystemSnapshot
    /// A battery-gauge averaging window that completed during this interval.
    public var telemetry: TelemetryWindow?
    /// CPU time Battery Trace itself spent producing this report.
    public var samplingCPUNS: UInt64 = 0
    /// The CPU row is `powermetrics`' figure, from the privileged helper.
    public var cpuFromPowermetrics = false

    public init(endUptimeNS: UInt64, endDate: Date, durationSeconds: Double, onExternalPower: Bool,
                measuredJoules: Double?, measuredSource: TotalSource?, components: [ComponentEnergy],
                apps: [AppEnergy], unclaimedJoules: Double, unattributedJoules: Double?,
                overshootJoules: Double, system: SystemSnapshot, telemetry: TelemetryWindow? = nil) {
        self.endUptimeNS = endUptimeNS
        self.endDate = endDate
        self.durationSeconds = durationSeconds
        self.onExternalPower = onExternalPower
        self.measuredJoules = measuredJoules
        self.measuredSource = measuredSource
        self.components = components
        self.apps = apps
        self.unclaimedJoules = unclaimedJoules
        self.unattributedJoules = unattributedJoules
        self.overshootJoules = overshootJoules
        self.system = system
        self.telemetry = telemetry
    }

    public var componentJoules: Double { components.reduce(0) { $0 + $1.joules } }
    public var appJoules: Double { apps.reduce(0) { $0 + $1.joules } }

    /// The System / Unattributed row: everything that isn't an app.
    public var systemJoules: Double {
        let nonApp = components.filter { $0.id.appSplit == .none }.reduce(0) { $0 + $1.joules }
        return nonApp + unclaimedJoules + (unattributedJoules ?? 0)
    }

    /// The figure the UI calls "total": measured when possible, else the
    /// sum of what the components reported.
    public var totalJoules: Double { appJoules + systemJoules }
    public var totalWatts: Double { durationSeconds > 0 ? totalJoules / durationSeconds : 0 }

    public func joules(for id: ComponentID) -> Double? { components.first { $0.id == id }?.joules }
}
