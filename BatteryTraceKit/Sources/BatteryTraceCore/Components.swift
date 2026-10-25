/// A consumer of power that is not an app: the CPU, the GPU, the display.
///
/// Open-ended on purpose. A new source can report a component nobody listed
/// here (say `ComponentID("wifi")`) and attribution, storage and the System
/// section handle it without changes: it is subtracted from Unattributed and
/// listed under its raw name.
public struct ComponentID: RawRepresentable, Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public static let cpu = ComponentID("cpu")
    public static let gpu = ComponentID("gpu")
    public static let ane = ComponentID("ane")
    /// DRAM plus its controller (Apple's "DCS").
    public static let memory = ComponentID("memory")
    /// Our model of the built-in panel's backlight. Always an estimate.
    public static let displayBacklight = ComponentID("display.backlight")
    /// The SoC's display pipes (DCP), internal and external. Measured.
    public static let displayController = ComponentID("display.controller")
    /// Image signal processor, video encoder, always-on and fabric blocks.
    public static let otherSoC = ComponentID("soc.other")
    /// PCIe and Thunderbolt links.
    public static let pcie = ComponentID("pcie")

    public var description: String { rawValue }
    public static func < (a: ComponentID, b: ComponentID) -> Bool { a.sortIndex == b.sortIndex ? a.rawValue < b.rawValue : a.sortIndex < b.sortIndex }

    public var displayName: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .ane: "Neural Engine"
        case .memory: "Memory"
        case .displayBacklight: "Display backlight"
        case .displayController: "Display controller"
        case .otherSoC: "Other chip blocks"
        case .pcie: "PCIe / Thunderbolt"
        default: rawValue
        }
    }

    /// The per-app counter that splits this component's energy across apps.
    /// Components without one stay in the System row.
    public var appSplit: AppSplit {
        switch self {
        case .cpu: .cpu
        case .gpu: .gpu
        case .ane: .ane
        default: .none
        }
    }

    private var sortIndex: Int {
        switch self {
        case .cpu: 0
        case .gpu: 1
        case .ane: 2
        case .memory: 3
        case .displayBacklight: 4
        case .displayController: 5
        case .otherSoC: 6
        case .pcie: 7
        default: 8
        }
    }
}

/// How much to trust a number. The UI labels every `.estimated` value as such.
public enum Provenance: UInt8, Sendable, Codable, Comparable {
    /// Read from a hardware or firmware energy counter.
    case measured = 0
    /// Computed by a model of ours from indirect signals.
    case estimated = 1

    public static func < (a: Provenance, b: Provenance) -> Bool { a.rawValue < b.rawValue }
}

public enum AppSplit: UInt8, Sendable, Codable, CaseIterable {
    case cpu, gpu, ane, none
}

/// Energy one component used over one interval.
public struct ComponentEnergy: Sendable, Hashable, Codable {
    public var id: ComponentID
    public var joules: Double
    public var provenance: Provenance

    public init(id: ComponentID, joules: Double, provenance: Provenance) {
        self.id = id
        self.joules = joules
        self.provenance = provenance
    }
}

/// Where a measured total came from, most trustworthy first.
public enum TotalSource: UInt8, Sendable, Codable {
    /// The battery gauge's own running average of system load (60 s windows).
    case batteryTelemetry = 0
    /// Battery voltage × current while discharging.
    case batteryDischarge = 1
    /// The SMC's live system power rail.
    case smc = 2

    public var label: String {
        switch self {
        case .batteryTelemetry: "battery gauge"
        case .batteryDischarge: "battery voltage × current"
        case .smc: "system power sensor"
        }
    }
}
