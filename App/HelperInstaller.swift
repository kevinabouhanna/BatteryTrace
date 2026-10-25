import AppKit
import Foundation
import HelperProtocol
import PowerSources

/// Installs and removes the optional privileged helper from inside the app.
///
/// The app carries the helper (`Contents/MacOS/app.batterytrace.helper`) and
/// its installer (`Contents/Resources/helper-setup.sh`), and runs the
/// installer through macOS's administrator dialog: password or Touch ID, once.
///
/// It goes through `do shell script … with administrator privileges`, as
/// NetworkMonitor does, because that needs no Developer ID. `SMAppService.daemon`
/// would need a team identifier to say which apps may talk to the daemon, and
/// an ad-hoc signature has none. See the helper's own header for the rest.
enum HelperInstaller {
    enum Outcome: Equatable {
        case done
        /// The user closed the password dialog. Not an error.
        case cancelled
        case failed(String)
    }

    static var bundledHelper: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(HelperProtocol.helperName)")
    }

    static var setupScript: URL? {
        Bundle.main.url(forResource: "helper-setup", withExtension: "sh")
    }

    /// Whether this copy carries the helper and its installer.
    static var canInstall: Bool {
        FileManager.default.isExecutableFile(atPath: bundledHelper.path) && setupScript != nil
    }

    /// Installs or replaces the helper. Shows the administrator dialog and
    /// blocks until it's answered: call it from a user action.
    static func install() -> Outcome {
        guard canInstall, let script = setupScript else {
            return .failed("This copy of Battery Trace is missing its helper. Download it again.")
        }
        return runAsAdministrator(
            ["/bin/bash", script.path, "install", bundledHelper.path, NSUserName()],
            prompt: "Battery Trace needs your permission once to install its helper, "
                + "which reads Apple's CPU energy figure and every process's energy.")
    }

    static func uninstall() -> Outcome {
        guard FileManager.default.fileExists(atPath: HelperProtocol.helperPath)
                || FileManager.default.fileExists(atPath: HelperProtocol.sudoersPath)
        else { return .done }
        guard let script = setupScript else {
            return .failed("This copy of Battery Trace is missing its uninstaller.")
        }
        return runAsAdministrator(["/bin/bash", script.path, "uninstall"],
                                  prompt: "Battery Trace needs your permission to remove its helper.")
    }

    // MARK: Running as root

    static func runAsAdministrator(_ arguments: [String], prompt: String) -> Outcome {
        guard let script = NSAppleScript(source: appleScript(running: arguments, prompt: prompt)) else {
            return .failed("Couldn't prepare the administrator request.")
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        guard let error else { return .done }
        // -128 is AppleScript's "User canceled."
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { return .cancelled }
        return .failed((error[NSAppleScript.errorMessage] as? String) ?? "The helper could not be installed.")
    }

    /// The AppleScript for one root command. Two layers of quoting: each
    /// argument single-quoted for `/bin/sh`, then the whole command made an
    /// AppleScript string literal. Paths come from the bundle, and a renamed
    /// folder could put either kind of quote in them.
    static func appleScript(running arguments: [String], prompt: String) -> String {
        let command = arguments.map(shellQuoted).joined(separator: " ")
        return "do shell script \(appleScriptLiteral(command)) "
            + "with prompt \(appleScriptLiteral(prompt)) with administrator privileges"
    }

    static func shellQuoted(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptLiteral(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\")
                   .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// The helper's state for Settings, and the switch that tells the sampling
/// engine to use it.
@MainActor
final class PrivilegedHelperController: ObservableObject {
    typealias Installation = PrivilegedHelperClient.Installation

    /// Nil while it's being checked.
    @Published private(set) var installation: Installation?
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?

    /// Called with whether the engine should use the helper, and whether to
    /// start it afresh (it was just replaced).
    var onChange: (_ use: Bool, _ restart: Bool) -> Void = { _, _ in }

    var canInstall: Bool { HelperInstaller.canInstall }

    /// Asks the installed helper its version, off the main thread: it runs
    /// `sudo -n` once.
    func refresh(restart: Bool = false) {
        guard PrivilegedHelperClient.isInstalled else {
            installation = .missing
            onChange(false, false)
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let state = PrivilegedHelperClient.installation()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.installation = state
                    self.onChange(state == .current, restart)
                }
            }
        }
    }

    func install() {
        run(HelperInstaller.install, restart: true)
    }

    func uninstall() {
        // Stopped first, so nothing is using it while it's removed.
        onChange(false, false)
        run(HelperInstaller.uninstall, restart: false)
    }

    private func run(_ action: () -> HelperInstaller.Outcome, restart: Bool) {
        isBusy = true
        message = nil
        let outcome = action()
        isBusy = false
        switch outcome {
        case .done, .cancelled: break
        case .failed(let reason): message = reason
        }
        refresh(restart: restart)
    }
}
