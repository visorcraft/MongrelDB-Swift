import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Errors

/// The base error type for every failure raised by the MongrelDB client.
///
/// Every non-2xx response from the daemon is mapped to a typed subclass. Catch
/// `MongrelDBError` to handle any client-side failure, or catch one of the
/// specific subclasses:
///
/// - ``AuthError`` - HTTP 401/403 (bad or missing credentials)
/// - ``NotFoundError`` - HTTP 404 (missing table, schema, etc.)
/// - ``ConflictError`` - HTTP 409 (unique, foreign-key, check, or trigger
///   constraint violations)
/// - ``QueryError`` - HTTP 400 or 5xx, and any other request-level failure
///   (including transport failures, which carry an HTTP status of `-1`)
///
/// Each typed error carries the HTTP status code, the daemon's decoded error
/// envelope (`code`, `opIndex`), so callers can both branch on type and inspect
/// the response detail.
open class MongrelDBError: Error, CustomStringConvertible {
    /// The human-readable error message.
    public let message: String
    /// The HTTP status code returned by the daemon, or `-1` when unknown
    /// (e.g. a transport failure).
    public let status: Int
    /// The server's structured error code, when present
    /// (e.g. `UNIQUE_VIOLATION`, `FK_VIOLATION`).
    public let code: String?
    /// The offending operation index within a transaction, when the server
    /// reports one.
    public let opIndex: Int?
    /// The underlying error for transport failures, when applicable.
    public let cause: Error?

    public init(
        message: String,
        status: Int = -1,
        code: String? = nil,
        opIndex: Int? = nil,
        cause: Error? = nil
    ) {
        self.message = message
        self.status = status
        self.code = code
        self.opIndex = opIndex
        self.cause = cause
    }

    public var description: String {
        var s = "MongrelDBError: \(message)"
        if status >= 0 { s += " (status \(status))" }
        if let code { s += " [\(code)]" }
        if let opIndex { s += " op=\(opIndex)" }
        return s
    }
}

/// Raised for HTTP 401 or 403 responses - bad or missing credentials.
public final class AuthError: MongrelDBError {}

/// Raised for HTTP 404 responses - a missing table, schema, or other resource.
public final class NotFoundError: MongrelDBError {}

/// Raised for HTTP 409 responses - a unique, foreign-key, check, or trigger
/// constraint violation.
///
/// During a transaction commit, the engine enforces all constraints at commit
/// time. On any violation every staged operation rolls back and this error is
/// thrown carrying the server's structured ``code`` (e.g. `UNIQUE_VIOLATION`,
/// `FK_VIOLATION`) and the offending ``opIndex`` within the batch.
public final class ConflictError: MongrelDBError {}

/// Raised for HTTP 400 or 5xx responses, and for any other request-level
/// failure not covered by ``AuthError``, ``NotFoundError``, or
/// ``ConflictError``.
///
/// This is the catch-all for malformed queries, server-side errors, and
/// transport failures (the latter carries the underlying ``cause`` and an HTTP
/// status of `-1`).
public final class QueryError: MongrelDBError {
    /// Creates an error carrying the daemon's HTTP response detail.
    override public init(
        message: String,
        status: Int,
        code: String? = nil,
        opIndex: Int? = nil,
        cause: Error? = nil
    ) {
        super.init(message: message, status: status, code: code, opIndex: opIndex, cause: cause)
    }

    /// Creates a transport/decode error with no HTTP detail.
    public init(_ message: String, cause: Error? = nil) {
        super.init(message: message, cause: cause)
    }
}

// MARK: - JSON

/// A tiny JSON helper namespace built on `Foundation.JSONSerialization`.
///
/// The daemon's API is dynamic JSON (objects, arrays, numbers, strings, bools,
/// null), so values flow through the client as `[String: Any]` / `[Any]` /
/// `Any` - the exact shape the other MongrelDB clients (PHP/Go/Java/Ruby) use.
public enum JSON {
    /// A JSON `null` for use in `[String: Any]` / `[Any]` payloads. Swift's
    /// `nil` cannot be stored in an `Any` slot, so pass `JSON.null` to write a
    /// JSON null.
    public static let null: Any = NSNull()

