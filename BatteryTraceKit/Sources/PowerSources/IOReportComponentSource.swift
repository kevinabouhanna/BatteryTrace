import BatteryTraceCore
import CoreFoundation
import Foundation

/// SoC energy per component, from the private IOReport library.
///
/// Apple moves these counters around between chips and OS versions. On an M1
/// under macOS 27 the "Energy Model" CPU channels never advance, while group
/// "PMP", subgroup "Energy Counters" has live CPU, GPU, DRAM, ANE and media
/// counters. So each component has an ordered list of candidate channel sets,
/// and the first one seen moving is used from then on.
///
/// Cost is per driver asked, about 0.65 ms of CPU each, whatever the number
/// of channels. So after a short warm-up the subscription is rebuilt with
/// only the drivers whose channels were chosen, usually just PMP.
public final class IOReportComponentSource: ComponentSource {
    public let sourceName = "IOReport"
    public private(set) var isAvailable = false
    public var diagnostics: [String] {
        var lines = notes
        lines.append("\(channels.count) channels subscribed from \(Set(drivers).count) driver(s)\(warmedUp ? "" : ", warming up")")
        for plan in plans {
            let chosen = plan.selected.map { plan.candidates[$0].label } ?? "no channel has moved yet"
            lines.append("\(plan.component.displayName): \(chosen)")
        }
        return lines
    }

    // MARK: - libIOReport, looked up at run time

    private typealias CopyChannelsInGroup = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFDictionary>?
    private typealias CreateSubscription = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> OpaquePointer?
    private typealias CreateSamples = @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias ChannelString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias IntegerValue = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias ChannelFormat = @convention(c) (CFDictionary) -> Int32

    private var createSubscription: CreateSubscription?
    private var createSamples: CreateSamples?
    private var integerValue: IntegerValue?
    private var channelName: ChannelString?
    private var unitLabel: ChannelString?
    private var subscription: OpaquePointer?
    private var subscribedChannels: CFMutableDictionary?
    private var template: NSDictionary?

    // MARK: - Channel plan

    fileprivate struct Channel {
        let name: String
        let group: String
        let joulesPerUnit: Double
        let source: NSDictionary
    }

    fileprivate struct Candidate {
        let label: String
        let indices: [Int]
    }

    fileprivate struct Plan {
        let component: ComponentID
        let candidates: [Candidate]
        var selected: Int?
        var idleReads = 0
        /// Candidates seen moving during warm-up.
        var moved: Set<Int> = []
    }

    private var channels: [Channel] = []
    private var drivers: [Int64] = []
    private var plans: [Plan] = []
    private var previous: [Int64] = []
    private var current: [Int64] = []
    private var hasBaseline = false
    private var notes: [String] = []
    private var reads = 0
    private var warmedUp = false

    /// Reads a channel this many times without movement before trying the
    /// next candidate, if that one has moved.
    private let switchAfterIdleReads = 6
    /// Reads before dropping the drivers no chosen channel needs.
    private let warmupReads = 6

    nonisolated(unsafe) private static let channelsKey = "IOReportChannels" as CFString

