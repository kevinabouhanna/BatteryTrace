import Attribution
import BatteryTraceCore
import Foundation

/// Local history, in one SQLite file.
///
/// | table            | resolution | kept    | holds                                |
/// |------------------|------------|---------|--------------------------------------|
/// | `live`           | each live reading (≈5 s) | 1 hour | total watts, battery %     |
/// | `minute`         | 1 minute   | 7 days  | totals, measured energy, gauge windows |
/// | `minute_component` | 1 minute | 7 days  | energy per component                  |
/// | `minute_app`     | 1 minute   | 24 hours| energy per app (CPU, GPU, ANE)        |
/// | `minute_process` | 1 minute   | 24 hours| CPU energy per app per process name   |
/// | `hour_app`       | 1 hour     | 7 days  | energy per app, rolled up from minutes |
///
/// Writes are buffered and committed in one transaction every few minutes
/// (WAL, `synchronous=NORMAL`: no fsync per commit), so the disk wakes rarely.
/// Queries merge what's still buffered, so the UI never sees a gap.
///
/// Not thread-safe: the app uses it from one serial queue.
public final class HistoryStore {
    public struct Limits: Sendable {
        public var liveRetention: TimeInterval = 3600
        public var minuteRetention: TimeInterval = 7 * 86400
        public var appMinuteRetention: TimeInterval = 86400
        public var hourRetention: TimeInterval = 7 * 86400
        /// Above this, process and app minutes are trimmed harder.
        public var maxBytes: Int64 = 64 * 1024 * 1024
        /// How long buffered data may wait before it is written.
        public var flushInterval: TimeInterval = 300
        public init() {}
    }

    public let url: URL
    public let limits: Limits
    let db: SQLiteDatabase

    private var appIDs: [AppKey: Int64] = [:]
    private var pendingLive: [LiveReading] = []
    private var pendingMinutes: [Int64: EnergyLedger] = [:]
    var pendingMeta: [Int64: MinuteMeta] = [:]
    private var lastFlush = Date()
    private var lastPrune = Date.distantPast

    struct MinuteMeta {
        var batteryPercent: Double?
        var onExternalPower = true
        var charging = false
    }

    struct DailyBattery {
        var health: Double
        var nominalMAh: Int
        var designMAh: Int
        var cycles: Int?
    }

    var pendingDaily: [Int64: DailyBattery] = [:]

    public init(url: URL, limits: Limits = Limits()) throws {
        self.url = url
        self.limits = limits
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        db = try SQLiteDatabase(path: url.path)
        try db.execute("""
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = NORMAL;
        PRAGMA auto_vacuum = INCREMENTAL;
        CREATE TABLE IF NOT EXISTS live (ts INTEGER PRIMARY KEY, watts REAL, battery_pct REAL, on_ac INTEGER) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS minute (
            ts INTEGER PRIMARY KEY, seconds REAL, battery_seconds REAL,
            sensor_j REAL, sensor_seconds REAL, sensor_src INTEGER,
            telemetry_j REAL, telemetry_seconds REAL, unclaimed_j REAL,
            battery_pct REAL, on_ac INTEGER) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS minute_component (ts INTEGER, component TEXT, joules REAL, provenance INTEGER, PRIMARY KEY (ts, component)) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS apps (id INTEGER PRIMARY KEY, key TEXT UNIQUE NOT NULL, name TEXT, kind INTEGER, bundle_id TEXT);
        CREATE TABLE IF NOT EXISTS minute_app (ts INTEGER, app INTEGER, cpu_j REAL, gpu_j REAL, ane_j REAL, PRIMARY KEY (ts, app)) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS minute_process (ts INTEGER, app INTEGER, name TEXT, cpu_j REAL, PRIMARY KEY (ts, app, name)) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS hour_app (ts INTEGER, app INTEGER, cpu_j REAL, gpu_j REAL, ane_j REAL, PRIMARY KEY (ts, app)) WITHOUT ROWID;
        """)
        try migrate()
        try db.statement("SELECT id, key FROM apps").rows { row in
            if let key = row.string(1) { appIDs[AppKey(rawValue: key)] = row.int(0) }
        }
    }

    /// Schema changes since the first release, in order, tracked in
    /// `PRAGMA user_version`. Each runs once per history file.
    private func migrate() throws {
        var version: Int64 = 0
        try db.statement("PRAGMA user_version").rows { version = $0.int(0) }
        if version < 1 {
            // 0.5.0: whether the battery was charging each minute, and one
            // health reading a day, kept indefinitely.
            try db.transaction {
                try db.execute("ALTER TABLE minute ADD COLUMN charging INTEGER")
                try db.execute("""
                CREATE TABLE IF NOT EXISTS battery_daily (
                    day INTEGER PRIMARY KEY, health REAL, nominal_mah INTEGER, design_mah INTEGER, cycles INTEGER) WITHOUT ROWID
                """)
                try db.execute("PRAGMA user_version = 1")
            }
        }
    }

