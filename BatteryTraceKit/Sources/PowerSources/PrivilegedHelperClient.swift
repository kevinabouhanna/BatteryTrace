import BatteryTraceCore
import Darwin
import Foundation
import HelperProtocol

/// Battery Trace's side of the optional root helper: finds it, starts it with
/// `sudo -n` and asks it for readings over its stdin and stdout.
///
/// `sudo -n` never prompts. Without the helper's sudoers rule it fails at
/// once, and Battery Trace carries on without the helper.
///
/// Not thread-safe: the sampling queue owns it.
public final class PrivilegedHelperClient: DataSource {
    public let sourceName = "Privileged helper"
    public var isAvailable: Bool { pid > 0 }
    public private(set) var diagnostics: [String] = []

    public enum Installation: Equatable, Sendable {
        case missing
        /// Installed, and the version this app speaks.
        case current
        /// Installed by another version of Battery Trace.
        case outdated
        /// The files are there, but `sudo -n` couldn't run it: a rule for
        /// another user, or a half-removed install. Reinstalling fixes both.
        case notAnswering
    }

    /// Whether the helper's files are in place: root-owned, not writable by
    /// anyone else, with its sudoers rule. Starts no process.
    public static var isInstalled: Bool {
        var info = stat()
        guard stat(HelperProtocol.helperPath, &info) == 0, info.st_uid == 0,
              info.st_mode & (S_IWGRP | S_IWOTH) == 0, info.st_mode & S_IXUSR != 0
        else { return false }
        return FileManager.default.fileExists(atPath: HelperProtocol.sudoersPath)
    }

    /// Asks the installed helper which version it is, through `sudo -n`. One
    /// short process: call it when something is about to be decided, not
    /// from a view's body.
    public static func installation() -> Installation {
        guard isInstalled else { return .missing }
        guard let child = Child.spawn(["/usr/bin/sudo", "-n", HelperProtocol.helperPath, "status"], input: false) else {
            return .notAnswering
        }
        var lines = LineBuffer()
        let line = lines.next(from: child.output, timeout: 5)
        child.finish()
        guard let line, let status = HelperStatus.parse(line), status.root else { return .notAnswering }
        return status.version == HelperProtocol.version ? .current : .outdated
    }

    private var child: Child?
    private var pid: pid_t { child?.pid ?? 0 }
    private var lines = LineBuffer()
    private var seq: UInt32 = 0

    public init() {}

    deinit { stop() }

    /// Starts `sudo -n <helper> serve`. Returns whether it is running.
    @discardableResult
    public func start() -> Bool {
        if child != nil { return true }
        guard Self.isInstalled else {
            diagnostics = ["not installed"]
            return false
        }
        guard let started = Child.spawn(["/usr/bin/sudo", "-n", HelperProtocol.helperPath, "serve"], input: true) else {
            diagnostics = ["couldn't start sudo"]
            return false
        }
        child = started
        lines = LineBuffer()
        diagnostics = ["running as pid \(started.pid) (sudo)"]
        return true
    }

    /// Closes the helper's stdin, which ends it.
    public func stop() {
        child?.finish()
        child = nil
    }

    /// Sends a request. Returns its sequence number, or nil if the helper
    /// isn't running or has gone away.
    public func send(_ make: (UInt32) -> HelperRequest) -> UInt32? {
        guard let child, child.input >= 0 else { return nil }
        seq &+= 1
        let request = make(seq)
        guard child.write(request.line + "\n") else {
            fail("the helper stopped reading")
            return nil
        }
        return request.seq
    }

    /// Waits for the reply to `seq`, dropping replies to older requests that
    /// arrived late. Nil on timeout or if the helper ended; either way the
    /// helper is stopped, so a late reply can't be taken for a later request.
    public func receive(_ seq: UInt32, timeout: Double) -> HelperReply? {
        guard let child else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let left = deadline.timeIntervalSinceNow
            guard left > 0, let line = lines.next(from: child.output, timeout: left) else {
                fail(deadline.timeIntervalSinceNow > 0 ? "the helper ended" : "no reply within \(String(format: "%.1f", timeout)) s")
                return nil
            }
            guard let reply = HelperReply.parse(line) else { continue }
            if case .error(let reason) = reply {
                fail("helper: \(reason)")
                return nil
            }
            if reply.seq == seq { return reply }
        }
    }

    private func fail(_ reason: String) {
        diagnostics = [reason]
        stop()
    }
}

/// A child process with pipes, in its own session so `sudo` never finds a
/// terminal to attach a pseudo-terminal to, even when `bttrace` runs from one.
private struct Child {
    let pid: pid_t
    /// Our end of its stdin, or -1.
    let input: Int32
    /// Our end of its stdout.
    let output: Int32

    static func spawn(_ arguments: [String], input wantsInput: Bool) -> Child? {
        var stdinPipe: [Int32] = [-1, -1]
        var stdoutPipe: [Int32] = [-1, -1]
        guard pipe(&stdoutPipe) == 0 else { return nil }
        if wantsInput, pipe(&stdinPipe) != 0 {
            close(stdoutPipe[0]); close(stdoutPipe[1])
            return nil
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if wantsInput {
            posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], STDIN_FILENO)
        } else {
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSID))

        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let environment: [UnsafeMutablePointer<CChar>?] = [strdup("PATH=/usr/bin:/bin:/usr/sbin:/sbin"), nil]
        defer { environment.forEach { free($0) } }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, arguments[0], &actions, &attributes, argv, environment)
        close(stdoutPipe[1])
        if wantsInput { close(stdinPipe[0]) }
        guard result == 0 else {
            close(stdoutPipe[0])
            if wantsInput { close(stdinPipe[1]) }
            return nil
        }
        // Our ends stay out of any other child this process starts: one that
        // inherited the stdin pipe would keep the helper from ever seeing it close.
        _ = fcntl(stdoutPipe[0], F_SETFD, FD_CLOEXEC)
        if wantsInput {
            _ = fcntl(stdinPipe[1], F_SETFD, FD_CLOEXEC)
            _ = fcntl(stdinPipe[1], F_SETNOSIGPIPE, 1)
        }
        return Child(pid: pid, input: wantsInput ? stdinPipe[1] : -1, output: stdoutPipe[0])
    }

    func write(_ text: String) -> Bool {
        var bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeMutableBytes { Darwin.write(input, $0.baseAddress! + offset, $0.count - offset) }
            if written < 0 {
                if errno == EINTR { continue }
                return false
            }
            offset += written
        }
        bytes.removeAll()
        return true
    }

    /// Closes our ends and reaps the child, waiting up to a second for it to
    /// exit. A helper that outlives that sees its stdin closed and exits on
    /// its own; it is reaped by the next `finish` or with the app.
    func finish() {
        if input >= 0 { close(input) }
        close(output)
        var status: Int32 = 0
        for _ in 0..<20 {
            if waitpid(pid, &status, WNOHANG) != 0 { return }
            usleep(50_000)
        }
    }
}

/// Lines from a pipe, read with a timeout.
private struct LineBuffer {
    private var buffer: [UInt8] = []

    mutating func next(from fd: Int32, timeout: Double) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: buffer[..<newline], as: UTF8.self)
                buffer.removeSubrange(...newline)
                return line
            }
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return nil }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(left * 1000) + 1)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { return nil }
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk[..<count])
            if buffer.count > 8 << 20 { return nil }
        }
    }
}
