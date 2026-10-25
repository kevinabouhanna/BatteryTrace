import Foundation

/// A version like `0.7.0`, compared number by number: 0.10.0 is newer than
/// 0.9.0. A leading `v` and anything after a `-` are ignored.
public struct AppVersion: Comparable, Hashable, CustomStringConvertible, Sendable {
    public let parts: [Int]

    public init?(_ text: String) {
        var core = text.trimmingCharacters(in: .whitespaces)
        if core.hasPrefix("v") || core.hasPrefix("V") { core.removeFirst() }
        if let dash = core.firstIndex(of: "-") { core = String(core[..<dash]) }
        let numbers = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !numbers.isEmpty, numbers.count <= 4, numbers.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        parts = numbers.compactMap { $0 }
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        for index in 0..<max(a.parts.count, b.parts.count) {
            let x = index < a.parts.count ? a.parts[index] : 0
            let y = index < b.parts.count ? b.parts[index] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }

    public func hash(into hasher: inout Hasher) {
        var trimmed = parts
        while trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
    }
}

/// The newest release on GitHub, as much of it as the app shows.
public struct Release: Equatable, Sendable {
    public var version: AppVersion
    /// The release's "What's new" section, as plain text.
    public var whatsNew: String
    public var pageURL: URL
    /// The disk image, when the release has one.
    public var downloadURL: URL?

    public init(version: AppVersion, whatsNew: String, pageURL: URL, downloadURL: URL?) {
        self.version = version
        self.whatsNew = whatsNew
        self.pageURL = pageURL
        self.downloadURL = downloadURL
    }
}

/// Asks GitHub which release is newest. One HTTPS request, made only when
/// asked to: by Check for Updates…, or once a day if that's turned on.
public enum UpdateCheck {
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/kevinabouhanna/BatteryTrace/releases/latest")!
    public static let diskImageName = "BatteryTrace.dmg"

    public enum Outcome: Equatable, Sendable {
        case upToDate(latest: AppVersion)
        case available(Release)
        case failed(String)
    }

    /// Fetches the latest release and compares it with `current`.
    public static func check(current: AppVersion) async -> Outcome {
        var request = URLRequest(url: latestReleaseURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        // GitHub requires a User-Agent. This one names the app and nothing else.
        request.setValue("BatteryTrace", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed("No answer from GitHub.") }
            guard http.statusCode == 200 else { return .failed("GitHub answered \(http.statusCode).") }
            return outcome(current: current, latest: parse(data))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    public static func outcome(current: AppVersion, latest: Release?) -> Outcome {
        guard let latest else { return .failed("GitHub's answer didn't name a release.") }
        return latest.version > current ? .available(latest) : .upToDate(latest: latest.version)
    }

    /// Reads GitHub's `releases/latest` JSON. Nil for a draft, a pre-release
    /// or anything without a version tag.
    public static func parse(_ data: Data) -> Release? {
        struct Asset: Decodable {
            var name: String
            var browser_download_url: URL
        }
        struct Payload: Decodable {
            var tag_name: String
            var html_url: URL
            var body: String?
            var draft: Bool?
            var prerelease: Bool?
            var assets: [Asset]?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.draft != true, payload.prerelease != true,
              let version = AppVersion(payload.tag_name)
        else { return nil }
        return Release(
            version: version,
            whatsNew: whatsNew(from: payload.body ?? ""),
            pageURL: payload.html_url,
            downloadURL: payload.assets?.first { $0.name == diskImageName }?.browser_download_url
        )
    }

    /// The release notes' "What's new" section, as plain text: from its
    /// heading to the next heading or rule, bullets as •, bold marks removed.
    public static func whatsNew(from body: String) -> String {
        var lines: [String] = []
        var inSection = false
        for raw in body.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                if inSection { break }
                inSection = line.lowercased().contains("what's new") || line.lowercased().contains("what’s new")
                continue
            }
            if line.hasPrefix("---") { if inSection { break } else { continue } }
            guard inSection else { continue }
            var text = line.replacingOccurrences(of: "**", with: "")
            if text.hasPrefix("- ") || text.hasPrefix("* ") { text = "• " + text.dropFirst(2) }
            lines.append(text)
        }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}