    /// Encodes a JSON-compatible value to UTF-8 `Data`.
    static func encode(_ value: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(value) else {
            throw QueryError("mongreldb: cannot encode value to JSON")
        }
        return try JSONSerialization.data(withJSONObject: value, options: [])
    }

    /// Decodes JSON `Data` into `Any` (dictionary / array / string / number /
    /// bool / null). Allows bare JSON fragments.
    static func decode(_ data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data, options: .allowFragments)
    }
}

// MARK: - MongrelDBClient

/// The MongrelDB HTTP client.
///
/// A pure-Swift client for a running `mongreldb-server` daemon, built on the
/// standard library `URLSession` (Swift 5.9+). No external dependencies. The
/// API mirrors the MongrelDB PHP, Go, Java, and Ruby clients: typed CRUD, a
/// fluent query builder that pushes conditions down to the engine's native
/// indexes, idempotent batch transactions, full SQL access, and schema
/// introspection.
///
/// Connect with a base URL:
///
/// ```swift
/// let db = MongrelDBClient(baseURL: "http://127.0.0.1:8453")
/// let ok = await db.health()
/// ```
///
/// A `MongrelDBClient` is safe for concurrent use from multiple tasks once
/// constructed: `URLSession` is thread-safe and the instance is immutable after
/// initialization.
public final class MongrelDBClient {
    /// The daemon address used when none is supplied.
    public static let defaultBaseURL = "http://127.0.0.1:8453"

    /// The default per-request timeout, in seconds.
    public static let defaultTimeout: TimeInterval = 30

    /// The maximum response body size (256 MB). Bodies larger than this are
    /// aborted with a ``QueryError`` to guard client memory against a malicious
    /// or buggy server.
    public static let maxResponseBytes = 268_435_456

    /// The daemon base URL this client was configured with.
    public let baseURL: String
    /// The Bearer token, when configured.
    public let token: String?
    /// The Basic-auth username, when configured.
    public let username: String?
    /// The Basic-auth password, when configured.
    public let password: String?
    /// The underlying URL session.
    public let session: URLSession
    /// The per-request timeout, in seconds.
    public let timeout: TimeInterval

    /// Creates a client for the daemon at `baseURL` with optional
    /// authentication.
    ///
    /// A non-nil `token` authenticates requests with a `Bearer` header
    /// (`--auth-token` mode) and takes precedence over basic-auth credentials.
    /// When `token` is `nil`, a non-nil `username` enables HTTP Basic auth
    /// (`--auth-users` mode); the password may be `nil`.
    ///
    /// - Parameters:
    ///   - baseURL: the daemon base URL, or `nil` for ``defaultBaseURL``
    ///   - token: a Bearer token, or `nil`
    ///   - username: the Basic-auth username, or `nil`
    ///   - password: the Basic-auth password, or `nil`
    ///   - session: a custom `URLSession`, or `nil` to use the shared session
    ///   - timeout: the per-request timeout in seconds
    public init(
        baseURL: String? = nil,
        token: String? = nil,
        username: String? = nil,
        password: String? = nil,
        session: URLSession? = nil,
        timeout: TimeInterval = MongrelDBClient.defaultTimeout
    ) {
        var base = baseURL ?? MongrelDBClient.defaultBaseURL
        while base.hasSuffix("/") {
            base.removeLast()
        }
        self.baseURL = base
        self.token = token
        self.username = username
        self.password = password
        self.session = session ?? .shared
        self.timeout = timeout
    }

    // MARK: Health & tables

    /// Reports whether the daemon is reachable and healthy.
    ///
    /// - Returns: `true` if the daemon answered `/health` with a 2xx response;
    ///   `false` (rather than throwing) on any failure.
    public func health() async -> Bool {
        do {
            _ = try await get("/health")
            return true
        } catch {
            return false
        }
    }

    public func historyRetentionEpochs() async throws -> UInt64 {
        let value = try await historyRetention("GET", nil)["history_retention_epochs"]
        return (value as? NSNumber)?.uint64Value ?? 0
    }

