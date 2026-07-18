<p align="center">
  <img src="assets/mongrel.png" alt="MongrelDB logo" width="250" />
</p>

<h1 align="center">MongrelDB Swift Client</h1>

<p align="center">
  <b>Swift client for MongrelDB - embedded+server database with SQL, vector search, full-text search, and AI-native retrieval.</b>
  <br />
  No external dependencies - built on the standard library <code>URLSession</code> (Swift 5.9+). The API mirrors the MongrelDB PHP, Go, Java, and Ruby clients.
</p>

<p align="center">
  <a href="https://github.com/visorcraft/MongrelDB-Swift/actions/workflows/ci.yml"><img src="https://github.com/visorcraft/MongrelDB-Swift/actions/workflows/ci.yml/badge.svg" alt="Swift CI" /></a>
  <a href="https://swift.org/"><img src="https://img.shields.io/badge/Swift-5.9%2B-orange.svg" alt="Swift" /></a>
  <a href="https://swift.org/"><img src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20iOS%20%7C%20Linux-lightgrey.svg" alt="Platform" /></a>
  <a href="#license"><img src="https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-blue.svg" alt="License" /></a>
</p>

## Package

| Surface | Package | Install |
|---|---|---|
| Swift client | `https://github.com/visorcraft/MongrelDB-Swift.git` | Swift Package Manager snippets below |

### Swift Package Manager

Add the dependency in your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/visorcraft/MongrelDB-Swift.git", from: "0.60.3")
]
```

and attach it to a target:

```swift
.target(
    name: "YourApp",
    dependencies: ["MongrelDB"]
)
```

### Xcode

File → Add Package Dependencies… → enter `https://github.com/visorcraft/MongrelDB-Swift.git`, then add the `MongrelDB` library to your target.

The package has no runtime dependencies - only the Swift standard library and Foundation.

## Requirements