    public init() {
        guard let library = PrivateSymbols.open("/usr/lib/libIOReport.dylib") else {
            notes.append("libIOReport.dylib not found")
            return
        }
        guard let copyChannels = PrivateSymbols.function("IOReportCopyChannelsInGroup", in: library, as: CopyChannelsInGroup.self),
              let subscribeFunction = PrivateSymbols.function("IOReportCreateSubscription", in: library, as: CreateSubscription.self),
              let samples = PrivateSymbols.function("IOReportCreateSamples", in: library, as: CreateSamples.self),
              let name = PrivateSymbols.function("IOReportChannelGetChannelName", in: library, as: ChannelString.self),
              let unit = PrivateSymbols.function("IOReportChannelGetUnitLabel", in: library, as: ChannelString.self),
              let format = PrivateSymbols.function("IOReportChannelGetFormat", in: library, as: ChannelFormat.self),
              let value = PrivateSymbols.function("IOReportSimpleGetIntegerValue", in: library, as: IntegerValue.self)
        else {
            notes.append("an IOReport function is missing")
            return
        }
        createSubscription = subscribeFunction
        createSamples = samples
        integerValue = value
        channelName = name
        unitLabel = unit

        // Only the channels some candidate could use.
        func wanted(_ group: String, _ subgroup: String?) -> [NSDictionary] {
            guard let dict = copyChannels(group as CFString, subgroup as CFString?, 0, 0, 0)?.takeRetainedValue() as NSDictionary?,
                  let all = dict["IOReportChannels"] as? [NSDictionary]
            else {
                notes.append("no IOReport group \(group)\(subgroup.map { "/\($0)" } ?? "")")
                return []
            }
            if template == nil { template = dict }
            return all.filter { channel in
                let cf = channel as CFDictionary
                guard format(cf) == 1, // kIOReportFormatSimple
                      let channelName = name(cf)?.takeUnretainedValue() as String?,
                      let unitName = unit(cf)?.takeUnretainedValue() as String?,
                      Self.joulesPerUnit(unitName) != nil
                else { return false }
                return Self.isWanted(name: channelName, group: group)
            }
        }

        let candidates = wanted("PMP", "Energy Counters") + wanted("Energy Model", nil)
        guard !candidates.isEmpty, subscribe(to: candidates) else { return }
        isAvailable = !plans.isEmpty
    }

    /// (Re)subscribes to exactly these channels, keeping each component's
    /// chosen candidate, and takes the first sample as the baseline.
    private func subscribe(to channelDicts: [NSDictionary]) -> Bool {
        guard let createSubscription, let createSamples, let channelName, let unitLabel, let template else { return false }
        let request = NSMutableDictionary(dictionary: template)
        request["IOReportChannels"] = channelDicts
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let sub = createSubscription(nil, request as CFMutableDictionary, &subscribed, 0, nil),
              let subscribedDict = subscribed?.takeRetainedValue()
        else {
            notes.append("IOReportCreateSubscription failed")
            return false
        }
        // The sample's channel order is the subscription's; learn it once.
        guard let sampled = createSamples(sub, subscribedDict, nil)?.takeRetainedValue() as NSDictionary?,
              let list = sampled["IOReportChannels"] as? [NSDictionary]
        else {
            notes.append("IOReportCreateSamples returned nothing")
            return false
        }
        let chosen = Dictionary(plans.compactMap { plan in plan.selected.map { (plan.component, plan.candidates[$0].label) } },
                                uniquingKeysWith: { a, _ in a })
        subscription = sub
        subscribedChannels = subscribedDict
        channels = list.map { channel in
            let cf = channel as CFDictionary
            let unit = unitLabel(cf)?.takeUnretainedValue() as String? ?? ""
            return Channel(name: channelName(cf)?.takeUnretainedValue() as String? ?? "",
                           group: channel["IOReportGroupName"] as? String ?? "",
                           joulesPerUnit: Self.joulesPerUnit(unit) ?? 0, source: channel)
        }
        drivers = channels.map { ($0.source["DriverID"] as? NSNumber)?.int64Value ?? 0 }
        plans = Self.makePlans(names: channels.map(\.name), groups: channels.map(\.group))
        for i in plans.indices {
            if let label = chosen[plans[i].component] { plans[i].selected = plans[i].candidates.firstIndex { $0.label == label } }
        }
        previous = [Int64](repeating: 0, count: channels.count)
        current = previous
        if let array = Self.channelArray(sampled as CFDictionary), CFArrayGetCount(array) == channels.count {
            for i in 0..<channels.count { previous[i] = readValue(array, i) }
            hasBaseline = true
        }
        return true
    }

    public func resetBaseline() { hasBaseline = false }

