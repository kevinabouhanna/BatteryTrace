import Darwin
import Foundation
import HelperProtocol
@testable import HelperServer
import Testing

@Suite struct HelperProtocolTests {
    @Test func requestsRoundTrip() {
        for request in [HelperRequest.power(seq: 7), .rusage(seq: 8, pids: [0, 1, 4242]), .rusage(seq: 9, pids: [])] {
            #expect(HelperRequest.parse(request.line) == request)
        }
    }

    @Test func requestParsingIsStrict() {
        #expect(HelperRequest.parse("power") == nil)
        #expect(HelperRequest.parse("power 1 2") == nil)
        #expect(HelperRequest.parse("power -1") == nil)
        #expect(HelperRequest.parse("rusage 1 12 -5") == nil)
        #expect(HelperRequest.parse("rusage 1 12 /bin/sh") == nil)
        #expect(HelperRequest.parse("exec 1 /bin/sh") == nil)
        #expect(HelperRequest.parse("") == nil)
        let tooMany = "rusage 1 " + Array(repeating: "1", count: HelperProtocol.maxPIDsPerRequest + 1).joined(separator: " ")
        #expect(HelperRequest.parse(tooMany) == nil)
    }

    @Test func repliesRoundTrip() {
        let reading = PowerReading(elapsedNS: 60_012_345_678, cpuMillijoules: 25_734, gpuMillijoules: 0, aneMillijoules: 0)
        let usage = RootRusage(pid: 391, startAbstime: 123, energyNJ: 456_789, userTime: 1_000, systemTime: 2_000,
                               interruptWakeups: 3, idleWakeups: 4, diskReadBytes: 5, diskWriteBytes: 6, footprintBytes: 7)
        for reply in [HelperReply.power(seq: 1, reading), .power(seq: 2, nil), .rusage(seq: 3, [usage, usage]),
                      .rusage(seq: 4, []), .error("unknown request")] {
            #expect(HelperReply.parse(reply.line) == reply)
        }
    }

    @Test func replyParsingRejectsNonsense() {
        #expect(HelperReply.parse("power 1 5 -3 0 0") == nil)
        #expect(HelperReply.parse("power 1 5 nan 0 0") == nil)
        #expect(HelperReply.parse("rusage 1 12:3") == nil)
        // What a pseudo-terminal would echo back: requests, not replies.
        #expect(HelperReply.parse("power 1") == nil)
        #expect(HelperReply.parse("rusage 2 12 13") == nil)
    }

    @Test func statusLine() {
        let status = HelperStatus(version: HelperProtocol.version, root: true)
        #expect(HelperStatus.parse(status.line + "\r\n") == status)
        #expect(HelperStatus.parse("sudo: a password is required") == nil)
    }

    static func plist(_ body: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>\(body)</dict></plist>
        """.utf8)
    }

    @Test func readsPowermetricsEnergy() throws {
        let data = Self.plist("""
            <key>is_delta</key><true/><key>elapsed_ns</key><integer>2006412345</integer>
            <key>processor</key><dict>
              <key>clusters</key><array/>
              <key>cpu_energy</key><integer>3103</integer><key>cpu_power</key><real>1546.5</real>
              <key>combined_power</key><real>1546.5</real>
            </dict>
            """)
        let reading = try #require(PowermetricsPlist.reading(from: data))
        #expect(reading.elapsedNS == 2_006_412_345)
        #expect(reading.cpuMillijoules == 3103)
        #expect(reading.gpuMillijoules == 0)
    }

    @Test func fallsBackToPowerTimesElapsed() throws {
        let data = Self.plist("""
            <key>elapsed_ns</key><integer>2000000000</integer>
            <key>processor</key><dict><key>cpu_power</key><real>500</real><key>gpu_power</key><real>10</real></dict>
            """)
        let reading = try #require(PowermetricsPlist.reading(from: data))
        #expect(reading.cpuMillijoules == 1000)
        #expect(reading.gpuMillijoules == 20)
    }

    @Test func rejectsSamplesWithoutACPUFigure() {
        #expect(PowermetricsPlist.reading(from: Self.plist("<key>elapsed_ns</key><integer>5</integer>")) == nil)
        #expect(PowermetricsPlist.reading(from: Data("not a plist".utf8)) == nil)
    }
}

final class FakeSampler: PowerSampler {
    var readings: [PowerReading?]
    var stopped = false
    init(_ readings: [PowerReading?]) { self.readings = readings }
    func sample() -> PowerReading? { readings.isEmpty ? nil : readings.removeFirst() }
    func stop() { stopped = true }
}

@Suite struct HelperServerTests {
    let reading = PowerReading(elapsedNS: 2_000_000_000, cpuMillijoules: 900, gpuMillijoules: 0, aneMillijoules: 0)

    func usage(_ pid: Int32) -> RootRusage? {
        pid == 99 ? nil : RootRusage(pid: pid, startAbstime: 1, energyNJ: UInt64(pid) * 10, userTime: 0, systemTime: 0,
                                     interruptWakeups: 0, idleWakeups: 0, diskReadBytes: 0, diskWriteBytes: 0, footprintBytes: 0)
    }

    @Test func answersEachRequest() {
        let server = HelperServer(sampler: FakeSampler([reading, nil]), rusage: usage)
        #expect(server.reply(to: "power 1") == .power(seq: 1, reading))
        #expect(server.reply(to: "power 2") == .power(seq: 2, nil))
        #expect(server.reply(to: "rusage 3 5 99 6") == .rusage(seq: 3, [usage(5)!, usage(6)!]))
        #expect(server.reply(to: "rm -rf /") == .error("unknown request"))
    }

    @Test func servesUntilInputClosesThenStops() throws {
        let sampler = FakeSampler([reading])
        let server = HelperServer(sampler: sampler, rusage: usage)
        var toServer: [Int32] = [-1, -1], fromServer: [Int32] = [-1, -1]
        #expect(pipe(&toServer) == 0 && pipe(&fromServer) == 0)
        let requests = "power 1\n\nrusage 2 7\r\nbogus\n"
        _ = requests.withCString { write(toServer[1], $0, strlen($0)) }
        close(toServer[1])
        server.serve(input: toServer[0], output: fromServer[1])
        close(fromServer[1])
        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while case let count = read(fromServer[0], &chunk, chunk.count), count > 0 { output.append(contentsOf: chunk[..<count]) }
        let lines = String(decoding: output, as: UTF8.self).split(separator: "\n").compactMap { HelperReply.parse($0) }
        #expect(lines == [.power(seq: 1, reading), .rusage(seq: 2, [usage(7)!]), .error("unknown request")])
        #expect(sampler.stopped)
    }

    @Test func readsItsOwnRusage() throws {
        let mine = try #require(RootRusageReader.read(getpid()))
        #expect(mine.pid == getpid())
        #expect(mine.userTime + mine.systemTime > 0)
    }
}