    public func earliestRetainedEpoch() async throws -> UInt64 {
        let value = try await historyRetention("GET", nil)["earliest_retained_epoch"]
        return (value as? NSNumber)?.uint64Value ?? 0
    }

    public func setHistoryRetentionEpochs(_ epochs: UInt64) async throws -> [String: Any] {
        try await historyRetention("PUT", ["history_retention_epochs": epochs])
    }

    private func historyRetention(_ method: String, _ payload: Any?) async throws -> [String: Any] {
        let data = try await send(method, "/history/retention", body: payload)
        return try JSON.decode(data) as? [String: Any] ?? [:]
    }

    /// Lists all table names in the database.
    public func tableNames() async throws -> [String] {
        let body = try await get("/tables")
        if body.isEmpty { return [] }
        let parsed = try JSON.decode(body)
        if let arr = parsed as? [Any] {
            return arr.map { ($0 as? String) ?? String(describing: $0) }
        }
        throw QueryError("mongreldb: unexpected table-list response")
    }

    /// Creates a table named `name` with the given columns and returns the
    /// assigned table id.
    ///
    /// Each column is a `[String: Any]` dictionary sent verbatim to the daemon.
    /// Recognized keys include `id`, `name`, `ty`, `primary_key`, `nullable`,
    /// `enum_variants`, and `default_value`; table checks go in `constraints`.
    /// - Returns: the assigned table id, or `0` if the daemon did not return one.
    @discardableResult
    public func createTable(
        _ name: String,
        columns: [[String: Any]],
        constraints: [String: Any]? = nil
    ) async throws -> Int {
        var payload: [String: Any] = ["name": name, "columns": columns]
        if let constraints { payload["constraints"] = constraints }
        let body = try await post("/kit/create_table", payload)
        if body.isEmpty { return 0 }
        let parsed = try JSON.decode(body)
        if let obj = parsed as? [String: Any] {
            return Self.asInt(obj["table_id"]) ?? 0
        }
        return 0
    }

    /// Drops a table by name.
    public func dropTable(_ name: String) async throws {
        _ = try await delete("/tables/" + Self.pathEscape(name))
    }

    /// Returns the row count for a table.
    public func count(_ table: String) async throws -> Int {
        let body = try await get("/tables/" + Self.pathEscape(table) + "/count")
        if body.isEmpty { return 0 }
        let parsed = try JSON.decode(body)
        if let obj = parsed as? [String: Any] {
            return Self.asInt(obj["count"]) ?? 0
        }
        return 0
    }

    // MARK: CRUD (via the Kit typed transaction endpoint)

    /// Inserts a row. `idempotencyKey`, when non-nil and non-empty, makes the
    /// commit safe to retry - the daemon returns the original result on
    /// duplicate commits.
    ///
    /// - Parameters:
    ///   - table: the target table
    ///   - cells: a column-id-to-value map (flattened to the server's
    ///     `[col_id, value, ...]` array before sending)
    ///   - idempotencyKey: an idempotency key, or `nil`
    /// - Returns: the per-operation result object (the first element of the
    ///   server's results array), or an empty dictionary if none.
    @discardableResult
    public func put(
        _ table: String,
        cells: [Int: Any],
        idempotencyKey: String? = nil
    ) async throws -> [String: Any] {
        let op: [String: Any] = ["put": ["table": table, "cells": Self.flattenCells(cells)]]
        let results = try await commitOne([op], idempotencyKey: idempotencyKey)
        return results.first ?? [:]
    }

    /// Inserts a row, or updates it on a primary-key conflict.
    /// `updateCells`, when non-nil, supplies the values written on conflict;
    /// `nil` means DO NOTHING.
    @discardableResult
    public func upsert(
        _ table: String,
        cells: [Int: Any],
        updateCells: [Int: Any]? = nil,
        idempotencyKey: String? = nil
    ) async throws -> [String: Any] {
        var upsert: [String: Any] = [
            "table": table,
            "cells": Self.flattenCells(cells),
        ]
        if let updateCells {
            upsert["update_cells"] = Self.flattenCells(updateCells)
        }
        let op: [String: Any] = ["upsert": upsert]
        let results = try await commitOne([op], idempotencyKey: idempotencyKey)
        return results.first ?? [:]
    }

