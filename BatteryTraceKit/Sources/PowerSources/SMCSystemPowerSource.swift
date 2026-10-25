import BatteryTraceCore
import IOKit

/// Live whole-system power from the SMC's `PSTR` key ("system total rail").
///
/// The `AppleSMC` user client is undocumented but needs no privileges.
/// About 0.1 ms per read. On Macs without the key (most Intel models), the
/// source is unavailable and totals come from the battery gauge alone.
public final class SMCSystemPowerSource: LiveSystemPowerSource {
    public let sourceName = "SMC"
    public private(set) var isAvailable = false
    public private(set) var diagnostics: [String] = []

    let connection: SMCConnection?
    private let systemPowerKey = SMCConnection.fourCC("PSTR")

    public init() {
        connection = SMCConnection()
        guard let connection else {
            diagnostics.append("AppleSMC unavailable")
            return
        }
        if let watts = connection.readFloat(systemPowerKey), watts.isFinite {
            isAvailable = true
            diagnostics.append("PSTR reads \(String(format: "%.2f", watts)) W")
        } else {
            diagnostics.append("PSTR key missing or not a float")
        }
    }

    public func readSystemWatts() -> Double? {
        guard isAvailable, let watts = connection?.readFloat(systemPowerKey) else { return nil }
        // A Mac laptop draws under 200 W; anything outside is a bad read.
        return watts.isFinite && watts >= 0 && watts < 500 ? Double(watts) : nil
    }
}

/// A connection to the `AppleSMC` user client, reading `flt ` keys.
final class SMCConnection {
    private var connection: io_connect_t = 0
    private var keyInfoCache: [UInt32: SMCKeyInfo] = [:]

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    // MARK: - SMC protocol

    /// Mirrors the kernel's `SMCKeyData_t` (80 bytes). The explicit padding in
    /// `SMCKeyInfo` matters: without it Swift packs `result` into the struct's
    /// tail padding, where C does not, and every read fails.
    private struct SMCKeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
        var padding: (UInt8, UInt8, UInt8) = (0, 0, 0)
    }

    private struct SMCParam {
        var key: UInt32 = 0
        var version: (UInt8, UInt8, UInt8, UInt8, UInt16) = (0, 0, 0, 0, 0)
        var powerLimit: (UInt16, UInt16, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0)
        var keyInfo = SMCKeyInfo()
        var result: UInt8 = 0
        var status: UInt8 = 0
        var command: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
    }

    private static let readKeyInfoCommand: UInt8 = 9
    private static let readBytesCommand: UInt8 = 5
    private static let floatType = fourCC("flt ")

    private func call(_ input: inout SMCParam) -> Bool {
        var output = SMCParam()
        var outputSize = MemoryLayout<SMCParam>.stride
        let result = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<SMCParam>.stride, &output, &outputSize)
        input = output
        return result == KERN_SUCCESS && output.result == 0
    }

    func readFloat(_ key: UInt32) -> Float? {
        guard connection != 0, MemoryLayout<SMCParam>.stride == 80 else { return nil }
        let info: SMCKeyInfo
        if let cached = keyInfoCache[key] {
            info = cached
        } else {
            var request = SMCParam()
            request.key = key
            request.command = Self.readKeyInfoCommand
            guard call(&request) else { return nil }
            info = request.keyInfo
            keyInfoCache[key] = info
        }
        guard info.dataType == Self.floatType, info.dataSize == 4 else { return nil }
        var request = SMCParam()
        request.key = key
        request.keyInfo.dataSize = info.dataSize
        request.command = Self.readBytesCommand
        guard call(&request) else { return nil }
        return withUnsafeBytes(of: request.bytes) { $0.load(as: Float.self) }
    }

    static func fourCC(_ code: StaticString) -> UInt32 {
        code.withUTF8Buffer { $0.reduce(0) { $0 << 8 | UInt32($1) } }
    }
}
