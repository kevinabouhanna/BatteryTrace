import BatteryTraceCore
import Foundation
import IOKit

/// GPU time per process, from the GPU driver's user clients in the IORegistry.
///
/// Every Metal connection is a child of the `IOAccelerator` service, naming
/// its creator (`IOUserClientCreator = "pid 690, WindowServer"`) and keeping
/// `AppUsage[].accumulatedGPUTime` in nanoseconds. Needs no privileges.
///
/// Only the fallback for macOS 14, whose coalitions carry no GPU energy: the
/// walk costs about 0.7 ms with 40 clients, and time is a worse weight than
/// energy, since a GPU at low clocks uses less energy per millisecond.
public final class GPUClientReader: DataSource {
    public let sourceName = "GPU clients"
    public private(set) var isAvailable = false
    public private(set) var diagnostics: [String] = []

    private let accelerator: io_registry_entry_t

    public init() {
        accelerator = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
        isAvailable = accelerator != 0
        diagnostics.append(isAvailable ? "IOAccelerator found" : "no IOAccelerator")
    }

    deinit {
        if accelerator != 0 { IOObjectRelease(accelerator) }
    }

    /// Cumulative GPU nanoseconds per PID, summed over its connections.
    public func read(into totals: inout [Int32: UInt64]) {
        totals.removeAll(keepingCapacity: true)
        guard isAvailable else { return }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let client = IOIteratorNext(iterator), client != 0 {
            defer { IOObjectRelease(client) }
            guard let usage = IORegistryEntryCreateCFProperty(client, "AppUsage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [NSDictionary],
                  !usage.isEmpty,
                  let creator = IORegistryEntryCreateCFProperty(client, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
                  let pid = Self.pid(fromCreator: creator)
            else { continue }
            let nanoseconds = usage.reduce(UInt64(0)) { $0 &+ ((($1["accumulatedGPUTime"]) as? NSNumber)?.uint64Value ?? 0) }
            totals[pid, default: 0] &+= nanoseconds
        }
    }

    /// "pid 690, WindowServer" → 690
    static func pid(fromCreator creator: String) -> Int32? {
        guard creator.hasPrefix("pid ") else { return nil }
        return Int32(creator.dropFirst(4).prefix { $0.isNumber })
    }
}
