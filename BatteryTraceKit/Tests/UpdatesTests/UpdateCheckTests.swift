import Foundation
import Testing
import Updates

@Suite struct UpdateCheckTests {
    func version(_ text: String) -> AppVersion { AppVersion(text)! }

    @Test func versionsCompareNumberByNumber() {
        #expect(version("0.10.0") > version("0.9.0"))
        #expect(version("v0.7.0") > version("0.6.0"))
        #expect(version("1.0") == version("1.0.0"))
        #expect(!(version("0.6.0") < version("0.6.0")))
        #expect(version("0.6.0-beta") == version("0.6.0"))
        #expect(AppVersion("") == nil)
        #expect(AppVersion("latest") == nil)
        #expect(AppVersion("1..2") == nil)
    }

    static let releaseJSON = """
    {
      "tag_name": "v0.7.0",
      "html_url": "https://github.com/kevinabouhanna/BatteryTrace/releases/tag/v0.7.0",
      "draft": false,
      "prerelease": false,
      "body": "## What's new in 0.7.0\\r\\n\\r\\n- **Check for updates** (#26): one request.\\r\\n- Signed builds when set up.\\r\\n\\r\\n### Installing\\r\\n\\r\\n1. Download it.\\r\\n\\r\\n---\\r\\n## What's Changed\\r\\n* Something by someone",
      "assets": [
        {"name": "notes.txt", "browser_download_url": "https://example.com/notes.txt"},
        {"name": "BatteryTrace.dmg", "browser_download_url": "https://github.com/kevinabouhanna/BatteryTrace/releases/download/v0.7.0/BatteryTrace.dmg"}
      ]
    }
    """

    @Test func readsTheLatestRelease() throws {
        let release = try #require(UpdateCheck.parse(Data(Self.releaseJSON.utf8)))
        #expect(release.version == version("0.7.0"))
        #expect(release.downloadURL?.lastPathComponent == "BatteryTrace.dmg")
        #expect(release.whatsNew == "• Check for updates (#26): one request.\n• Signed builds when set up.")
    }

    @Test func ignoresDraftsAndPreReleases() {
        let draft = Self.releaseJSON.replacingOccurrences(of: "\"draft\": false", with: "\"draft\": true")
        let pre = Self.releaseJSON.replacingOccurrences(of: "\"prerelease\": false", with: "\"prerelease\": true")
        #expect(UpdateCheck.parse(Data(draft.utf8)) == nil)
        #expect(UpdateCheck.parse(Data(pre.utf8)) == nil)
        #expect(UpdateCheck.parse(Data("{\"message\": \"Not Found\"}".utf8)) == nil)
    }

    @Test func comparesWithTheRunningVersion() throws {
        let release = try #require(UpdateCheck.parse(Data(Self.releaseJSON.utf8)))
        #expect(UpdateCheck.outcome(current: version("0.6.0"), latest: release) == .available(release))
        #expect(UpdateCheck.outcome(current: version("0.7.0"), latest: release) == .upToDate(latest: version("0.7.0")))
        // A build newer than the latest release (a development build) is up to date.
        #expect(UpdateCheck.outcome(current: version("0.8.0"), latest: release) == .upToDate(latest: version("0.7.0")))
        if case .failed = UpdateCheck.outcome(current: version("0.6.0"), latest: nil) {} else { Issue.record("expected failure") }
    }

    @Test func notesWithoutAWhatsNewSectionGiveNothing() {
        #expect(UpdateCheck.whatsNew(from: "### Installing\n\n1. Download it.") == "")
    }
}