    // MARK: Recording

    public func record(_ reading: LiveReading) {
        pendingLive.append(reading)
    }

    /// Adds an interval to the minute its end falls in.
    public func record(_ report: IntervalReport) {
        let minute = Self.minute(of: report.endDate)
        pendingMinutes[minute, default: EnergyLedger()].add(report)
        if let window = report.telemetry { pendingMinutes[minute, default: EnergyLedger()].add(window) }
        var meta = pendingMeta[minute] ?? MinuteMeta()
        meta.batteryPercent = report.system.battery.percent
        meta.onExternalPower = report.onExternalPower
        meta.charging = report.system.battery.isCharging
        pendingMeta[minute] = meta
        let battery = report.system.battery
        if let health = battery.healthPercent, let nominal = battery.nominalCapacityMAh, let design = battery.designCapacityMAh {
            pendingDaily[Self.day(of: report.endDate)] = DailyBattery(health: health, nominalMAh: nominal, designMAh: design, cycles: battery.cycleCount)
        }
    }

    /// Writes buffered data if it has waited long enough. Cheap otherwise.
    public func flushIfDue(now: Date = Date()) {
        guard now.timeIntervalSince(lastFlush) >= limits.flushInterval else { return }
        try? flush(now: now)
    }

    /// Writes everything buffered, in one transaction. Prunes hourly.
    public func flush(now: Date = Date()) throws {
        lastFlush = now
        guard !pendingLive.isEmpty || !pendingMinutes.isEmpty || !pendingDaily.isEmpty else { return }
        let live = pendingLive
        let minutes = pendingMinutes
        let meta = pendingMeta
        let daily = pendingDaily
        try db.transaction {
            let insertDaily = try db.statement("INSERT OR REPLACE INTO battery_daily VALUES (?, ?, ?, ?, ?)")
            for (day, reading) in daily {
                try insertDaily.bind(day, reading.health, reading.nominalMAh, reading.designMAh, reading.cycles).run()
                insertDaily.reset()
            }
            let insertLive = try db.statement("INSERT OR REPLACE INTO live VALUES (?, ?, ?, ?)")
            for reading in live {
                try insertLive.bind(Int64(reading.date.timeIntervalSince1970.rounded()), reading.systemWatts,
                                    reading.battery.percent, reading.battery.isOnExternalPower).run()
                insertLive.reset()
            }
            for (minute, ledger) in minutes {
                try write(minute: minute, ledger: ledger, meta: meta[minute] ?? MinuteMeta())
            }
        }
        pendingLive.removeAll(keepingCapacity: true)
        pendingMinutes.removeAll(keepingCapacity: true)
        pendingMeta.removeAll(keepingCapacity: true)
        pendingDaily.removeAll(keepingCapacity: true)
        if now.timeIntervalSince(lastPrune) >= 3600 {
            lastPrune = now
            try prune(now: now)
        }
    }

