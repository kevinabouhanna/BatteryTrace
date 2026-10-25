import BatteryTraceCore

/// Raw usage for one app over one interval, before any watts are assigned.
public struct AppUsage: Sendable, Hashable {
    public var identity: AppIdentity
    /// Sum of the app's coalitions (or processes, without coalitions).
    public var usage: UsageCounters
    /// Processes whose own counters were readable, with their CPU energy.
    public var processes: [ProcessUsage]
    /// Live members whose counters `proc_pid_rusage` refused (other users').
    public var unreadableProcessCount: Int
    public var coalitionIDs: [UInt64] = []

    public init(identity: AppIdentity, usage: UsageCounters, processes: [ProcessUsage] = [], unreadableProcessCount: Int = 0, coalitionIDs: [UInt64] = []) {
        self.identity = identity
        self.coalitionIDs = coalitionIDs
        self.usage = usage
        self.processes = processes
        self.unreadableProcessCount = unreadableProcessCount
    }
}

public struct ProcessUsage: Sendable, Hashable {
    public var pid: Int32
    public var name: String
    public var cpuEnergyNJ: UInt64

    public init(pid: Int32, name: String, cpuEnergyNJ: UInt64) {
        self.pid = pid
        self.name = name
        self.cpuEnergyNJ = cpuEnergyNJ
    }
}

/// Groups processes into apps.
///
/// With coalitions (the normal case), the kernel already did the grouping:
/// Chrome's helpers, Safari's WebContent processes and an Electron app's
/// renderers sit in their app's coalition. This names each coalition and
/// merges coalitions of the same `.app` bundle (an app's launchd-started
/// helpers get their own coalition).
///
/// Without coalitions, each process is placed by the app at the top of its
/// process chain, or failing that by its own path.
///
/// Runs every tick over every process, so names are cached per coalition and
/// recomputed only when its lowest PID (its likely leader) changes.
public struct AppGrouper: Sendable {
    /// The name and bundle ID for an `.app` path. Injected: reading
    /// Info.plist is I/O, and this type stays pure.
    public typealias BundleNamer = @Sendable (String) -> (name: String, bundleID: String?)

    private let bundleNamer: BundleNamer

    private struct CachedName {
        var identity: AppIdentity
        /// The lowest live PID when the name was worked out.
        var leader: Int32
    }

    private struct Tally {
        var leader: Int32 = .max
        var members = 0
        var app = -1
    }

    /// Names of coalitions seen before. Also covers intervals in which every
    /// member exited before the interval ended.
    private var names: [UInt64: CachedName] = [:]
    private var tallies: [UInt64: Tally] = [:]
    private var slots: [AppKey: Int] = [:]

    public init(bundleNamer: @escaping BundleNamer = AppGrouper.fileNameBundleNamer) {
        self.bundleNamer = bundleNamer
    }

    public static let fileNameBundleNamer: BundleNamer = { path in
        let file = path.split(separator: "/").last.map(String.init) ?? path
        return (file.hasSuffix(".app") ? String(file.dropLast(4)) : file, nil)
    }

    /// - Parameters:
    ///   - processes: every live process at the end of the interval
    ///   - coalitions: usage per coalition over the interval; empty if
    ///     coalitions are unavailable
    ///   - processDeltas: usage per PID over the interval, where readable
    public mutating func group(processes: [ProcessRecord], coalitions: [UInt64: UsageCounters],
                               processDeltas: [Int32: UsageCounters]) -> [AppUsage] {
        guard !coalitions.isEmpty else { return groupWithoutCoalitions(processes: processes, processDeltas: processDeltas) }

        var apps: [AppUsage] = []
        apps.reserveCapacity(min(coalitions.count, 256))
        slots.removeAll(keepingCapacity: true)
        tallies.removeAll(keepingCapacity: true)

        // Pass 1: each coalition's lowest PID, which decides whether its cached name still holds.
        for process in processes where process.coalitionID != 0 {
            tallies[process.coalitionID, default: Tally()].members += 1
            if process.pid < tallies[process.coalitionID]!.leader { tallies[process.coalitionID]!.leader = process.pid }
        }

        // Coalitions whose name is unknown or stale: gather just their members.
        var stale: [UInt64: [ProcessRecord]] = [:]
        for (id, tally) in tallies where coalitions[id] != nil {
            if let cached = names[id], cached.leader == tally.leader { continue }
            stale[id] = []
        }
        if !stale.isEmpty {
            for process in processes where stale[process.coalitionID] != nil { stale[process.coalitionID]!.append(process) }
            for (id, members) in stale {
                names[id] = CachedName(identity: identify(coalition: id, members: members), leader: tallies[id]!.leader)
            }
        }

        // Pass 2: one app per name, summing its coalitions.
        for (id, usage) in coalitions {
            guard let name = names[id] else { continue } // never seen alive: nothing to call it
            let slot = slot(for: name.identity, in: &apps)
            apps[slot].usage += usage
            apps[slot].coalitionIDs.append(id)
            tallies[id, default: Tally()].app = slot
        }

        // Pass 3: each app's processes, for the child rows. A process whose
        // coalition used nothing this interval has nothing to report.
        for process in processes {
            guard process.coalitionID != 0, let slot = tallies[process.coalitionID]?.app, slot >= 0 else { continue }
            if let delta = processDeltas[process.pid] {
                if delta.cpuEnergyNJ > 0 {
                    apps[slot].processes.append(ProcessUsage(pid: process.pid, name: process.name, cpuEnergyNJ: delta.cpuEnergyNJ))
                }
            } else {
                apps[slot].unreadableProcessCount += 1
            }
        }

        // Reaped coalitions never come back. Forget them now and then.
        if names.count > tallies.count + 512 {
            names = names.filter { tallies[$0.key] != nil || coalitions[$0.key] != nil }
        }
        return apps
    }

