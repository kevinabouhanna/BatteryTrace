import BatteryTraceCore
import Foundation

/// Splits measured component energy across apps. Pure; see docs/ATTRIBUTION.md.
///
///     Unattributed  = Measured − Σ components                  (≥ 0)
///     App_i(CPU)    = CPU × w_cpu(i) / Σ w_cpu                 (w = kernel nJ deltas)
///     App_i(GPU)    = GPU × w_gpu(i) / Σ w_gpu
///     App_i(ANE)    = ANE × w_ane(i) / Σ w_ane
///     System row    = non-app components + unclaimed CPU/GPU/ANE + Unattributed
///
/// The kernel's per-app counters are a *model* of energy (CLPC for the CPU,
/// the GPU driver's billing for the GPU). They decide each app's share. The
/// SoC's measured component energy decides the watts.
public enum EnergySplitter {
    public struct Input: Sendable {
        public var endUptimeNS: UInt64
        public var endDate: Date
        public var durationSeconds: Double
        public var onExternalPower: Bool
        public var measuredJoules: Double?
        public var measuredSource: TotalSource?
        public var components: [ComponentEnergy]
        public var apps: [AppUsage]
        public var system: SystemSnapshot
        /// Splits whose app weights are real kernel energy (nJ), not time.
        /// For these, a missing component is rebuilt from the weights, marked
        /// as an estimate, rather than dropped.
        public var energyWeightedSplits: Set<AppSplit>

        public init(endUptimeNS: UInt64, endDate: Date, durationSeconds: Double, onExternalPower: Bool,
                    measuredJoules: Double?, measuredSource: TotalSource?, components: [ComponentEnergy],
                    apps: [AppUsage], system: SystemSnapshot = SystemSnapshot(),
                    energyWeightedSplits: Set<AppSplit> = [.cpu, .gpu, .ane]) {
            self.endUptimeNS = endUptimeNS
            self.endDate = endDate
            self.durationSeconds = durationSeconds
            self.onExternalPower = onExternalPower
            self.measuredJoules = measuredJoules
            self.measuredSource = measuredSource
            self.components = components
            self.apps = apps
            self.system = system
            self.energyWeightedSplits = energyWeightedSplits
        }
    }

    public static func attribute(_ input: Input) -> IntervalReport {
        // One entry per component; a source may report a component twice.
        var merged: [ComponentID: ComponentEnergy] = [:]
        for component in input.components where component.joules.isFinite && component.joules >= 0 {
            if var existing = merged[component.id] {
                existing.joules += component.joules
                existing.provenance = max(existing.provenance, component.provenance)
                merged[component.id] = existing
            } else {
                merged[component.id] = component
            }
        }

        var apps = input.apps.map { AppEnergy(identity: $0.identity, usage: $0.usage, coalitionIDs: $0.coalitionIDs.sorted()) }
        var unclaimed = 0.0

        for split in [AppSplit.cpu, .gpu, .ane] {
            let weights = input.apps.map { Double($0.usage.value(for: split)) }
            let totalWeight = weights.reduce(0, +)
            let componentID = ComponentID.forSplit(split)
            var componentJoules = merged.values.filter { $0.id.appSplit == split }.reduce(0) { $0 + $1.joules }

            if merged[componentID] == nil, componentJoules == 0, totalWeight > 0, input.energyWeightedSplits.contains(split) {
                // No hardware counter for this component: the kernel's own
                // energy model is the next best figure.
                componentJoules = totalWeight * 1e-9
                merged[componentID] = ComponentEnergy(id: componentID, joules: componentJoules, provenance: .estimated)
            }
            guard componentJoules > 0 else { continue }
            guard totalWeight > 0 else {
                unclaimed += componentJoules
                continue
            }
            for i in apps.indices where weights[i] > 0 {
                let share = componentJoules * weights[i] / totalWeight
                switch split {
                case .cpu: apps[i].cpuJoules = share
                case .gpu: apps[i].gpuJoules = share
                case .ane: apps[i].aneJoules = share
                case .none: break
                }
            }
        }

        for i in apps.indices {
            apps[i].processes = processShares(for: input.apps[i], cpuJoules: apps[i].cpuJoules)
        }
        apps.removeAll { $0.joules <= 0 }
        apps.sort { $0.joules == $1.joules ? $0.identity.key < $1.identity.key : $0.joules > $1.joules }

        let components = merged.values.sorted { $0.id < $1.id }
        let componentTotal = components.reduce(0) { $0 + $1.joules }
        var unattributed: Double?
        var overshoot = 0.0
        if let measured = input.measuredJoules, measured.isFinite, measured >= 0 {
            let remainder = measured - componentTotal
            unattributed = max(0, remainder)
            overshoot = max(0, -remainder)
        }

        return IntervalReport(
            endUptimeNS: input.endUptimeNS, endDate: input.endDate, durationSeconds: input.durationSeconds,
            onExternalPower: input.onExternalPower, measuredJoules: input.measuredJoules,
            measuredSource: input.measuredSource, components: components, apps: apps,
            unclaimedJoules: unclaimed, unattributedJoules: unattributed, overshootJoules: overshoot,
            system: input.system
        )
    }

    /// The app's CPU energy, split by its processes' own counters. Whatever
    /// the readable processes don't account for (other users' processes,
    /// helpers that exited) goes to one "Other or exited processes" row, so the
    /// rows always add up to the app.
    static func processShares(for app: AppUsage, cpuJoules: Double) -> [ProcessShare] {
        guard cpuJoules > 0, !app.processes.isEmpty || app.unreadableProcessCount > 0 else { return [] }
        let readable = app.processes.reduce(0.0) { $0 + Double($1.cpuEnergyNJ) }
        let whole = max(Double(app.usage.cpuEnergyNJ), readable)
        guard whole > 0 else { return [] }
        var shares = app.processes
            .filter { $0.cpuEnergyNJ > 0 }
            .map { ProcessShare(name: $0.name, pid: $0.pid, cpuJoules: cpuJoules * Double($0.cpuEnergyNJ) / whole) }
        let rest = cpuJoules * (whole - readable) / whole
        if rest > cpuJoules * 0.001 {
            shares.append(ProcessShare(name: ProcessShare.otherProcessesName, pid: nil, cpuJoules: rest))
        }
        return shares.sorted { $0.cpuJoules > $1.cpuJoules }
    }
}

extension ComponentID {
    static func forSplit(_ split: AppSplit) -> ComponentID {
        switch split {
        case .cpu: .cpu
        case .gpu: .gpu
        case .ane: .ane
        case .none: .otherSoC
        }
    }
}
