import Foundation

/// Builds a request for the daemon's `/kit/query` endpoint, where conditions
/// push down to the engine's specialized indexes for sub-millisecond lookups.
///
/// Condition parameters accept friendly aliases that are translated to the
/// server's exact on-wire keys before sending (see ``where(_:params:)``):
///
/// | friendly alias      | on-wire key      |
/// |---------------------|------------------|
/// | `column`            | `column_id`      |
/// | `min` / `max`       | `lo` / `hi`      |
/// | `min_inclusive`     | `lo_inclusive`   |
/// | `max_inclusive`     | `hi_inclusive`   |
///
/// The server's canonical keys are accepted directly too.
///
/// Usage:
/// ```swift
/// let rows = try await db.query("orders")
///     .where("range", ["column": 3, "min": 100.0, "max": 150.0])
///     .projection([1, 2])
///     .limit(100)
///     .execute()
/// if builder.truncated {
///     // result set hit the limit; more matches exist on the server
/// }
/// ```
public final class QueryBuilder {
    private let client: MongrelDBClient
    private let table: String
    private var conditions: [[String: Any]] = []
    private var projection: [Int]? = nil
    private var limit: Int? = nil
    /// Whether the most recent ``execute()`` result was capped by `limit`.
    /// `false` until ``execute()`` has been called.
    public private(set) var truncated: Bool = false

    init(client: MongrelDBClient, table: String) {
        self.client = client
        self.table = table
    }

    /// Adds a native condition. Conditions are AND-ed together.
    ///
    /// Available condition types include:
    /// - `pk` - exact primary-key match (`["value": pk]`)
    /// - `bitmap_eq` - equality on a bitmap-indexed column
    /// - `bitmap_in` - IN predicate on a bitmap-indexed column
    /// - `range` - integer range predicate (lo/hi, inclusive)
    /// - `range_f64` - float range predicate (lo/hi + lo_inclusive/hi_inclusive)
    /// - `is_null` - null check
    /// - `is_not_null` - non-null check
    /// - `fm_contains` - full-text substring search (FM-index)
    /// - `fm_contains_all` - multiple substring patterns (all must match)
    /// - `ann` - dense vector similarity search (HNSW)
    /// - `sparse_match` - sparse vector match
    /// - `min_hash_similar` - MinHash similarity search
    ///
    /// - Parameters:
    ///   - condType: the condition type
    ///   - params: the condition parameters (friendly aliases accepted)
    /// - Returns: this builder, for chaining
    @discardableResult
    public func `where`(_ condType: String, params: [String: Any]) -> QueryBuilder {
        let normalized = Self.normalizeCondition(condType: condType, params: params)
        let entry: [String: Any] = [condType: normalized]
        conditions.append(entry)
        return self
    }

    /// Sets the column ids to return. `nil` (the default) means all columns.
    @discardableResult
    public func projection(_ columnIDs: [Int]?) -> QueryBuilder {
        self.projection = columnIDs
        return self
    }

    /// Caps the number of rows returned.
    @discardableResult
    public func limit(_ limit: Int) -> QueryBuilder {
        self.limit = limit
        return self
    }

    /// Builds the request payload that will be sent to `/kit/query`.
    public func build() -> [String: Any] {
        var payload: [String: Any] = ["table": table]
        if !conditions.isEmpty {
            // The daemon expects externally-tagged conditions:
            // [{type: {...}}, ...]
            payload["conditions"] = conditions
        }
        if let projection { payload["projection"] = projection }
        if let limit { payload["limit"] = limit }
        return payload
    }

    /// Runs the query and returns the matching rows. Also records whether the
    /// result was truncated by `limit`; check it with ``truncated``.
    public func execute() async throws -> [[String: Any]] {
        let body = try await client.post("/kit/query", build())
        var rows: [[String: Any]] = []
        var truncated = false
        if !body.isEmpty {
            let parsed = try JSON.decode(body)
            if let obj = parsed as? [String: Any] {
                if let raw = obj["rows"] as? [Any] {
                    for row in raw {
                        if let m = row as? [String: Any] {
                            rows.append(m)
                        } else {
                            rows.append([:])
                        }
                    }
                }
                if let t = obj["truncated"] as? Bool { truncated = t }
            }
        }
        self.truncated = truncated
        return rows
    }

    /// Translates friendly parameter aliases to the server's canonical on-wire
    /// keys. Both spellings are accepted, so callers may use whichever is
    /// clearer.
    ///
    /// Generic aliases (applied to all condition types):
    /// - `column` → `column_id`
    /// - `min` → `lo`
    /// - `max` → `hi`
    /// - `min_inclusive` → `lo_inclusive`
    /// - `max_inclusive` → `hi_inclusive`
    ///
    /// Type-specific aliases:
    /// - `fm_contains` / `fm_contains_all`: `value` → `pattern` (other types
    ///   like `pk`/`bitmap_eq` use `value` as their canonical key, so the
    ///   `value`→`pattern` alias must NOT apply globally)
    static func normalizeCondition(condType: String, params: [String: Any]) -> [String: Any] {
        var normalized: [String: Any] = [:]
        for (key, val) in params {
            let canonical: String
            switch key {
            case "column": canonical = "column_id"
            case "min": canonical = "lo"
            case "max": canonical = "hi"
            case "min_inclusive": canonical = "lo_inclusive"
            case "max_inclusive": canonical = "hi_inclusive"
            case "value":
                // The docs historically used "value" for the FTS pattern; the
                // server's fm_contains key is "pattern". Only apply this for
                // FTS conditions, since pk/bitmap_eq use "value" canonically.
                canonical = (condType == "fm_contains" || condType == "fm_contains_all")
                    ? "pattern" : "value"
            default: canonical = key
            }
            normalized[canonical] = val
        }
        return normalized
    }
}
