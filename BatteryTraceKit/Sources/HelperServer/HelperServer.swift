import Darwin
import Foundation
import HelperProtocol

// Battery Trace's optional privileged helper.
//
// The only part of Battery Trace that runs as root, and kept small. It exists
// for two readings the kernel keeps from an ordinary user:
//
// - Apple's own CPU energy figure, which `powermetrics` reports and which
//   only root can get fresh. Without it, Battery Trace reads PMP's cluster
//   counters, about 0.3 W lower (docs/VALIDATION.md §3).
// - `proc_pid_rusage` for other users' processes (WindowServer, root daemons).
//
// # Why a sudoers rule rather than an XPC daemon
//
// The textbook route is `SMAppService.daemon` with XPC, validating callers by
// team identifier. An ad-hoc-signed app has no team identifier, so that
// validation can't be done, and the daemon would be a Mach service any local
// process could talk to. NetworkMonitor faced the same choice and made the
// same one: a file in /etc/sudoers.d naming this binary and its two verbs, no
// other arguments, checked with `visudo -c` before it is installed.
//
// `serve` then talks only over its own stdin and stdout, so a running helper
// answers only the process that started it, and exits when that process
// closes stdin, by quitting or crashing.
//
// # What it will do
//
// Two requests, both read-only: a `powermetrics` sample with fixed samplers,
// and rusage for numeric PIDs. It runs no command a caller names and writes
// nothing to disk.
//
// Verbs: status | serve

/// Where the energy figures come from: `powermetrics`, or a fake in tests.
public protocol PowerSampler: AnyObject {
    /// Energy since the previous sample, or since the sampler started.
    func sample() -> PowerReading?
    /// Stops anything the sampler started. It may start again on the next
    /// `sample()`.
    func stop()
}

/// Answers one request at a time. Separate from the I/O so it can be tested.
public final class HelperServer {
    private let sampler: PowerSampler
    private let rusage: (Int32) -> RootRusage?

    public init(sampler: PowerSampler, rusage: @escaping (Int32) -> RootRusage? = RootRusageReader.read) {
        self.sampler = sampler
        self.rusage = rusage
    }

    public func reply(to line: Substring) -> HelperReply {
        guard let request = HelperRequest.parse(line) else { return .error("unknown request") }
        switch request {
        case .power(let seq):
            return .power(seq: seq, sampler.sample())
        case .rusage(let seq, let pids):
            return .rusage(seq: seq, pids.compactMap(rusage))
        }
    }

    /// Reads requests from `input` until it closes, writing one reply line
    /// for each to `output`. Stops the sampler on the way out.
    public func serve(input: Int32, output: Int32) {
        var reader = LineReader(fd: input)
        while let line = reader.next() {
            if line.isEmpty { continue }
            let reply = reply(to: line[...]).line + "\n"
            guard writeAll(output, reply) else { break }
        }
        sampler.stop()
    }

    private func writeAll(_ fd: Int32, _ text: String) -> Bool {
        var bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeMutableBytes { raw in
                write(fd, raw.baseAddress! + offset, raw.count - offset)
            }
            if written < 0 {
                if errno == EINTR { continue }
                return false
            }
            offset += written
        }
        bytes.removeAll()
        return true
    }
}

/// Splits a file descriptor's bytes into lines. Lines longer than the limit
/// are dropped whole, so a misbehaving peer can't grow the buffer forever.
struct LineReader {
    let fd: Int32
    var buffer: [UInt8] = []
    var discarding = false
    static let maxLine = 1 << 20

    init(fd: Int32) { self.fd = fd }

    /// The next line without its terminator, or nil at end of input.
    mutating func next() -> String? {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                if discarding { discarding = false; continue }
                return String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespaces.union(.init(charactersIn: "\r")))
            }
            if buffer.count > Self.maxLine {
                buffer.removeAll()
                discarding = true
            }
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk[..<count])
        }
    }
}

/// `proc_pid_rusage`, which as root works for every process.
public enum RootRusageReader {
    nonisolated(unsafe) private static var useV6 = true

    public static func read(_ pid: Int32) -> RootRusage? {
        var info = rusage_info_v6()
        let ok = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { pointer in
                if useV6, proc_pid_rusage(pid, RUSAGE_INFO_V6, pointer) == 0 { return true }
                if useV6, errno == EINVAL { useV6 = false }
                return proc_pid_rusage(pid, RUSAGE_INFO_V4, pointer) == 0
            }
        }
        guard ok else { return nil }
        return RootRusage(
            pid: pid, startAbstime: info.ri_proc_start_abstime,
            energyNJ: useV6 ? info.ri_energy_nj : info.ri_billed_energy,
            userTime: info.ri_user_time, systemTime: info.ri_system_time,
            interruptWakeups: info.ri_interrupt_wkups, idleWakeups: info.ri_pkg_idle_wkups,
            diskReadBytes: info.ri_diskio_bytesread, diskWriteBytes: info.ri_diskio_byteswritten,
            footprintBytes: info.ri_phys_footprint
        )
    }
}

/// The helper's entry point, called from its `main.swift`.
public enum HelperMain {
    public static func run(_ arguments: [String]) -> Int32 {
        switch arguments.dropFirst().first {
        case "status":
            print(HelperStatus(version: HelperProtocol.version, root: geteuid() == 0).line)
            return 0
        case "serve":
            guard geteuid() == 0 else {
                FileHandle.standardError.write(Data("battery trace helper: serve must run as root\n".utf8))
                return 1
            }
            signal(SIGPIPE, SIG_IGN)
            PowermetricsProcess.installTerminationHandlers()
            let sampler = PowermetricsProcess()
            sampler.prepare()
            HelperServer(sampler: sampler).serve(input: STDIN_FILENO, output: STDOUT_FILENO)
            return 0
        default:
            FileHandle.standardError.write(Data("usage: \(HelperProtocol.helperName) status | serve\n".utf8))
            return 2
        }
    }
}
