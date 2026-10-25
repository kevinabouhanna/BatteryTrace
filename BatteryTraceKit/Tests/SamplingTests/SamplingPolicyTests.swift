import BatteryTraceCore
import Sampling
import Testing

@Suite struct SamplingPolicyTests {
    let policy = SamplingPolicy()

    @Test func closedPopoverReadsTheMenuBarTotalOftenAndAttributesOnceAMinute() throws {
        let schedule = try #require(policy.schedule(for: .init()))
        #expect(schedule.interval == 5)
        #expect(schedule.attributionInterval == 60)
        #expect(schedule.leeway == 0.5)
        #expect(!schedule.detailed)
    }

    @Test func lowPowerModeHalvesTheRate() throws {
        let schedule = try #require(policy.schedule(for: .init(lowPowerMode: true)))
        #expect(schedule.interval == 10)
        #expect(schedule.attributionInterval == 60)
    }

    @Test func anOpenPopoverAttributesEveryTickWithDetail() throws {
        let schedule = try #require(policy.schedule(for: .init(popoverVisible: true, lowPowerMode: true)))
        #expect(schedule.interval == 2)
        #expect(schedule.attributeEvery == 1)
        #expect(schedule.detailed)
    }

    @Test func asleepScreensSlowEverythingToAMinute() throws {
        let schedule = try #require(policy.schedule(for: .init(popoverVisible: true, screensAsleep: true)))
        #expect(schedule.interval == 60)
        #expect(!schedule.detailed)
    }

    @Test func nothingRunsWhileTheMacSleeps() {
        #expect(policy.schedule(for: .init(popoverVisible: true, systemAsleep: true)) == nil)
    }

    @Test func theUsersIntervalIsHonouredAndClamped() throws {
        let slow = try #require(SamplingPolicy(closedInterval: 10).schedule(for: .init()))
        #expect(slow.interval == 10)
        #expect(slow.attributeEvery == 6)
        let silly = try #require(SamplingPolicy(closedInterval: 0.01).schedule(for: .init()))
        #expect(silly.interval == 0.5)
    }
}
