import XCTest
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import MongrelDB

/// Live integration tests for the MongrelDB Swift client.
///
/// These tests boot a real `mongreldb-server` daemon and exercise the full
/// client surface against it. They resolve the daemon binary in this order:
/// 1. the `MONGRELDB_SERVER` env var (path to the server binary)
/// 2. a prebuilt binary at `./bin/mongreldb-server`
/// 3. `mongreldb-server` on `PATH`
///
/// If no binary is available, the suite is skipped. Set `MONGRELDB_URL` to
/// point at an already-running daemon to skip the boot and connect directly.
final class MongrelDBLiveTests: XCTestCase {
    /// Shared daemon state (XCTest gives each test a fresh instance, so the
    /// booted daemon is held in statics and bootstrapped on first use).
    private static var sharedDB: MongrelDBClient?
    private static var sharedProcess: Process?
    private static var sharedDataDir: URL?
    private static var bootError: String?
    private static var didAttemptBoot = false

    // MARK: - Tests (alphabetical order; testZStopDaemon runs last)

    func testCreateTableAndCount() async throws {
        let db = try await requireDaemon()
        let name = Self.uniqueTable("swift_tbl")
        try await freshTable(db, name, columns: [Self.intCol(1, "id", primaryKey: true), Self.floatCol(2, "amount")])
        let n = try await db.count(name)
        XCTAssertEqual(n, 0, "expected 0 rows")
    }

    func testDeleteByPK() async throws {
        let db = try await requireDaemon()
        let name = Self.uniqueTable("swift_del")
        try await freshTable(db, name, columns: [Self.intCol(1, "id", primaryKey: true)])

        _ = try await db.put(name, cells: [1: 5])
        let countAfterPut = try await db.count(name)
        XCTAssertEqual(countAfterPut, 1)

        try await db.deleteByPk(name, pk: 5)
        let countAfterDelete = try await db.count(name)
        XCTAssertEqual(countAfterDelete, 0, "expected 0 rows after delete")
    }

    func testDropTable() async throws {
        let db = try await requireDaemon()
        let name = Self.uniqueTable("swift_drop")
        try await freshTable(db, name, columns: [Self.intCol(1, "id", primaryKey: true)])
        let namesBeforeDrop = try await db.tableNames()
        XCTAssertTrue(namesBeforeDrop.contains(name), "table should exist before drop")

        try await db.dropTable(name)
        let namesAfterDrop = try await db.tableNames()
        XCTAssertFalse(namesAfterDrop.contains(name), "table should be gone after drop")
    }

    func testErrorOnNonexistentTable() async throws {
        let db = try await requireDaemon()
        let name = Self.uniqueTable("swift_missing")
        do {
            _ = try await db.schemaFor(name)
            XCTFail("expected NotFoundError for nonexistent table")
        } catch let e as NotFoundError {
            XCTAssertEqual(e.status, 404, "expected status 404")
        }
    }

    func testErrorTypeCarriesStatus() async throws {
        let db = try await requireDaemon()
        let name = Self.uniqueTable("swift_missing2")
        do {
            _ = try await db.schemaFor(name)
            XCTFail("expected an error")
        } catch let e as MongrelDBError {
            XCTAssertEqual(e.status, 404, "expected status 404")
            XCTAssertTrue(e is NotFoundError, "expected NotFoundError, got \(type(of: e))")
        }
    }

    func testHealth() async throws {
        let db = try await requireDaemon()
        let ok = await db.health()
        XCTAssertTrue(ok, "expected healthy daemon")
    }

    func testIdempotentPut() async throws {
        let db = try await requireDaemon()
        let name = Self.uniqueTable("swift_idem")
        try await freshTable(db, name, columns: [Self.intCol(1, "id", primaryKey: true)])

        let key = "idem-\(name)"
        _ = try await db.put(name, cells: [1: 7], idempotencyKey: key)
        _ = try await db.put(name, cells: [1: 7], idempotencyKey: key)
        // The daemon returns the original response on duplicate commits. The
        // row count must remain 1 either way.
        let countAfterIdempotentPut = try await db.count(name)
        XCTAssertEqual(countAfterIdempotentPut, 1, "idempotent put should not duplicate the row")
    }

