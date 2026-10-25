import BatteryTraceCore
import Foundation
import HelperProtocol
import PowerSources

/// `bttrace helper`: whether the privileged helper is installed and
/// answering, and what its two requests return.
enum HelperCommand {
    static func run(_ arguments: inout Arguments) {
        let count = arguments.int("--count", default: 3)
        let interval = arguments.double("--interval", default: 2)
        let installation = PrivilegedHelperClient.installation()
        print("Helper: \(installation) (this build speaks version \(HelperProtocol.version))")
        guard installation == .current else {
            print("Install it from Battery Trace's Settings › Accuracy, or with `make install-helper`.")
            return
        }
        let client = PrivilegedHelperClient()
        guard client.start() else {
            print("Couldn't start it: \(client.diagnostics.joined(separator: "; "))")
            return
        }
        defer { client.stop() }
        // The first sample covers powermetrics' start-up, not an interval.
        for index in 0...count {
            if index > 0 { Thread.sleep(forTimeInterval: interval) }
            let start = Date()
            guard let seq = client.send({ .power(seq: $0) }),
                  case .power(_, let reading)? = client.receive(seq, timeout: 5) else {
                print("power: no reply (\(client.diagnostics.joined(separator: "; ")))")
                return
            }
            let latency = Date().timeIntervalSince(start) * 1000
            if let reading {
                print(String(format: "power %d: %.3f s, CPU %.0f mW, reply in %.0f ms%@", index, reading.elapsedSeconds,
                             reading.cpuMillijoules / reading.elapsedSeconds, latency, index == 0 ? " (start-up, not used)" : ""))
            } else {
                print("power \(index): no sample")
            }
        }
        // launchd and WindowServer belong to other users: proc_pid_rusage
        // refuses them without root.
        let pids: [Int32] = [1] + (windowServerPID().map { [$0] } ?? [])
        if let seq = client.send({ .rusage(seq: $0, pids: pids) }), case .rusage(_, let records)? = client.receive(seq, timeout: 5) {
            for record in records {
                print("rusage pid \(record.pid): \(record.energyNJ / 1_000_000) mJ since it started, \(record.footprintBytes >> 20) MB")
            }
        } else {
            print("rusage: no reply")
        }
    }

    private static func windowServerPID() -> Int32? {
        var records: [ProcessRecord] = []
        ProcessTableReader(coalitions: nil).list(into: &records)
        return records.first { $0.name == "WindowServer" }?.pid
    }
}