    private func write(minute: Int64, ledger: EnergyLedger, meta: MinuteMeta) throws {
        // A minute may already be partly stored (flushes split it): add to it.
        try db.statement("""
        INSERT INTO minute (ts, seconds, battery_seconds, sensor_j, sensor_seconds, sensor_src,
                            telemetry_j, telemetry_seconds, unclaimed_j, battery_pct, on_ac, charging)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(ts) DO UPDATE SET
            seconds = seconds + excluded.seconds,
            battery_seconds = battery_seconds + excluded.battery_seconds,
            sensor_j = coalesce(sensor_j, 0) + coalesce(excluded.sensor_j, 0),
            sensor_seconds = sensor_seconds + excluded.sensor_seconds,
            sensor_src = coalesce(excluded.sensor_src, sensor_src),
            telemetry_j = telemetry_j + excluded.telemetry_j,
            telemetry_seconds = telemetry_seconds + excluded.telemetry_seconds,
            unclaimed_j = unclaimed_j + excluded.unclaimed_j,
            battery_pct = coalesce(excluded.battery_pct, battery_pct),
            on_ac = excluded.on_ac,
            charging = excluded.charging
        """).bind(minute, ledger.durationSeconds, ledger.onBatterySeconds,
                  ledger.sensorSeconds > 0 ? ledger.sensorJoules : nil, ledger.sensorSeconds,
                  ledger.sensorSource.map { Int($0.rawValue) },
                  ledger.telemetryJoules, ledger.telemetrySeconds, ledger.unclaimedJoules,
                  meta.batteryPercent, meta.onExternalPower, meta.charging).run()

        let component = try db.statement("""
        INSERT INTO minute_component VALUES (?, ?, ?, ?)
        ON CONFLICT(ts, component) DO UPDATE SET joules = joules + excluded.joules, provenance = max(provenance, excluded.provenance)
        """)
        for (id, total) in ledger.components {
            try component.bind(minute, id.rawValue, total.joules, Int(total.provenance.rawValue)).run()
            component.reset()
        }

        let app = try db.statement("""
        INSERT INTO minute_app VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(ts, app) DO UPDATE SET cpu_j = cpu_j + excluded.cpu_j, gpu_j = gpu_j + excluded.gpu_j, ane_j = ane_j + excluded.ane_j
        """)
        let process = try db.statement("""
        INSERT INTO minute_process VALUES (?, ?, ?, ?)
        ON CONFLICT(ts, app, name) DO UPDATE SET cpu_j = cpu_j + excluded.cpu_j
        """)
        for total in ledger.apps.values where total.joules > 0 {
            let id = try appID(for: total.identity)
            try app.bind(minute, id, total.cpuJoules, total.gpuJoules, total.aneJoules).run()
            app.reset()
            for (name, joules) in total.processes where joules > 0 {
                try process.bind(minute, id, name, joules).run()
                process.reset()
            }
        }
    }

    private func appID(for identity: AppIdentity) throws -> Int64 {
        if let id = appIDs[identity.key] { return id }
        try db.statement("INSERT INTO apps (key, name, kind, bundle_id) VALUES (?, ?, ?, ?) ON CONFLICT(key) DO UPDATE SET name = excluded.name")
            .bind(identity.key.rawValue, identity.name, Int(identity.kind.rawValue), identity.bundleID).run()
        var id: Int64 = 0
        try db.statement("SELECT id FROM apps WHERE key = ?").bind(identity.key.rawValue).rows { id = $0.int(0) }
        appIDs[identity.key] = id
        return id
    }

    // MARK: Pruning