    func testPutAndCountRoundTrip() async throws {
        let db = try await requireDaemon()
        let name = Self.uniqueTable("swift_put")
        try await freshTable(db, name, columns: [Self.intCol(1, "id", primaryKey: true), Self.floatCol(2, "amount")])

        _ = try await db.put(name, cells: [1: 1, 2: 99.5])
        _ = try await db.put(name, cells: [1: 2, 2: 150.0])

        let n = try await db.count(name)
        XCTAssertEqual(n, 2, "expected 2 rows")
    }

    func testQueryByPK() async throws {
        let db = try await requireDaemon()
        let name = Self.uniqueTable("swift_pk")
        try await freshTable(db, name, columns: [Self.intCol(1, "id", primaryKey: true)])

        _ = try await db.put(name, cells: [1: 42])
        _ = try await db.put(name, cells: [1: 43])

        let rows = try await db.query(name).`where`("pk", params: ["value": 42]).execute()
        XCTAssertEqual(rows.count, 1, "expected exactly 1 row")
        // The returned row must carry the queried PK value.
        XCTAssertEqual(Self.cellInt(rows[0], colId: 1), 42, "expected pk 42")
    }

    func testQueryRangeWithFriendlyAliases() async throws {
        let db = try await requireDaemon()
        let name = Self.uniqueTable("swift_range")
        try await freshTable(db, name, columns: [Self.intCol(1, "id", primaryKey: true), Self.intCol(2, "amount", primaryKey: false)])

        _ = try await db.put(name, cells: [1: 1, 2: 50])
        _ = try await db.put(name, cells: [1: 2, 2: 120])
        _ = try await db.put(name, cells: [1: 3, 2: 200])

        // Range predicate using friendly aliases (column/min/max -> column_id/lo/hi).
        let builder = db.query(name).`where`("range", params: ["column": 2, "min": 100, "max": 150])
        let rows = try await builder.execute()
        // Only the row with amount=120 (pk=2) falls in [100, 150].
        XCTAssertEqual(rows.count, 1, "range query should return exactly the matching row")
        XCTAssertFalse(builder.truncated, "result should not be truncated")
        // Verify the PK and amount values of returned rows match the filter range.
        for row in rows {
            XCTAssertEqual(Self.cellInt(row, colId: 1), 2, "expected returned pk 2")
            let amt = Self.cellInt(row, colId: 2)
            XCTAssertGreaterThanOrEqual(amt, 100, "amount below range")
            XCTAssertLessThanOrEqual(amt, 150, "amount above range")
        }
    }

    func testSQLInsertIncreasesCountAndSelectReturnsRow() async throws {
        let db = try await requireDaemon()
        let name = Self.uniqueTable("swift_sql")
        try await freshTable(db, name, columns: [Self.intCol(1, "id", primaryKey: true), Self.intCol(2, "amount", primaryKey: false)])

        let countBefore = try await db.count(name)
        XCTAssertEqual(countBefore, 0, "expected 0 rows")
        // INSERT via SQL must increase the row count.
        _ = try await db.sql("INSERT INTO \(name) (id, amount) VALUES (10, 42)")
        let countAfter = try await db.count(name)
        XCTAssertEqual(countAfter, 1, "count must increase after INSERT")

        // JSON SQL mode must return the inserted row. An old server ignores the
        // requested JSON format and answers with Arrow IPC bytes, so sql()
        // returns [] - only verify row content when JSON mode worked.
        let rows = try await db.sql("SELECT id, amount FROM \(name)")
        if !rows.isEmpty {
            XCTAssertEqual(rows.count, 1, "expected 1 row from JSON SELECT")
            XCTAssertEqual(MongrelDBClient.asInt(rows[0]["id"]), 10, "expected id 10")
        }
    }

    func testSchemaForReturnsDescriptor() async throws {
        let db = try await requireDaemon()
        let name = Self.uniqueTable("swift_schema_for")
        try await freshTable(db, name, columns: [Self.intCol(1, "id", primaryKey: true), Self.floatCol(2, "amount")])

        let desc = try await db.schemaFor(name)
        XCTAssertNotNil(desc["schema_id"], "descriptor missing schema_id; got \(desc)")
        let cols = try XCTUnwrap(desc["columns"] as? [[String: Any]], "columns should be a list of objects")
        XCTAssertEqual(cols.count, 2, "expected 2 columns")
    }

    func testSchemaListsCreatedTable() async throws {
        let db = try await requireDaemon()
        let name = Self.uniqueTable("swift_schema")
        try await freshTable(db, name, columns: [Self.intCol(1, "id", primaryKey: true), Self.floatCol(2, "amount")])

        let schema = try await db.schema()
        XCTAssertNotNil(schema[name], "schema catalog missing table \(name)")
    }