    /// Removes a row by its internal row id.
    public func delete(_ table: String, rowId: Int) async throws {
        let op: [String: Any] = ["delete": ["table": table, "row_id": rowId]]
        _ = try await commitOne([op], idempotencyKey: nil)
    }

    /// Removes a row by its primary-key value.
    public func deleteByPk(_ table: String, pk: Any) async throws {
        let op: [String: Any] = ["delete_by_pk": ["table": table, "pk": pk]]
        _ = try await commitOne([op], idempotencyKey: nil)
    }

    /// Sends a single-op transaction and returns the results array.
    private func commitOne(
        _ ops: [[String: Any]],
        idempotencyKey: String?
    ) async throws -> [[String: Any]] {
        var payload: [String: Any] = ["ops": ops]
        if let key = idempotencyKey, !key.isEmpty {
            payload["idempotency_key"] = key
        }
        let body = try await post("/kit/txn", payload)
        return try Self.decodeResults(body)
    }

    // MARK: Query

    /// Starts a fluent ``QueryBuilder`` against `table`.
    public func query(_ table: String) -> QueryBuilder {
        QueryBuilder(client: self, table: table)
    }

    // MARK: SQL

    /// Executes a SQL statement via the `/sql` endpoint, requesting JSON output.
    ///
    /// The server returns a JSON array of row objects keyed by column name, e.g.
    /// `[["id": 1, "name": "Alice", "score": 95.5]]`. For statements that yield
    /// no rows (DDL/DML), it returns an empty list.
    public func sql(_ sql: String) async throws -> [[String: Any]] {
        let body = try await post("/sql", ["sql": sql, "format": "json"])
        let trimmed = Self.trimWhitespace(body)
        if trimmed.isEmpty { return [] }
        // Requested format is JSON; decode the array of row objects. An old
        // server may ignore the requested JSON format and answer with Arrow IPC
        // binary bytes (which are not valid JSON). Treat that as "no rows"
        // rather than throwing, so callers keep working against legacy servers.
        guard let parsed = try? JSON.decode(body) else { return [] }
        if let arr = parsed as? [Any] {
            var rows: [[String: Any]] = []
            for row in arr {
                if let m = row as? [String: Any] {
                    rows.append(m)
                } else {
                    rows.append([:])
                }
            }
            return rows
        }
        // A single JSON object (e.g. an error envelope) is not a row set.
        return []
    }

    // MARK: Schema

    /// Returns the full schema catalog: a table-name-to-descriptor map.
    public func schema() async throws -> [String: [String: Any]] {
        let body = try await get("/kit/schema")
        var out: [String: [String: Any]] = [:]
        if body.isEmpty { return out }
        let parsed = try JSON.decode(body)
        if let obj = parsed as? [String: Any], let tables = obj["tables"] as? [String: Any] {
            for (name, desc) in tables {
                if let m = desc as? [String: Any] {
                    out[name] = m
                }
            }
        }
        return out
    }

    /// Returns the descriptor for a single table.
    public func schemaFor(_ table: String) async throws -> [String: Any] {
        let body = try await get("/kit/schema/" + Self.pathEscape(table))
        if body.isEmpty { return [:] }
        let parsed = try JSON.decode(body)
        return (parsed as? [String: Any]) ?? [:]
    }

    // MARK: Maintenance

    /// Merges sorted runs across all tables (`POST /compact`).
    @discardableResult
    public func compact() async throws -> [String: Any] {
        try await postDecode("/compact")
    }

    /// Merges sorted runs for a single table (`POST /tables/{name}/compact`).
    @discardableResult
    public func compactTable(_ table: String) async throws -> [String: Any] {
        try await postDecode("/tables/" + Self.pathEscape(table) + "/compact")
    }

