import Darwin
import Foundation
import HelperProtocol

/// One `powermetrics` kept running with periodic sampling off (`-i 0`), and
/// asked for a sample with SIGINFO whenever Battery Trace attributes. Each
/// sample covers exactly the time since the previous one, so the samples line
/// up with Battery Trace's own intervals, and between requests `powermetrics`
/// does nothing.
///
/// Measured on an M1 (macOS 27): starting takes about 0.7 s of CPU, which is
/// why it is kept running; a sample takes 10–20 ms to arrive and about 10 ms
/// of CPU. Only the CPU sampler runs: Battery Trace's own GPU and ANE readings
/// already agree with `powermetrics` to within 3%.
///
/// The samplers and flags are fixed here. Nothing a caller sends reaches the
/// command line.
public final class PowermetricsProcess: PowerSampler {
    static let path = "/usr/bin/powermetrics"
    static let arguments = ["-i", "0", "-b", "0", "-f", "plist", "--samplers", "cpu_power"]
    /// How long a new process needs before it answers SIGINFO. Until then
    /// SIGINFO does what it does by default: nothing.
    static let warmUp: TimeInterval = 1.5

    /// The running child, for the termination handlers.
    nonisolated(unsafe) static var runningPID: pid_t = 0

    private var pid: pid_t = 0
    private var output: Int32 = -1
    private var buffer: [UInt8] = []
    /// When it last had to be started, to back off if it keeps failing.
    private var lastStart: Date?
    /// Set until the first sample after a start.
    private var startedAt: Date?

    public init() {}

    deinit { stop() }

    /// Starts `powermetrics` now rather than on the first request, so it is
    /// warm by the time one comes.
    public func prepare() {
        if pid == 0 { _ = start() }
    }

    /// Takes a sample. On failure the process is stopped, so a late sample
    /// can't be taken for the next one, and started again on a later request
    /// (at most once a minute).
    public func sample() -> PowerReading? {
        if pid == 0 {
            if let lastStart, Date().timeIntervalSince(lastStart) < 60 { return nil }
            guard start() else { return nil }
        }
        discardStale()
        var attempts = 1
        if let startedAt {
            let wait = Self.warmUp - Date().timeIntervalSince(startedAt)
            if wait > 0 { usleep(UInt32(wait * 1_000_000)) }
            attempts = 2 // in case the first signal still came too early
            self.startedAt = nil
        }
        for _ in 0..<attempts {
            guard kill(pid, SIGINFO) == 0 else { break }
            if let data = readSample(timeout: 2) { return PowermetricsPlist.reading(from: data) }
        }
        stop()
        return nil
    }

    public func stop() {
        guard pid > 0 else { return }
        kill(pid, SIGTERM)
        var status: Int32 = 0
        for _ in 0..<20 {
            if waitpid(pid, &status, WNOHANG) != 0 { break }
            usleep(50_000)
        }
        if waitpid(pid, &status, WNOHANG) == 0 {
            kill(pid, SIGKILL)
            waitpid(pid, &status, 0)
        }
        close(output)
        pid = 0
        output = -1
        buffer.removeAll()
        Self.runningPID = 0
    }

    /// SIGTERM, SIGHUP and SIGINT stop `powermetrics` too, so the helper never
    /// leaves one running behind it.
    public static func installTerminationHandlers() {
        for signalNumber in [SIGTERM, SIGHUP, SIGINT] {
            signal(signalNumber) { _ in
                if PowermetricsProcess.runningPID > 0 { kill(PowermetricsProcess.runningPID, SIGTERM) }
                _exit(0)
            }
        }
    }

    private func start() -> Bool {
        lastStart = Date()
        var pipeFDs: [Int32] = [-1, -1]
        guard pipe(&pipeFDs) == 0 else { return false }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, pipeFDs[1], STDOUT_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only the three descriptors above reach the child.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv: [UnsafeMutablePointer<CChar>?] = ([Self.path] + Self.arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let environment: [UnsafeMutablePointer<CChar>?] = [strdup("PATH=/usr/bin:/bin:/usr/sbin:/sbin"), nil]
        defer { environment.forEach { free($0) } }

        var child: pid_t = 0
        let result = posix_spawn(&child, Self.path, &actions, &attributes, argv, environment)
        close(pipeFDs[1])
        guard result == 0 else {
            close(pipeFDs[0])
            return false
        }
        pid = child
        output = pipeFDs[0]
        Self.runningPID = child
        startedAt = Date()
        return true
    }

    private static let sampleEnd = Array("</plist>".utf8)

    /// Reads until the end of one plist sample. `powermetrics` writes its NUL
    /// separator before each sample after the first, not after it, so a
    /// sample is complete at its closing tag.
    private func readSample(timeout: Double) -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let sample = takeSample() { return sample }
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return nil }
            var descriptor = pollfd(fd: output, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(left * 1000) + 1)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0, readAvailable() else { return nil }
        }
    }

    /// Drops samples nobody asked for: a reply to a signal that came late.
    private func discardStale() {
        var descriptor = pollfd(fd: output, events: Int16(POLLIN), revents: 0)
        while poll(&descriptor, 1, 0) > 0, readAvailable() {}
        while takeSample() != nil {}
    }

    /// Appends what the pipe has. False at end of file or on error.
    private func readAvailable() -> Bool {
        var chunk = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(output, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return false }
            buffer.append(contentsOf: chunk[..<count])
            if buffer.count > 4 << 20 { buffer.removeAll() }
            return true
        }
    }

    /// Removes and returns the first complete sample in the buffer, without
    /// its separators.
    private func takeSample() -> Data? {
        let tag = Self.sampleEnd
        guard buffer.count >= tag.count else { return nil }
        var index = 0
        while index + tag.count <= buffer.count {
            if buffer[index] == tag[0], buffer[index..<(index + tag.count)].elementsEqual(tag) {
                let end = index + tag.count
                let sample = Data(buffer[..<end].drop { $0 == 0 || $0 == 0x0A || $0 == 0x20 })
                buffer.removeSubrange(..<end)
                return sample
            }
            index += 1
        }
        return nil
    }
}
