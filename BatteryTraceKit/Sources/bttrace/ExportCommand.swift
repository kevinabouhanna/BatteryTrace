import Foundation
import Storage

/// The app's history as CSV, from the command line.
enum ExportCommand {
    static func run(_ arguments: inout Arguments) {
        let directory = URL(fileURLWithPath: arguments.value("--to") ?? FileManager.default.currentDirectoryPath)
        let days = arguments.double("--days", default: 7)
        let database = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Battery Trace/history.sqlite")
        do {
            let export = try HistoryStore(url: database).exportCSV(since: Date().addingTimeInterval(-days * 86400))
            let apps = directory.appendingPathComponent("battery-trace-apps.csv")
            let system = directory.appendingPathComponent("battery-trace-system.csv")
            try export.apps.write(to: apps, atomically: true, encoding: .utf8)
            try export.system.write(to: system, atomically: true, encoding: .utf8)
            print("Wrote \(apps.path) and \(system.path)")
        } catch {
            print("export failed: \(error)")
        }
    }
}