    /// POSTs an empty body and decodes the JSON object response.
    private func postDecode(_ path: String) async throws -> [String: Any] {
        let body = try await post(path, nil)
        if body.isEmpty { return [:] }
        let parsed = try JSON.decode(body)
        return (parsed as? [String: Any]) ?? [:]
    }

    // MARK: Transactions

    /// Starts a new batch transaction. Operations staged on the returned
    /// ``Transaction`` are committed atomically in a single `/kit/txn` request.
    public func beginTransaction() -> Transaction {
        Transaction(client: self)
    }

    /// Sends a batch of staged operations atomically. Exposed for the
    /// ``Transaction`` type; returns the per-operation results array.
    func commitTxn(
        _ ops: [[String: Any]],
        idempotencyKey: String?
    ) async throws -> [[String: Any]] {
        if ops.isEmpty { return [] }
        var payload: [String: Any] = ["ops": ops]
        if let key = idempotencyKey, !key.isEmpty {
            payload["idempotency_key"] = key
        }
        let body = try await post("/kit/txn", payload)
        return try Self.decodeResults(body)
    }

    // MARK: HTTP plumbing

    func get(_ path: String) async throws -> Data {
        try await send("GET", path, body: nil)
    }

    func post(_ path: String, _ body: Any?) async throws -> Data {
        try await send("POST", path, body: body)
    }

    func delete(_ path: String) async throws -> Data {
        try await send("DELETE", path, body: nil)
    }