    public func readComponents(intervalSeconds: Double, into out: inout [ComponentEnergy]) {
        guard isAvailable, let subscription, let subscribedChannels, let createSamples,
              let sample = createSamples(subscription, subscribedChannels, nil)?.takeRetainedValue(),
              let array = Self.channelArray(sample), CFArrayGetCount(array) == channels.count
        else { return }

        for index in 0..<channels.count { current[index] = readValue(array, index) }
        defer { swap(&previous, &current) }
        guard hasBaseline else {
            hasBaseline = true
            return
        }

        for planIndex in plans.indices {
            var deltas: [Double] = []
            deltas.reserveCapacity(plans[planIndex].candidates.count)
            for candidate in plans[planIndex].candidates {
                var joules = 0.0
                for i in candidate.indices {
                    let d = current[i] - previous[i]
                    if d > 0 { joules += Double(d) * channels[i].joulesPerUnit }
                }
                deltas.append(joules)
            }
            plans[planIndex].choose(given: deltas, warmingUp: !warmedUp, switchAfterIdleReads: switchAfterIdleReads)
            if let chosen = plans[planIndex].selected {
                out.append(ComponentEnergy(id: plans[planIndex].component, joules: deltas[chosen], provenance: .measured))
            }
        }

        reads += 1
        if !warmedUp, reads >= warmupReads {
            warmedUp = true
            // Settle on the best candidate that moved at all during warm-up,
            // not merely the first to move: a coarse counter (mJ) can sit
            // still for one short read and still be the better source.
            for i in plans.indices {
                if let best = plans[i].moved.min() { plans[i].selected = best }
            }
            dropUnusedDrivers()
        }
    }

    /// Keeps every channel of each driver that hosts a chosen channel, so a
    /// sibling that hasn't moved yet (the ANE at idle) is still there later.
    private func dropUnusedDrivers() {
        var needed = Set<Int64>()
        for plan in plans {
            guard let selected = plan.selected else { continue }
            for i in plan.candidates[selected].indices { needed.insert(drivers[i]) }
        }
        let keep = channels.indices.filter { needed.contains(drivers[$0]) }
        guard !needed.isEmpty, keep.count < channels.count else { return }
        let dropped = Set(channels.indices).subtracting(keep).map { channels[$0].name }.sorted()
        guard subscribe(to: keep.map { channels[$0].source }) else { return }
        // `readComponents` swaps previous and current when this returns, so
        // both must hold the new subscription's baseline.
        current = previous
        notes.append("after warm-up, dropped channels no chosen driver needs: \(dropped.joined(separator: ", "))")
    }

    private func readValue(_ array: CFArray, _ index: Int) -> Int64 {
        let channel = unsafeBitCast(CFArrayGetValueAtIndex(array, index), to: CFDictionary.self)
        return integerValue?(channel, 0) ?? 0
    }

    private static func channelArray(_ sample: CFDictionary) -> CFArray? {
        guard let raw = CFDictionaryGetValue(sample, Unmanaged.passUnretained(channelsKey).toOpaque()) else { return nil }
        return unsafeBitCast(raw, to: CFArray.self)
    }

    // MARK: - Channel names → components

    static func joulesPerUnit(_ unit: String) -> Double? {
        switch unit.trimmingCharacters(in: .whitespaces) {
        case "mJ": 1e-3
        case "uJ", "µJ": 1e-6
        case "nJ": 1e-9
        default: nil
        }
    }

