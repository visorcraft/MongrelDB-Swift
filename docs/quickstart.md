# Quickstart

Zero to a running MongrelDB Swift program in fifteen minutes. This guide
assumes a fresh machine and walks through installing the prerequisites,
starting the daemon, and writing, running, and understanding a complete
program.

---

## 1. Prerequisites

You need two things installed: the Swift toolchain and a `mongreldb-server`
daemon.

### Install Swift 5.9 or newer

MongrelDB Swift is standard-library + Foundation only, so any recent Swift
toolchain works. Verify it:

```sh
swift --version
# Swift 5.9.x ...
```

If you do not have it, install from <https://swift.org/install/> or your
package manager (e.g. `pacman -S swift`, `brew install swift`).

### Install mongreldb-server

Fetch a prebuilt server binary from the
[MongrelDB releases](https://github.com/visorcraft/MongrelDB/releases):

```sh
mkdir -p bin
curl -fsSL -o bin/mongreldb-server \
  https://github.com/visorcraft/MongrelDB/releases/download/v0.60.2/mongreldb-server-linux-x64
chmod +x bin/mongreldb-server
```

Verify it runs:

```sh
./bin/mongreldb-server --version
```

## 2. Start the daemon

By default `mongreldb-server` listens on `http://127.0.0.1:8453` and stores
data in the current working directory.

```sh
mkdir -p /tmp/mdb-data && cd /tmp/mdb-data
/path/to/mongreldb-server
```

In another terminal, sanity-check it:

```sh
curl http://127.0.0.1:8453/health
# ok
```

Leave the daemon running for the rest of this guide.

## 3. Create a project and pull in the client

Create a new executable package and add the dependency:

```sh
mkdir MDBDemo && cd MDBDemo
swift package init --type executable
```

Edit `Package.swift`:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MDBDemo",
    dependencies: [
        .package(url: "https://github.com/visorcraft/MongrelDB-Swift.git", from: "0.60.2")
    ],
    targets: [
        .executableTarget(
            name: "MDBDemo",
            dependencies: ["MongrelDB"]
        )
    ]
)
```

Resolve the dependency:

```sh
swift package resolve
```

## 4. Write your first program

Replace `Sources/MDBDemo/main.swift`:

```swift
import MongrelDB

@main
struct Demo {
    static func main() async {
        // 1. Connect to the daemon. nil baseURL falls back to http://127.0.0.1:8453.
        let db = MongrelDBClient(baseURL: "http://127.0.0.1:8453")

        // 2. Health check before doing anything else.
        guard await db.health() else {
            fatalError("daemon not reachable")
        }

        do {
            // 3. Create a table. Each column has a stable numeric id, a name,
            //    a type, and flags. The first column is the primary key.
            //    Every column dict is sent verbatim to the engine, so any
            //    extra key it understands (enum_variants, default_value, ...)
            //    passes through untouched.
            let tid = try await db.createTable("orders", columns: [
                ["id": 1, "name": "id",       "ty": "int64",   "primary_key": true,  "nullable": false],
                ["id": 2, "name": "customer", "ty": "varchar", "primary_key": false, "nullable": false],
                [
                    "id": 3, "name": "status", "ty": "enum",
                    "enum_variants": ["draft", "open", "closed"],
                    "default_value": "draft",
                ],
                ["id": 4, "name": "amount",   "ty": "float64", "primary_key": false, "nullable": false],
            ])
            print("created table id: \(tid)")

            // Every column dictionary is sent verbatim, so the engine sees all
            // keys you supply: `enum_variants`, `default_value` for static
            // defaults, and `default_expr: "now"` / `"uuid"` for dynamic
            // defaults. Literal "now" / "uuid" strings use `default_value`.

            // 4. Insert rows. Cells maps column id -> value.
            _ = try await db.put("orders", cells: [1: 1, 2: "Alice", 3: "open", 4: 99.5])
            _ = try await db.put("orders", cells: [1: 2, 2: "Bob",   3: "open", 4: 150.0])

            // 5. Query with a native index condition. The range index serves
            //    this in sub-millisecond. Projection selects only column ids
            //    1 and 2.
            let rows: [[String: Any]] = try await db.query("orders")
                .where("range", params: ["column": 4, "min": 100.0])
                .projection([1, 2])
                .limit(100)
                .execute()
            for row in rows {
                print("row: \(row)")
            }

            // 6. Count the rows.
            let n = try await db.count("orders")
            print("total rows: \(n)")
        } catch {
            fatalError("error: \(error)")
        }
    }
}
```

Run it:

```sh
swift run
```

You should see:

```
created table id: 1
row: ["1": 2, "2": "Bob"]
total rows: 2
```

## 5. What each part does

| Code | What it does |
|------|--------------|
| `MongrelDBClient(baseURL:)` | Builds an HTTP client targeting one daemon. Safe to share across tasks. |
| `await db.health()` | GET `/health`; returns `true` when the daemon answers. Always check before real work. |
| `try await db.createTable(_:columns:)` | POST `/kit/create_table`. Column `id`s are the on-wire identifiers; use them everywhere else. |
| `try await db.put(_:cells:)` | Single-op transaction: POST `/kit/txn` with one `put` op. `cells` is flattened to `[col_id, val, ...]`. |
| `db.query(_:).where(...)` | Builds a `/kit/query` body. `where` pushes a condition down to a native index. |
| `.projection([1, 2])` | Server returns only those column ids, saving bandwidth. |
| `.limit(100)` | Caps the result; check `q.truncated` afterward to detect overflow. |
| `try await ...execute()` | Sends the query and decodes the `rows` array. |
| `try await db.count(_:)` | GET `/tables/{name}/count`. |

## 6. History retention and time travel

MongrelDB keeps a durable MVCC history window. You can inspect it, widen it,
and query older epochs with `AS OF EPOCH`.

```swift
print(try await db.historyRetentionEpochs())  // current window, e.g. 1024
print(try await db.earliestRetainedEpoch())   // oldest readable epoch, e.g. 3

