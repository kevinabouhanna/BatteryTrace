import BatteryTraceCore
import HelperProtocol
@testable import Sampling
import Testing

@Suite struct PrivilegedPowerMetricsTests {
    func reading(seconds: Double) -> PowerReading {
        PowerReading(elapsedNS: UInt64(seconds * 1e9), cpuMillijoules: 1000, gpuMillijoules: 0, aneMillijoules: 0)
    }

    @Test func aSampleCoversAnIntervalOfTheSameLength() {
        #expect(PrivilegedPowerMetrics.covers(reading(seconds: 60.01), interval: 60))
        #expect(PrivilegedPowerMetrics.covers(reading(seconds: 2.2), interval: 2))
        #expect(PrivilegedPowerMetrics.covers(reading(seconds: 62.9), interval: 60))
    }

    @Test func theFirstSampleAfterAStartIsTurnedDown() {
        // It covers powermetrics' start-up, not Battery Trace's interval.
        #expect(!PrivilegedPowerMetrics.covers(reading(seconds: 1.6), interval: 60))
        #expect(!PrivilegedPowerMetrics.covers(reading(seconds: 2.5), interval: 2))
        #expect(!PrivilegedPowerMetrics.covers(reading(seconds: 0), interval: 0))
    }

    @Test func replacesOnlyTheCPURow() {
        var sample = PowerMetricsSample(endUptimeNS: 0, durationSeconds: 60, components: [
            ComponentEnergy(id: .cpu, joules: 8, provenance: .measured),
            ComponentEnergy(id: .gpu, joules: 2, provenance: .measured),
        ], coalitions: [:], processes: [], processDeltas: [:])
        PrivilegedPowerMetrics.replaceCPU(in: &sample, joules: 26)
        #expect(sample.components.map(\.joules) == [26, 2])

        sample.components.removeFirst()
        PrivilegedPowerMetrics.replaceCPU(in: &sample, joules: 26)
        #expect(sample.components.first { $0.id == .cpu }?.joules == 26)
    }
}