    /// Per-core, per-state ("DTL") and cluster-manager channels are parts of
    /// their cluster's total. Not subscribing to them keeps each sample small.
    static func isWanted(name: String, group: String) -> Bool {
        if name.contains("DTL") { return false }
        if name.range(of: #"^([EPM]CORE\d+|[EPM]CPM\d*)$"#, options: .regularExpression) != nil { return false }
        if group == "Energy Model", name.range(of: #"^[EPM]CPU\d+$"#, options: .regularExpression) != nil { return false }
        return true
    }

    /// What the plans would be for a given channel list. For tests.
    public static func describePlans(names: [String], groups: [String]) -> [ComponentPlanDescription] {
        makePlans(names: names, groups: groups).map { plan in
            ComponentPlanDescription(component: plan.component, candidateLabels: plan.candidates.map(\.label))
        }
    }

    /// Candidate channel sets per component, best first: PMP's live counters
    /// (one driver for everything), then the Energy Model's totals, then
    /// older chips' names.
    fileprivate static func makePlans(names: [String], groups: [String]) -> [Plan] {
        func indices(group: String, _ match: (String) -> Bool) -> [Int] {
            names.indices.filter { groups[$0] == group && match(names[$0]) }
        }
        func regex(_ pattern: String) -> (String) -> Bool {
            { $0.range(of: pattern, options: .regularExpression) != nil }
        }
        let pmp = "PMP", model = "Energy Model"
        var claimedPMP = Set<Int>()

        func candidate(_ label: String, _ group: String, _ match: @escaping (String) -> Bool) -> Candidate? {
            let found = indices(group: group, match)
            if group == pmp { claimedPMP.formUnion(found) }
            return found.isEmpty ? nil : Candidate(label: "\(label) [\(found.map { names[$0] }.joined(separator: " + "))]", indices: found)
        }

        var plans: [Plan] = []
        func add(_ id: ComponentID, _ candidates: [Candidate?]) {
            let present = candidates.compactMap { $0 }
            if !present.isEmpty { plans.append(Plan(component: id, candidates: present)) }
        }

        // PMP's per-core (ECORE0…, PCORE0…) and cluster-manager (ECPM, PCPM)
        // counters are parts of the cluster totals: ECPU = Σ ECORE + ECPM,
        // to within 0.2% under load on an M1. Claim them in case they were
        // subscribed, so they aren't counted again under "Other chip blocks".
        claimedPMP.formUnion(indices(group: pmp, regex(#"^([EPM]CORE\d+|[EPM]CPM\d*)$"#)))
        add(.cpu, [
            candidate("PMP", pmp, regex(#"^[EPM]CPU\d*$"#)),
            candidate("Energy Model", model) { $0 == "CPU Energy" },
            candidate("Energy Model clusters", model, regex(#"^([EPM]CPU\d*|[EP]ACC\d*_CPU)$"#)),
        ])
        add(.gpu, [
            candidate("PMP", pmp, regex(#"^GPU( SRAM)?\d*$"#)),
            candidate("Energy Model", model) { $0 == "GPU Energy" },
            candidate("Energy Model GPU", model, regex(#"^GPU\d*$"#)),
        ])
        add(.ane, [
            candidate("PMP", pmp, regex(#"^ANE\d*$"#)),
            candidate("Energy Model", model, regex(#"^ANE"#)),
        ])
        add(.memory, [
            candidate("PMP", pmp, regex(#"^(DRAM|DCS)\d*$"#)),
            candidate("Energy Model", model, regex(#"^(DRAM|DCS)"#)),
        ])
        add(.displayController, [
            candidate("PMP", pmp, regex(#"^DISP"#)),
            candidate("Energy Model", model, regex(#"^DISP"#)),
        ])
        add(.pcie, [
            candidate("Energy Model", model, regex(#"(PCIe|apciec)"#)),
        ])
        // Whatever else PMP counts (ISP, video codecs, always-on, fabric).
        let rest = names.indices.filter { groups[$0] == pmp && !claimedPMP.contains($0) }
        if !rest.isEmpty {
            plans.append(Plan(component: .otherSoC, candidates: [Candidate(label: "PMP [\(rest.map { names[$0] }.joined(separator: " + "))]", indices: rest)]))
        }
        return plans
    }
}

/// A component's candidate channel sets, for tests and diagnostics.
public struct ComponentPlanDescription: Sendable, Equatable {
    public let component: ComponentID
    public let candidateLabels: [String]
}

private extension IOReportComponentSource.Plan {
    /// While warming up: report the best candidate that has moved so far.
    /// After: stick with the chosen one, and move on only if it stays still
    /// for a while and a later candidate moves (a counter that froze after an
    /// OS update).
    mutating func choose(given deltas: [Double], warmingUp: Bool, switchAfterIdleReads: Int) {
        if warmingUp {
            for i in deltas.indices where deltas[i] > 0 { moved.insert(i) }
            if let best = moved.min() { selected = best }
            return
        }
        guard let current = selected else {
            selected = deltas.indices.first { deltas[$0] > 0 }
            return
        }
        if deltas[current] > 0 {
            idleReads = 0
        } else {
            idleReads += 1
            if idleReads >= switchAfterIdleReads, let moving = deltas.indices.first(where: { $0 != current && deltas[$0] > 0 }) {
                selected = moving
                idleReads = 0
            }
        }
    }
}
