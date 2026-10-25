import Foundation
import Updates

/// `bttrace updates [--as 0.6.0]`: what Check for Updates… would say.
enum UpdatesCommand {
    static func run(_ arguments: inout Arguments) {
        guard let current = AppVersion(arguments.value("--as") ?? "0.0.0") else {
            print("--as takes a version, like 0.6.0")
            return
        }
        let done = DispatchSemaphore(value: 0)
        Task {
            switch await UpdateCheck.check(current: current) {
            case .upToDate(let latest):
                print("Up to date: the latest release is \(latest).")
            case .available(let release):
                print("\(release.version) is available (running as \(current)).")
                print("Download: \(release.downloadURL?.absoluteString ?? "none; page \(release.pageURL)")")
                print("What's new:\n\(release.whatsNew.isEmpty ? "(no section)" : release.whatsNew)")
            case .failed(let reason):
                print("Couldn't check: \(reason)")
            }
            done.signal()
        }
        done.wait()
    }
}