    /// Builds and runs one request. The server's JSON extractors require an
    /// explicit `Content-Type: application/json` header on any request carrying
    /// a JSON body, so one is added whenever the body is non-nil. Non-2xx
    /// responses are mapped to typed client errors via ``toError(status:data:)``.
    private func send(_ method: String, _ path: String, body: Any?) async throws -> Data {
        let urlStr = baseURL + "/" + Self.stripLeadingSlash(path)
        guard let url = URL(string: urlStr) else {
            throw QueryError("mongreldb: invalid URL \(urlStr)")
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body {
            let payload = try JSON.encode(body)
            req.httpBody = payload
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        if let token, !token.isEmpty {
            req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        } else if let username, !username.isEmpty {
            let creds = "\(username):\(password ?? "")"
            let encoded = (creds.data(using: .utf8) ?? Data()).base64EncodedString()
            req.setValue("Basic " + encoded, forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            // URLSession's async data(for:) is unavailable on Linux
            // (FoundationNetworking), so drive the completion-handler-based
            // dataTask API through a continuation instead.
            (data, response) = try await withCheckedThrowingContinuation { cont in
                let task = session.dataTask(with: req) { data, response, error in
                    if let error {
                        cont.resume(throwing: error)
                    } else if let response {
                        cont.resume(returning: (data ?? Data(), response))
                    } else {
                        cont.resume(throwing: QueryError("mongreldb: empty response from server"))
                    }
                }
                task.resume()
            }
        } catch {
            throw QueryError(
                "mongreldb: request \(method) \(path) failed: \(error.localizedDescription)",
                cause: error
            )
        }
        guard let http = response as? HTTPURLResponse else {
            throw QueryError("mongreldb: non-HTTP response")
        }
        if data.count > MongrelDBClient.maxResponseBytes {
            throw QueryError(
                "mongreldb: response body exceeds maximum size of \(MongrelDBClient.maxResponseBytes) bytes"
            )
        }
        if !(200..<300).contains(http.statusCode) {
            throw Self.toError(status: http.statusCode, data: data)
        }
        return data
    }

    // MARK: Helpers

    /// Flattens a column-id-to-value map to the server's flat
    /// `[col_id, value, col_id, value, ...]` array. Pair order is not
    /// significant - each value is preceded by its own column id.
    static func flattenCells(_ cells: [Int: Any]) -> [Any] {
        var flat: [Any] = []
        flat.reserveCapacity(cells.count * 2)
        for (id, val) in cells {
            flat.append(id)
            flat.append(val)
        }
        return flat
    }

    /// Pulls the `results` array out of a `/kit/txn` response.
    static func decodeResults(_ body: Data) throws -> [[String: Any]] {
        if Self.trimWhitespace(body).isEmpty { return [] }
        let parsed = try JSON.decode(body)
        guard let obj = parsed as? [String: Any] else {
            throw QueryError("mongreldb: decode txn response: unexpected JSON")
        }
        var out: [[String: Any]] = []
        if let results = obj["results"] as? [Any] {
            for r in results {
                if let m = r as? [String: Any] {
                    out.append(m)
                } else {
                    out.append([:])
                }
            }
        }
        return out
    }

    /// Maps an HTTP status code and response body to a typed error. It
    /// best-effort decodes the server's JSON error envelope
    /// (`{error:{message,code,op_index}}`) and falls back to the raw body.
    static func toError(status: Int, data: Data) -> MongrelDBError {
        var message: String? = nil
        var code: String? = nil
        var opIndex: Int? = nil

        let trimmed = trimWhitespace(data)
        if !trimmed.isEmpty, trimmed[trimmed.startIndex] == 0x7B { // '{'
            if let parsed = try? JSON.decode(data), let obj = parsed as? [String: Any] {
                // Prefer the nested {"error": {...}} envelope.
                if let err = obj["error"] as? [String: Any] {
                    message = err["message"].flatMap { $0 as? String }
                        ?? err["message"].map { String(describing: $0) }
                    code = err["code"] as? String
                    opIndex = asInt(err["op_index"])
                }
                // Fall back to a flat {"message": ..., "code": ...} object.
                if message == nil && code == nil && opIndex == nil {
                    message = obj["message"] as? String
                    code = obj["code"] as? String
                }
            }
        }
        if (message == nil || message!.isEmpty) && !data.isEmpty {
            message = String(data: data, encoding: .utf8)
        }
        if message == nil || message!.isEmpty {
            switch status {
            case 401, 403: message = "authentication failed (\(status))"
            case 404: message = "resource not found"
            case 409: message = "constraint violation"
            default: message = "server error (\(status))"
            }
        }
        let msg = message!

        if msg.lowercased().hasPrefix("not found:") {
            return NotFoundError(message: msg, status: 404, code: code, opIndex: opIndex)
        }

        switch status {
        case 401, 403:
            return AuthError(message: msg, status: status, code: code, opIndex: opIndex)
        case 404:
            return NotFoundError(message: msg, status: status, code: code, opIndex: opIndex)
        case 409:
            return ConflictError(message: msg, status: status, code: code, opIndex: opIndex)
        default:
            return QueryError(message: msg, status: status, code: code, opIndex: opIndex)
        }
    }

    /// Coerces a JSON-decoded number into an `Int` across Apple and
    /// corelibs Foundation (which surface numbers as `NSNumber`, `Int`, or
    /// `Double` depending on platform).
    static func asInt(_ v: Any?) -> Int? {
        switch v {
        case let n as NSNumber: return n.intValue
        case let i as Int: return i
        case let d as Double: return Int(d)
        case let s as String: return Int(s)
        default: return nil
        }
    }

    /// Percent-encodes a path segment so table names containing '/', '?', '#',
    /// or spaces cannot inject extra segments or break routing. Only RFC 3986
    /// unreserved characters pass through unescaped.
    static func pathEscape(_ seg: String) -> String {
        seg.addingPercentEncoding(withAllowedCharacters: MongrelDBClient.pathAllowed) ?? seg
    }

    private static let pathAllowed: CharacterSet = {
        var cs = CharacterSet()
        // RFC 3986 unreserved characters only - '/' is NOT included so a
        // table name cannot inject an extra path segment.
        cs.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        return cs
    }()

    private static func stripLeadingSlash(_ s: String) -> String {
        var s = s
        while s.hasPrefix("/") { s.removeFirst() }
        return s
    }

    /// Returns a copy of `data` with leading/trailing ASCII whitespace removed.
    static func trimWhitespace(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }
        var start = data.startIndex
        var end = data.endIndex
        while start < end, data[start] <= 0x20 { start += 1 }
        while end > start, data[end - 1] <= 0x20 { end -= 1 }
        return start == data.startIndex && end == data.endIndex ? data : data[start..<end]
    }
}