    private mutating func slot(for identity: AppIdentity, in apps: inout [AppUsage]) -> Int {
        if let existing = slots[identity.key] { return existing }
        apps.append(AppUsage(identity: identity, usage: .zero))
        slots[identity.key] = apps.count - 1
        return apps.count - 1
    }

    private mutating func groupWithoutCoalitions(processes: [ProcessRecord], processDeltas: [Int32: UsageCounters]) -> [AppUsage] {
        var apps: [AppUsage] = []
        slots.removeAll(keepingCapacity: true)
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        for process in processes {
            let slot = slot(for: identify(process: process, ancestors: byPID), in: &apps)
            if let delta = processDeltas[process.pid] {
                apps[slot].usage += delta
                if delta.cpuEnergyNJ > 0 {
                    apps[slot].processes.append(ProcessUsage(pid: process.pid, name: process.name, cpuEnergyNJ: delta.cpuEnergyNJ))
                }
            } else {
                apps[slot].unreadableProcessCount += 1
            }
        }
        return apps
    }

    // MARK: Naming

    func identify(coalition id: UInt64, members: [ProcessRecord]) -> AppIdentity {
        if id == CoalitionRecord.kernelCoalitionID {
            return AppIdentity(key: .kernel, name: "kernel_task", kind: .kernel)
        }
        let sorted = members.sorted { $0.pid < $1.pid }
        if let bundle = sorted.lazy.compactMap({ $0.path.flatMap { Self.outermostBundle(of: $0) } }).first {
            return bundleIdentity(bundle)
        }
        guard let leader = sorted.first else {
            return AppIdentity(key: .command("coalition \(id)"), name: "coalition \(id)", kind: .other)
        }
        return executableIdentity(leader)
    }

    /// Without coalitions: the app that started this process's chain. Walk up
    /// to the ancestor just below launchd; if it is an app, the process is its
    /// (a tool run in Terminal counts for Terminal even if it lives inside
    /// Xcode.app). Otherwise the process's own bundle, else its executable.
    func identify(process: ProcessRecord, ancestors: [Int32: ProcessRecord]) -> AppIdentity {
        if process.pid == 0 { return AppIdentity(key: .kernel, name: "kernel_task", kind: .kernel) }
        var root = process
        var hops = 0
        while root.parentPID > 1, root.parentPID != root.pid, let parent = ancestors[root.parentPID], hops < 64 {
            root = parent
            hops += 1
        }
        if root.pid != process.pid, let bundle = root.path.flatMap({ Self.outermostBundle(of: $0) }) {
            return bundleIdentity(bundle)
        }
        if let bundle = process.path.flatMap({ Self.outermostBundle(of: $0) }) { return bundleIdentity(bundle) }
        return executableIdentity(process)
    }

    private func bundleIdentity(_ bundlePath: String) -> AppIdentity {
        let (name, bundleID) = bundleNamer(bundlePath)
        return AppIdentity(key: .bundle(bundlePath), name: name, kind: Self.kind(ofBundle: bundlePath), bundleID: bundleID)
    }

    private func executableIdentity(_ process: ProcessRecord) -> AppIdentity {
        if let path = process.path, !path.isEmpty {
            return AppIdentity(key: .executable(path), name: process.name, kind: Self.kind(ofExecutable: path))
        }
        return AppIdentity(key: .command(process.name), name: process.name, kind: .other)
    }

    /// The outermost `.app` in a path: helpers nested inside an app's
    /// frameworks belong to the app, not to their own little bundle.
    ///
    ///     /Applications/Google Chrome.app/Contents/Frameworks/…/Google Chrome Helper.app/Contents/MacOS/…
    ///     → /Applications/Google Chrome.app
    public static func outermostBundle(of path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    /// Apps live anywhere; macOS's own UI agents (Dock, Finder, Control
    /// Center) live under /System/Library.
    static func kind(ofBundle path: String) -> AppKind {
        path.hasPrefix("/System/Library/") ? .system : .app
    }

    static func kind(ofExecutable path: String) -> AppKind {
        let systemRoots = ["/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/", "/private/var/db/"]
        return systemRoots.contains { path.hasPrefix($0) } ? .system : .other
    }
}
