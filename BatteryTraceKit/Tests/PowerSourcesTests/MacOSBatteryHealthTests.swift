import Foundation
@testable import PowerSources
import Testing

@Suite struct MacOSBatteryHealthTests {
    /// The shape `system_profiler SPPowerDataType -xml -detailLevel mini`
    /// printed on macOS 27, cut down.
    static let output = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><array><dict>
      <key>_dataType</key><string>SPPowerDataType</string>
      <key>_items</key><array>
        <dict>
          <key>_name</key><string>spbattery_information</string>
          <key>sppower_battery_health_info</key><dict>
            <key>sppower_battery_cycle_count</key><integer>625</integer>
            <key>sppower_battery_health</key><string>Good</string>
            <key>sppower_battery_health_maximum_capacity</key><string>80%</string>
          </dict>
        </dict>
        <dict><key>_name</key><string>sppower_information</string></dict>
      </array>
    </dict></array></plist>
    """

    @Test func readsTheMaximumCapacity() {
        #expect(MacOSBatteryHealth.parse(Data(Self.output.utf8)) == 80)
    }

    @Test func nothingWithoutABatteryOrAFigure() {
        let desktop = Self.output.replacingOccurrences(of: "<key>sppower_battery_health_maximum_capacity</key><string>80%</string>", with: "")
        #expect(MacOSBatteryHealth.parse(Data(desktop.utf8)) == nil)
        #expect(MacOSBatteryHealth.parse(Data("not a plist".utf8)) == nil)
        let odd = Self.output.replacingOccurrences(of: "80%", with: "unknown")
        #expect(MacOSBatteryHealth.parse(Data(odd.utf8)) == nil)
    }
}
