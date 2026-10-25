import BatteryTraceCore
@testable import PowerSources
import Testing

@Suite struct IOReportPlanTests {
    /// The channel list of an M1 on macOS 27, after subscription filtering.
    static let m1Names = ["DISP", "DISPX", "SOC_AON", "SOC_REST", "BAT", "DRAM", "ECPU", "PCPU", "GPU", "ANE",
                          "ISP", "AVE", "VDEC", "MSR", "DCS", "GPU SRAM",
                          "ECPU", "PCPU", "CPU Energy", "PCIe Port 0 Energy", "apciec0 Energy", "GPU Energy"]
    static let m1Groups = Array(repeating: "PMP", count: 16) + Array(repeating: "Energy Model", count: 6)

    func plan(_ id: ComponentID) -> [String]? {
        IOReportComponentSource.describePlans(names: Self.m1Names, groups: Self.m1Groups).first { $0.component == id }?.candidateLabels
    }

    @Test func cpuPrefersPMPsClusterCountersOverTheFrozenEnergyModel() {
        #expect(plan(.cpu) == ["PMP [ECPU + PCPU]", "Energy Model [CPU Energy]", "Energy Model clusters [ECPU + PCPU]"])
    }

    @Test func gpuPrefersPMPSoOneDriverServesEverything() {
        #expect(plan(.gpu)?.first == "PMP [GPU + GPU SRAM]")
        #expect(plan(.gpu)?.contains("Energy Model [GPU Energy]") == true)
    }

    @Test func memoryIsDRAMPlusItsController() {
        #expect(plan(.memory)?.first == "PMP [DRAM + DCS]")
    }

    @Test func otherChipBlocksTakeOnlyWhatNoComponentClaimed() throws {
        let other = try #require(plan(.otherSoC)?.first)
        #expect(other == "PMP [SOC_AON + SOC_REST + BAT + ISP + AVE + VDEC + MSR]")
    }

    @Test func perCoreAndClusterManagerChannelsAreNeverCountedTwice() {
        let names = Self.m1Names + ["ECORE0", "PCORE3", "ECPM", "PCPM"]
        let groups = Self.m1Groups + ["PMP", "PMP", "PMP", "PMP"]
        let other = IOReportComponentSource.describePlans(names: names, groups: groups).first { $0.component == .otherSoC }
        #expect(other?.candidateLabels.first?.contains("CORE") == false)
        #expect(other?.candidateLabels.first?.contains("CPM") == false)
        #expect(!IOReportComponentSource.isWanted(name: "ECORE0", group: "PMP"))
        #expect(!IOReportComponentSource.isWanted(name: "PCPUDTL04", group: "Energy Model"))
        #expect(!IOReportComponentSource.isWanted(name: "ECPU0", group: "Energy Model"))
        #expect(IOReportComponentSource.isWanted(name: "ECPU", group: "Energy Model"))
    }

    @Test func units() {
        #expect(IOReportComponentSource.joulesPerUnit("mJ") == 1e-3)
        #expect(IOReportComponentSource.joulesPerUnit(" nJ ") == 1e-9)
        #expect(IOReportComponentSource.joulesPerUnit("µJ") == 1e-6)
        #expect(IOReportComponentSource.joulesPerUnit("ticks") == nil)
    }

    @Test func gpuClientCreatorParsing() {
        #expect(GPUClientReader.pid(fromCreator: "pid 690, WindowServer") == 690)
        #expect(GPUClientReader.pid(fromCreator: "WindowServer") == nil)
    }

    @Test func displayModelIsZeroAtTheBottomAndAboutFiveWattsAtTheTop() {
        #expect(DisplayBacklightSource.watts(slider: 0, scale: 1) == 0)
        #expect(abs(DisplayBacklightSource.watts(slider: 1, scale: 1) - 5.035) < 0.01)
        #expect(DisplayBacklightSource.watts(slider: 0.5, scale: 1) < DisplayBacklightSource.watts(slider: 0.75, scale: 1))
    }
}