- **Swift 5.9 or newer**
- A running [`mongreldb-server`](https://github.com/visorcraft/MongrelDB) daemon

## What It Provides

- **Typed CRUD** over the Kit transaction endpoint: `put`, `upsert` (insert-or-update on PK conflict), `delete` by row id or primary key, all with optional idempotency keys for safe retries.
- **Fluent query builder** that pushes conditions down to the engine's specialized indexes for sub-millisecond lookups: bitmap equality/IN, learned-range, null checks, FM-index full-text search, HNSW vector similarity (`ann`), and sparse vector match. Friendly aliases (`column` → `column_id`, `min`/`max` → `lo`/`hi`) are translated to the server's on-wire keys.
- **Idempotent batch transactions** - operations staged locally and committed atomically, with the engine enforcing unique, foreign-key, and check constraints at commit time. Idempotency keys return the original response on duplicate commits, even after a crash.
- **Full SQL access** through the DataFusion-backed `/sql` endpoint: recursive CTEs, window functions, `CREATE TABLE AS SELECT`, materialized views, and multi-statement execution.
- **Schema management**: typed table creation with engine-native passthrough (each column dict is forwarded verbatim, so `enum_variants`, `default_value`, `default_expr`, `auto_increment`, `encrypted`, and any other engine key work without a typed wrapper), full schema catalog, and per-table descriptors.
- **User/role/credentials management** via SQL: Argon2id-hashed catalog users, roles, and `GRANT`/`REVOKE` table-level permissions, all executed through `sql`.
- **Maintenance**: compaction (all tables or per-table).
- **Pluggable transport**: bring your own `URLSession`. Bearer token and HTTP Basic auth are first-class options.
- **Typed errors**: `AuthError` (401/403), `NotFoundError` (404), `ConflictError` (409, with error code + op index), and `QueryError` (everything else), all conforming to `Error` via `MongrelDBError` and carrying the status code and decoded server envelope.

## Examples

Task-focused, commented guides live in [`docs/`](docs):

- [Quickstart](docs/quickstart.md) - install, start the daemon, write and run a complete program.
- [Transactions](docs/transactions.md) - batch commits, idempotency keys, constraint handling.
- [Queries](docs/queries.md) - every native condition type and the index it pushes down to.
- [SQL](docs/sql.md) - recursive CTEs, window functions, advanced SQL.
- [Authentication](docs/auth.md) - Bearer token, HTTP Basic, and open modes.
- [Errors](docs/errors.md) - the error hierarchy and recovery patterns.

## Quick Example

```swift
import MongrelDB

// Connect to a running mongreldb-server daemon.
let db = MongrelDBClient(baseURL: "http://127.0.0.1:8453")

// Create a table. Column ids are stable on-wire identifiers. The client
// passes every column dict through verbatim, so any key the engine
// recognises works here - `enum_variants` for an `enum` column and
// `default_value` for a column default, for example.
_ = try await db.createTable("orders", columns: [
    ["id": 1, "name": "id",       "ty": "int64",   "primary_key": true,  "nullable": false],
    ["id": 2, "name": "customer", "ty": "varchar", "primary_key": false, "nullable": false],
    [
        "id": 3, "name": "status", "ty": "enum",
        "enum_variants": ["draft", "open", "closed"],
        "default_value": "draft",
    ],
    ["id": 4, "name": "amount",   "ty": "float64", "primary_key": false, "nullable": false]
], constraints: [
    "checks": [[
        "id": 1,
        "name": "ck_customer",
        "expr": ["IsNotNull": 2],
    ]],
])

// Column dictionaries pass through verbatim: `enum_variants` restricts an enum
// column, `default_value` supplies a static default, and `default_expr: "now"`
// or `"uuid"` asks the engine to fill a dynamic default. Literal strings "now"
// and "uuid" use `default_value`, not `default_expr`.

// Insert rows (cells map column id -> value).
_ = try await db.put("orders", cells: [1: 1, 2: "Alice", 3: "open",   4: 99.50])
_ = try await db.put("orders", cells: [1: 2, 2: "Bob",   3: "closed", 4: 150.00])

// Upsert (insert or update on PK conflict).
_ = try await db.upsert(
    "orders",
    cells: [1: 1, 2: "Alice", 3: "open", 4: 120.00],
    updateCells: [3: "open", 4: 120.00]
)

// Query with a native index condition (learned-range index).
let rows: [[String: Any]] = try await db.query("orders")
    .where("range", params: ["column": 4, "min": 100.0])
    .projection([1, 2])
    .limit(100)
    .execute()
print("rows: \(rows.count)")

let n = try await db.count("orders")
print("count: \(n)") // 2

// Run SQL.
_ = try await db.sql("UPDATE orders SET amount = 200.0 WHERE customer = 'Bob'")
```

## Authentication

```swift
// Bearer token (--auth-token mode)
let db = MongrelDBClient(baseURL: "http://127.0.0.1:8453", token: "my-secret-token")

// HTTP Basic (--auth-users mode)
let db = MongrelDBClient(baseURL: "http://127.0.0.1:8453", username: "admin", password: "s3cret")

// Default URL (http://127.0.0.1:8453) when baseURL is nil
let db = MongrelDBClient()

// Custom URLSession (timeouts, TLS, transport, etc.)
let config = URLSessionConfiguration.default
config.timeoutIntervalForRequest = 60
let db = MongrelDBClient(
    baseURL: "http://127.0.0.1:8453",
    session: URLSession(configuration: config)
)
```

A bearer token takes precedence over basic-auth credentials when both are supplied.

## Batch transactions

Operations are staged locally and committed atomically. The engine enforces
unique, foreign-key, and check constraints at commit time.

```swift
let txn = db.beginTransaction()
txn.put("orders", cells: [1: 10, 2: "Dave",  3: "open", 4: 50.00], returning: false)
txn.put("orders", cells: [1: 11, 2: "Eve",            4: 75.00], returning: false)
txn.deleteByPk("orders", pk: 2)

do {
    let results = try await txn.commit() // atomic - all or nothing
    print("committed \(results.count) ops")
} catch let e as ConflictError {
    // A constraint violation rolled back every op.
    print("duplicate: \(e.code ?? "?") at op \(e.opIndex.map(String.init) ?? "n/a")")
    txn.rollback() // discard locally as well
}

// Idempotent commit - safe to retry; the daemon returns the original response.
let txn2 = db.beginTransaction()
txn2.put("orders", cells: [1: 20, 2: "Frank", 3: "closed", 4: 100.00], returning: false)
_ = try await txn2.commit(idempotencyKey: "order-20-create")
```

A `Transaction` is single-use: calling `commit` or `rollback` twice traps with
a precondition failure. Create a fresh one with `db.beginTransaction()` for each
batch.

## Native query builder

Conditions push down to the engine's specialized indexes. The builder accepts
friendly aliases that are translated to the server's on-wire keys: `column`
(→ `column_id`), `min`/`max` (→ `lo`/`hi`). The canonical keys are also
accepted directly.

```swift
// Bitmap equality (low-cardinality columns).
_ = try await db.query("orders")
    .where("bitmap_eq", params: ["column": 2, "value": "Alice"])
    .execute()

// Range query (learned-range index).
_ = try await db.query("orders")
    .where("range", params: ["column": 4, "min": 50.0, "max": 150.0])
    .limit(100).execute()

// Full-text search (FM-index).
_ = try await db.query("documents")
    .where("fm_contains", params: ["column": 2, "pattern": "database performance"])
    .limit(10).execute()

// Vector similarity search (HNSW).
_ = try await db.query("embeddings")
    .where("ann", params: ["column": 2, "query": [0.1, 0.2, 0.3], "k": 10])
    .execute()

// Check whether a result was capped by the limit.
let q = db.query("orders")
    .where("range", params: ["column": 4, "min": 0])
    .limit(100)
let rows = try await q.execute()
if q.truncated {
    // result set hit the limit; more matches exist on the server
}
```

## SQL

```swift
_ = try await db.sql("INSERT INTO orders (id, customer, status, amount) VALUES (99, 'Zoe', 'open', 999.0)")
_ = try await db.sql("CREATE TABLE archive AS SELECT * FROM orders WHERE amount > 500")

// Recursive CTEs and window functions
_ = try await db.sql("WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM r WHERE n<10) SELECT n FROM r")
_ = try await db.sql("SELECT id, ROW_NUMBER() OVER (PARTITION BY customer ORDER BY amount DESC) FROM orders")
```

The `/sql` endpoint generally streams Arrow IPC bytes for `SELECT`s; `sql()`
decodes JSON row sets when the daemon returns them and returns an empty array
otherwise (DDL/DML or binary bodies).

## User & role management

User, role, and permission management is performed through SQL against the
daemon's catalog. Passwords are Argon2id-hashed server-side.

```swift
_ = try await db.sql("CREATE USER admin WITH PASSWORD 's3cret-pw'")
_ = try await db.sql("ALTER USER admin SET ADMIN TRUE")

_ = try await db.sql("CREATE ROLE analyst")
_ = try await db.sql("GRANT select ON orders TO analyst") // table-level permission
_ = try await db.sql("GRANT analyst TO alice")

_ = try await db.sql("SELECT username FROM catalog.users") // list users
_ = try await db.sql("SELECT name FROM catalog.roles")     // list roles
```

## Error handling

Every non-2xx response is mapped to a typed error. Catch the specific type for
the category, or catch `MongrelDBError` to handle any failure. Each carries the
HTTP status code and the server's decoded error envelope (`code`, `opIndex`).

```swift
do {
    _ = try await db.schemaFor("missing_table")
} catch let e as NotFoundError {
    print("not found: \(e.message)")
} catch let e as AuthError {
    print("not authorized: \(e.message)")
} catch let e as ConflictError {
    print("constraint \(e.code ?? "?") at op \(e.opIndex.map(String.init) ?? "n/a")")
} catch let e as QueryError {
    print("query/server error: \(e.message) (status \(e.status))")
}

// Or inspect directly on the base type:
do {
    _ = try await db.schemaFor("missing_table")
} catch let e as MongrelDBError {
    print("status=\(e.status) code=\(e.code ?? "nil") msg=\(e.message)")
    // e.g. status=404 code=NOT_FOUND msg=no such table
}
```

## API reference

### `MongrelDBClient`

| Method | Description |
|--------|-------------|
| `init(baseURL:token:username:password:session:timeout:)` | Construct a client (`baseURL` defaults to `http://127.0.0.1:8453`) |
| `health() async -> Bool` | Check daemon health |
| `tableNames() async throws -> [String]` | List table names |
| `createTable(_:columns:constraints:) async throws -> Int` | Create a table; returns the table id |
| `dropTable(_:) async throws` | Drop a table |
| `count(_:) async throws -> Int` | Row count |
| `put(_:cells:idempotencyKey:) async throws -> [String: Any]` | Insert a row |
| `upsert(_:cells:updateCells:idempotencyKey:) async throws -> [String: Any]` | Upsert a row |
| `delete(_:rowId:) async throws` | Delete by row id |
| `deleteByPk(_:pk:) async throws` | Delete by primary key |
| `query(_:) -> QueryBuilder` | Start a native query |
| `sql(_:) async throws -> [[String: Any]]` | Execute SQL |
| `schema() async throws -> [String: [String: Any]]` | Full schema catalog |
| `schemaFor(_:) async throws -> [String: Any]` | Single-table descriptor |
| `compact() async throws -> [String: Any]` | Compact all tables |
| `compactTable(_:) async throws -> [String: Any]` | Compact one table |
| `historyRetentionEpochs() async throws -> UInt64` | Current history-retention window |
| `earliestRetainedEpoch() async throws -> UInt64` | Oldest epoch still readable with `AS OF EPOCH` |
| `setHistoryRetentionEpochs(_:) async throws -> [String: Any]` | Set the durable MVCC window |
| `lastEpoch: UInt64?` | Commit epoch of the most recent `/kit/txn` |
| `beginTransaction() -> Transaction` | Start a batch |

### `QueryBuilder`

| Method | Description |
|--------|-------------|
| `where(_:params:) -> QueryBuilder` | Add a native condition (AND-ed) |
| `projection(_:) -> QueryBuilder` | Set column projection |
| `limit(_:) -> QueryBuilder` | Set row limit |
| `offset(_:) -> QueryBuilder` | Skip matching rows before the limit |
| `build() -> [String: Any]` | Build the request payload |
| `execute() async throws -> [[String: Any]]` | Run the query |
| `truncated: Bool` | Whether the last `execute()` result hit the limit |

### `Transaction`

| Method | Description |
|--------|-------------|
| `put(_:cells:returning:) -> Transaction` | Stage an insert |
| `upsert(_:cells:updateCells:returning:) -> Transaction` | Stage an upsert |
| `delete(_:rowId:) -> Transaction` | Stage a delete by row id |
| `deleteByPk(_:pk:) -> Transaction` | Stage a delete by primary key |
| `count: Int` | Number of staged operations |
| `commit(idempotencyKey:) async throws -> [[String: Any]]` | Commit atomically |
| `rollback()` | Discard all operations |

### Errors

| Type | HTTP status | Meaning |
|------|-------------|---------|
| `MongrelDBError` | any | Base class for all client errors |
| `AuthError` | 401, 403 | Bad or missing credentials |
| `NotFoundError` | 404 | Missing table, schema, or resource |
| `ConflictError` | 409 | Unique, FK, check, or trigger violation (carries `code` + `opIndex`) |
| `QueryError` | 400, 5xx | Malformed query, server error, or transport failure |

All errors conform to `Error` (via `MongrelDBError`) and expose `message`,
`status`, `code`, and `opIndex`.

## Building and testing

The test suite is a live integration suite: it boots a real `mongreldb-server`
daemon and exercises the full client surface against it. It skips automatically
(via `XCTSkip`) when no daemon is available.

```sh
# Build the package:
swift build

# Run the offline checks (live tests self-skip without a daemon):
swift test

# Run the live suite. The harness boots mongreldb-server itself if it can find
# the binary (in this order):
#   1. the MONGRELDB_SERVER env var (path to the server binary)
#   2. ./bin/mongreldb-server
#   3. mongreldb-server on PATH
# Or point it at an already-running daemon with MONGRELDB_URL.
MONGRELDB_SERVER=./bin/mongreldb-server swift test
```

Fetch a prebuilt server binary from the [MongrelDB releases](https://github.com/visorcraft/MongrelDB/releases):

```sh
mkdir -p bin
curl -fsSL -o bin/mongreldb-server \
  https://github.com/visorcraft/MongrelDB/releases/download/v0.60.3/mongreldb-server-linux-x64
chmod +x bin/mongreldb-server
```

## History retention

Use `historyRetentionEpochs()`, `setHistoryRetentionEpochs(_:)`, and
`earliestRetainedEpoch()` with MongrelDB 0.48.0+. The retention window controls
how far back `AS OF EPOCH` time-travel queries can read; increasing it cannot
bring back history that has already been pruned.

```swift
// Inspect the current durable MVCC window.
let retained = try await db.historyRetentionEpochs()  // e.g. 1024
let earliest = try await db.earliestRetainedEpoch()   // e.g. 3

// Widen the window. The response contains the updated values.
let resp = try await db.setHistoryRetentionEpochs(1_000)
print(resp["history_retention_epochs"] ?? "") // 1000

// After a write, lastEpoch holds the commit epoch of the most recent put,
// upsert, delete, or transaction commit.
_ = try await db.put("orders", cells: [1: 1, 2: 99.5])
if let insertEpoch = db.lastEpoch {
    // Query the table as it existed at that exact commit epoch.
    let rows = try await db.sql("SELECT id, amount FROM orders AS OF EPOCH \(insertEpoch)")
}
```

## Contributing

Contributions are welcome. Please:

1. Open an issue first for non-trivial changes.
2. Add focused tests near your change - the suite must stay green.
3. Keep the client dependency-free (Swift standard library + Foundation only).

## License

Dual-licensed under the **MIT License** or the **Apache License, Version 2.0**,
at your option. See [MIT](LICENSE-MIT) OR [Apache-2.0](LICENSE-APACHE) for the full text.

`SPDX-License-Identifier: MIT OR Apache-2.0`