    func testTableNamesListsCreatedTable() async throws {
        let db = try await requireDaemon()
        let name = Self.uniqueTable("swift_tables")
        try await freshTable(db, name, columns: [Self.intCol(1, "id", primaryKey: true)])

        let names = try await db.tableNames()
        XCTAssertTrue(names.contains(name), "table list \(names) missing \(name)")
    }

    func testTransactionPutCommit() async throws {
        let db = try await requireDaemon()
        let name = Self.uniqueTable("swift_txn")
        try await freshTable(db, name, columns: [Self.intCol(1, "id", primaryKey: true)])

        let txn = db.beginTransaction()
        txn.put(name, cells: [1: 1], returning: false)
        txn.put(name, cells: [1: 2], returning: false)
        txn.put(name, cells: [1: 3], returning: false)
        XCTAssertEqual(txn.count, 3, "expected 3 staged ops")

        let results = try await txn.commit()
        XCTAssertEqual(results.count, 3, "expected 3 results")
        let n = try await db.count(name)
        XCTAssertEqual(n, 3, "expected 3 rows after commit")
    }

    func testTransactionRollback() async throws {
        let db = try await requireDaemon()
        let name = Self.uniqueTable("swift_rb")
        try await freshTable(db, name, columns: [Self.intCol(1, "id", primaryKey: true)])

        let txn = db.beginTransaction()
        txn.put(name, cells: [1: 1], returning: false)
        XCTAssertEqual(txn.count, 1)
        txn.rollback()
        let n = try await db.count(name)
        XCTAssertEqual(n, 0, "rollback should leave the table empty")
    }

    func testUpsertOnConflict() async throws {
        let db = try await requireDaemon()
        let name = Self.uniqueTable("swift_upsert")
        try await freshTable(db, name, columns: [Self.intCol(1, "id", primaryKey: true), Self.intCol(2, "amount", primaryKey: false)])

        _ = try await db.put(name, cells: [1: 1, 2: 50])
        // Upsert the same PK with an update_cells that rewrites amount.
        _ = try await db.upsert(name, cells: [1: 1, 2: 50], updateCells: [2: 999])
        let countAfterUpsert = try await db.count(name)
        XCTAssertEqual(countAfterUpsert, 1, "upsert should not add a second row")

        let rows = try await db.query(name).`where`("pk", params: ["value": 1]).execute()
        XCTAssertEqual(rows.count, 1, "expected the upserted row")
        // Assert the PK and the updated cell value.
        XCTAssertEqual(Self.cellInt(rows[0], colId: 1), 1, "expected pk 1")
        XCTAssertEqual(Self.cellInt(rows[0], colId: 2), 999, "expected updated amount 999")
    }

    func testCompact() async throws {
        let db = try await requireDaemon()
        let name = Self.uniqueTable("swift_compact")
        try await freshTable(db, name, columns: [Self.intCol(1, "id", primaryKey: true)])
        _ = try await db.put(name, cells: [1: 1])

        // Both compaction endpoints should succeed without throwing.
        _ = try await db.compact()
        _ = try await db.compactTable(name)
    }

    func testHistoryRetentionRoundTrip() async throws {
        let db = try await requireDaemon()
        let defaultEpochs = try await db.historyRetentionEpochs()
        XCTAssertGreaterThan(defaultEpochs, 0, "expected a positive default retention window")
        let earliestEpoch = try await db.earliestRetainedEpoch()
        XCTAssertGreaterThan(earliestEpoch, 0, "expected a positive earliest retained epoch")

        try await Self.withRestoredRetention(db: db, temporaryEpochs: 1_000) {
            let updated = try await db.setHistoryRetentionEpochs(1_000)
            XCTAssertEqual(updated["history_retention_epochs"] as? Int, 1_000)
            let roundTripEpochs = try await db.historyRetentionEpochs()
            XCTAssertEqual(roundTripEpochs, 1_000)
        }
    }