// Widen the window. The response contains the updated values.
let resp = try await db.setHistoryRetentionEpochs(1_000)
print(resp["history_retention_epochs"] ?? "") // 1000

// Read the table as it existed at a captured commit epoch.
_ = try await db.put("orders", cells: [1: 1, 2: 99.5])
if let insertEpoch = db.lastEpoch {
    let rows = try await db.sql(
        "SELECT id, amount FROM orders AS OF EPOCH \(insertEpoch)"
    )
    print(rows)
}
```

Increasing retention cannot restore history that has already been pruned. The
window is a durable GC/time-travel policy, so it requires admin privileges when
the daemon is running with auth.

## 7. Common pitfalls

**Using the column name instead of the column id.** Every on-wire API uses the
numeric `id` from `createTable`, never the `name`. The query builder's
`column` alias maps to the server's `column_id` - pass the `Int` id, not the
`String` name:

```swift
// Wrong:
.where("range", params: ["column": "amount", "min": 100.0])
// Right:
.where("range", params: ["column": 4, "min": 100.0])
```

**Treating a single `put` as non-transactional.** `put` is a one-op
transaction. A unique constraint violation surfaces as a `ConflictError`
(HTTP 409), not as a silent no-op.

**Calling `commit` twice on the same `Transaction`.** The second call traps
with a precondition failure. Create a fresh `db.beginTransaction()` for each
logical unit of work.

**Reusing a `QueryBuilder` and expecting a fresh `truncated`.** `truncated`
reflects the most recent `execute()`. Build a new query, or re-run `execute()`
before reading it.

**Expecting `sql(_:)` to always return rows.** The `/sql` endpoint streams
Arrow IPC for `SELECT` in most builds, so `sql` returns an empty array (not an
error) for result sets. Use it for DDL/DML and statements whose success is the
signal; use the native query builder for typed row retrieval.

**Pointing at a daemon that requires auth.** If the daemon was started with
`--auth-token` or `--auth-users`, every call throws `AuthError` unless you
pass `token:` or `username:`/`password:`. See [auth.md](auth.md).

## Next steps

- [transactions.md](transactions.md) - atomic batches, idempotency, retries
- [queries.md](queries.md) - every native index condition
- [sql.md](sql.md) - recursive CTEs, window functions, `CREATE TABLE AS SELECT`
- [auth.md](auth.md) - bearer tokens, basic auth, user/role management
- [errors.md](errors.md) - the full error hierarchy and recovery patterns