    /// Rolls app minutes older than a day into hours, deletes what's past
    /// retention, and trims harder if the file outgrows its cap.
    public func prune(now: Date = Date()) throws {
        let t = Int64(now.timeIntervalSince1970)
        let appCutoff = t - Int64(limits.appMinuteRetention)
        try db.transaction {
            try db.statement("""
            INSERT INTO hour_app SELECT (ts / 3600) * 3600, app, sum(cpu_j), sum(gpu_j), sum(ane_j)
            FROM minute_app WHERE ts < ? GROUP BY ts / 3600, app
            ON CONFLICT(ts, app) DO UPDATE SET cpu_j = cpu_j + excluded.cpu_j, gpu_j = gpu_j + excluded.gpu_j, ane_j = ane_j + excluded.ane_j
            """).bind(appCutoff).run()
            try db.statement("DELETE FROM minute_app WHERE ts < ?").bind(appCutoff).run()
            try db.statement("DELETE FROM minute_process WHERE ts < ?").bind(appCutoff).run()
            try db.statement("DELETE FROM live WHERE ts < ?").bind(t - Int64(limits.liveRetention)).run()
            try db.statement("DELETE FROM minute WHERE ts < ?").bind(t - Int64(limits.minuteRetention)).run()
            try db.statement("DELETE FROM minute_component WHERE ts < ?").bind(t - Int64(limits.minuteRetention)).run()
            try db.statement("DELETE FROM hour_app WHERE ts < ?").bind(t - Int64(limits.hourRetention)).run()
        }
        if sizeBytes > limits.maxBytes {
            // Process detail is the bulk of the file; it goes first.
            try db.statement("DELETE FROM minute_process WHERE ts < ?").bind(t - Int64(limits.appMinuteRetention / 4)).run()
            try db.execute("PRAGMA incremental_vacuum")
        }
        try db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    public var sizeBytes: Int64 {
        let paths = [url.path, url.path + "-wal"]
        return paths.reduce(0) { total, path in
            total + ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    // MARK: Queries

    /// Everything recorded since `start`, stored and buffered, as one ledger.
    public func ledger(since start: Date, now: Date = Date()) throws -> EnergyLedger {
        var ledger = EnergyLedger()
        let from = Self.minute(of: start)

        try db.statement("""
        SELECT sum(seconds), sum(battery_seconds), sum(sensor_j), sum(sensor_seconds), max(sensor_src),
               sum(telemetry_j), sum(telemetry_seconds), sum(unclaimed_j)
        FROM minute WHERE ts >= ?
        """).bind(from).rows { row in
            guard !row.isNull(0) else { return }
            ledger.addStoredTotals(durationSeconds: row.double(0), onBatterySeconds: row.double(1),
                                   sensorJoules: row.double(2), sensorSeconds: row.double(3),
                                   sensorSource: row.isNull(4) ? nil : TotalSource(rawValue: UInt8(row.int(4))),
                                   telemetryJoules: row.double(5), telemetrySeconds: row.double(6),
                                   unclaimedJoules: row.double(7))
        }
        try db.statement("SELECT component, sum(joules), max(provenance) FROM minute_component WHERE ts >= ? GROUP BY component")
            .bind(from).rows { row in
                guard let id = row.string(0) else { return }
                ledger.addComponent(ComponentID(id), joules: row.double(1), provenance: Provenance(rawValue: UInt8(row.int(2))) ?? .estimated)
            }

        // Apps: minutes for the last day, hours before that.
        let appCutoff = Self.minute(of: now.addingTimeInterval(-limits.appMinuteRetention))
        var identities: [Int64: AppIdentity] = [:]
        try db.statement("SELECT id, key, name, kind, bundle_id FROM apps").rows { row in
            guard let key = row.string(1) else { return }
            identities[row.int(0)] = AppIdentity(key: AppKey(rawValue: key), name: row.string(2) ?? key,
                                                 kind: AppKind(rawValue: UInt8(row.int(3))) ?? .other, bundleID: row.string(4))
        }
        var processes: [Int64: [String: Double]] = [:]
        try db.statement("SELECT app, name, sum(cpu_j) FROM minute_process WHERE ts >= ? GROUP BY app, name")
            .bind(from).rows { row in
                if let name = row.string(1) { processes[row.int(0), default: [:]][name] = row.double(2) }
            }
        let appSQL = """
        SELECT app, sum(cpu_j), sum(gpu_j), sum(ane_j) FROM (
            SELECT app, cpu_j, gpu_j, ane_j FROM minute_app WHERE ts >= ?
            UNION ALL
            SELECT app, cpu_j, gpu_j, ane_j FROM hour_app WHERE ts >= ? AND ts < ?
        ) GROUP BY app
        """
        try db.statement(appSQL).bind(from, (from / 3600) * 3600, appCutoff).rows { row in
            guard let identity = identities[row.int(0)] else { return }
            ledger.addStoredApp(identity, cpuJoules: row.double(1), gpuJoules: row.double(2), aneJoules: row.double(3),
                                processes: processes[row.int(0)] ?? [:])
        }

        for (minute, pending) in pendingMinutes where minute >= from { ledger.merge(pending) }
        return ledger
    }

    /// Live total watts since `start`, oldest first, stored and buffered.
    public func liveSeries(since start: Date) throws -> [(date: Date, watts: Double)] {
        var series: [(Date, Double)] = []
        try db.statement("SELECT ts, watts FROM live WHERE ts >= ? AND watts IS NOT NULL ORDER BY ts")
            .bind(Int64(start.timeIntervalSince1970)).rows { row in
                series.append((Date(timeIntervalSince1970: Double(row.int(0))), row.double(1)))
            }
        for reading in pendingLive where reading.date >= start {
            if let watts = reading.systemWatts { series.append((reading.date, watts)) }
        }
        return series
    }

    /// Average watts per minute for one component since `start`.
    public func componentSeries(_ id: ComponentID, since start: Date) throws -> [(date: Date, watts: Double)] {
        var series: [(Date, Double)] = []
        try db.statement("""
        SELECT c.ts, c.joules / m.seconds FROM minute_component c JOIN minute m ON m.ts = c.ts
        WHERE c.component = ? AND c.ts >= ? AND m.seconds > 0 ORDER BY c.ts
        """).bind(id.rawValue, Self.minute(of: start)).rows { row in
            series.append((Date(timeIntervalSince1970: Double(row.int(0))), row.double(1)))
        }
        for (minute, pending) in pendingMinutes.sorted(by: { $0.key < $1.key }) where minute >= Self.minute(of: start) {
            if let total = pending.components[id], pending.durationSeconds > 0 {
                series.append((Date(timeIntervalSince1970: Double(minute)), total.joules / pending.durationSeconds))
            }
        }
        return series
    }

    static func minute(of date: Date) -> Int64 { Int64(date.timeIntervalSince1970 / 60) * 60 }

    /// The start of `date`'s day in the current time zone, as Unix seconds.
    static func day(of date: Date) -> Int64 { Int64(Calendar.current.startOfDay(for: date).timeIntervalSince1970) }
}