    func testAsOfEpochTimeTravel() async throws {
        let db = try await requireDaemon()

        // The retention window must be wide enough for the historical read.
        try await Self.withRestoredRetention(db: db, temporaryEpochs: 10_000) {
            let name = Self.uniqueTable("swift_pit")
            try await freshTable(db, name, columns: [
                Self.intCol(1, "id", primaryKey: true),
                Self.floatCol(2, "amount"),
            ])

            _ = try await db.put(name, cells: [1: 1, 2: 1.0])
            let insertEpoch = try XCTUnwrap(db.lastEpoch, "put() did not capture a commit epoch")
            XCTAssertGreaterThan(insertEpoch, 0)

            // Mutate the row at a later epoch.
            _ = try await db.upsert(name, cells: [1: 1, 2: 9.0], updateCells: [2: 9.0])

            // The historical value at the insert epoch must still be readable.
            let historical = try await db.sql("SELECT id, amount FROM \(name) AS OF EPOCH \(insertEpoch)")
            XCTAssertEqual(historical.count, 1, "expected one historical row")
            XCTAssertEqual(historical[0]["id"] as? Int, 1)
            let historicalAmount = try XCTUnwrap(historical[0]["amount"] as? Double)
            XCTAssertEqual(historicalAmount, 1.0, accuracy: 0.0001)

            // The current value reflects the upsert.
            let current = try await db.sql("SELECT id, amount FROM \(name)")
            XCTAssertEqual(current.count, 1, "expected one current row")
            XCTAssertEqual(current[0]["id"] as? Int, 1)
            let currentAmount = try XCTUnwrap(current[0]["amount"] as? Double)
            XCTAssertEqual(currentAmount, 9.0, accuracy: 0.0001)
        }
    }

    // ── Offline tests (always run, no daemon needed) ───────────────────────

    /// A client constructed with no reachable server reports `health() == false`
    /// rather than throwing.
    func testHealthReturnsFalseWhenUnreachable() async {
        let unreachable = MongrelDBClient(baseURL: "http://127.0.0.1:1", timeout: 2)
        let ok = await unreachable.health()
        XCTAssertFalse(ok, "health should be false for an unreachable daemon")
    }

    /// A token-configured client against an unreachable host still reports
    /// `health() == false` - exercising the Bearer-auth header path without
    /// crashing.
    func testTokenConfiguredClientHealthIsFalseWhenUnreachable() async {
        let unreachable = MongrelDBClient(baseURL: "http://127.0.0.1:1", token: "super-secret", timeout: 2)
        let ok = await unreachable.health()
        XCTAssertFalse(ok, "health should be false for an unreachable daemon")
    }

    /// Final test (sorts last): stop the daemon if we booted one.
    func testZStopDaemon() async throws {
        Self.stopSharedDaemon()
    }

    // MARK: - Daemon bootstrap

    /// Returns the shared client, booting the daemon on first call. Skips the
    /// test when no daemon is available.
    private func requireDaemon() async throws -> MongrelDBClient {
        if let err = Self.bootError { throw XCTSkip(err) }
        if let db = Self.sharedDB { return db }
        Self.didAttemptBoot = true

        if let url = Self.env("MONGRELDB_URL").nilIfEmpty {
            let client = MongrelDBClient(baseURL: url, token: Self.env("MONGRELDB_TOKEN").nilIfEmpty)
            if await client.health() {
                Self.sharedDB = client
                return client
            }
            Self.bootError = "MONGRELDB_URL=\(url) is not reachable"
            throw XCTSkip(Self.bootError!)
        }

        guard let bin = Self.resolveServerBinary() else {
            Self.bootError = "No mongreldb-server binary available; live tests skipped"
            throw XCTSkip(Self.bootError!)
        }

        let port: Int
        do {
            port = try Self.freePort()
        } catch {
            Self.bootError = "could not allocate a free port: \(error)"
            throw XCTSkip(Self.bootError!)
        }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mongreldb-swift-test-\(UInt64.random(in: 0..<UInt64.max))",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            Self.bootError = "could not create data dir: \(error)"
            throw XCTSkip(Self.bootError!)
        }
        Self.sharedDataDir = dir

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = [dir.path, "--port", String(port)]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = outPipe
        do {
            try proc.run()
        } catch {
            Self.bootError = "could not start mongreldb-server: \(error)"
            throw XCTSkip(Self.bootError!)
        }
        Self.sharedProcess = proc

        let url = "http://127.0.0.1:\(port)"
        let probe = MongrelDBClient(baseURL: url)
        let healthy = await Self.waitForHealth(probe: probe, timeoutSeconds: 40)
        if !healthy {
            let log = Self.readPipeString(outPipe)
            Self.bootError = "mongreldb-server did not become healthy. Log:\n\(log)"
            Self.stopSharedDaemon()
            throw XCTSkip(Self.bootError!)
        }
        let client = MongrelDBClient(baseURL: url)
        Self.sharedDB = client
        return client
    }

    private static func stopSharedDaemon() {
        sharedProcess?.terminate()
        sharedProcess = nil
        if let dir = sharedDataDir {
            try? FileManager.default.removeItem(at: dir)
            sharedDataDir = nil
        }
        sharedDB = nil
    }

    // MARK: - Helpers

    private func freshTable(_ db: MongrelDBClient, _ name: String, columns: [[String: Any]]) async throws {
        // A missing table on drop is the expected pre-condition; ignore any
        // error here.
        do { try await db.dropTable(name) } catch {}
        _ = try await db.createTable(name, columns: columns)
    }

    private static func intCol(_ id: Int, _ name: String, primaryKey: Bool) -> [String: Any] {
        ["id": id, "name": name, "ty": "int64", "primary_key": primaryKey, "nullable": false]
    }

    /// Extracts an `Int` value for `colId` from a Kit row's flat `cells` array
    /// (shape: `[col_id, value, col_id, value, ...]`).
    private static func cellInt(_ row: [String: Any], colId: Int) -> Int {
        guard let cells = row["cells"] as? [Any] else {
            XCTFail("cell \(colId) not found: row has no cells array")
            return 0
        }
        var i = 0
        while i + 1 < cells.count {
            if MongrelDBClient.asInt(cells[i]) == colId {
                if let v = MongrelDBClient.asInt(cells[i + 1]) { return v }
                XCTFail("cell \(colId) value not an int: \(cells[i + 1])")
                return 0
            }
            i += 2
        }
        XCTFail("cell \(colId) not found in row")
        return 0
    }

    private static func floatCol(_ id: Int, _ name: String) -> [String: Any] {
        ["id": id, "name": name, "ty": "float64", "primary_key": false, "nullable": false]
    }

    /// Widens the history-retention window, runs `body`, then restores the
    /// original window even if `body` throws. Avoids leaking a non-default
    /// retention setting to later live tests.
    private static func withRestoredRetention(
        db: MongrelDBClient,
        temporaryEpochs: UInt64,
        body: () async throws -> Void
    ) async throws {
        let original = try await db.historyRetentionEpochs()
        try await db.setHistoryRetentionEpochs(temporaryEpochs)
        do {
            try await body()
        } catch {
            _ = try? await db.setHistoryRetentionEpochs(original)
            throw error
        }
        _ = try await db.setHistoryRetentionEpochs(original)
    }

    private static func uniqueTable(_ prefix: String) -> String {
        "\(prefix)_\(String(UInt64.random(in: 0..<UInt64.max), radix: 16))"
    }

    private static func env(_ name: String) -> String {
        ProcessInfo.processInfo.environment[name] ?? ""
    }

    /// Finds the daemon binary, or returns nil to skip the live suite.
    private static func resolveServerBinary() -> String? {
        let envPath = env("MONGRELDB_SERVER")
        if !envPath.isEmpty {
            if FileManager.default.isExecutableFile(atPath: envPath) {
                return (envPath as NSString).standardizingPath
            }
            return nil
        }
        let local = "bin/mongreldb-server"
        if FileManager.default.isExecutableFile(atPath: local) {
            return (local as NSString).standardizingPath
        }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") {
                let candidate = "\(dir)/mongreldb-server"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return (candidate as NSString).standardizingPath
                }
            }
        }
        return nil
    }

    /// Binds a TCP socket on port 0 to let the OS assign a free port, then
    /// closes it and returns the port (same TOCTOU trade-off as Java's
    /// `new ServerSocket(0)` / Go's `net.Listen`).
    private static func freePort() throws -> Int {
        let s = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard s >= 0 else { throw QueryError("mongreldb: socket() failed") }
        defer { close(s) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(s, sa, size)
            }
        }
        guard bound == 0 else { throw QueryError("mongreldb: bind() failed") }

        var resolved = sockaddr_in()
        var len = size
        let got = withUnsafeMutablePointer(to: &resolved) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(s, sa, &len)
            }
        }
        guard got == 0 else { throw QueryError("mongreldb: getsockname() failed") }
        return Int(UInt16(bigEndian: resolved.sin_port))
    }

    private static func waitForHealth(probe: MongrelDBClient, timeoutSeconds: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            if await probe.health() { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    private static func readPipeString(_ pipe: Pipe) -> String {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? "(non-utf8 log)"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
