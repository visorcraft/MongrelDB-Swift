# Transactions

MongrelDB commits every write through a single atomic transaction endpoint
(`POST /kit/txn`). This guide covers the two ways to use it - a one-shot
single op, and a staged batch - plus idempotency keys for safe retries, typed
constraint-violation handling, and rollback.

The engine enforces `UNIQUE`, foreign-key, check, and trigger constraints at
**commit time**. A violation aborts the entire batch: no op in the batch
becomes visible.

---

## Single puts vs. batch transactions

### Single op: `MongrelDBClient.put`

`put` is a convenience wrapper that sends a one-op transaction. Use it when a
write is independent and you do not need atomicity across multiple rows.

```swift
// One row, one atomic op. nil idempotencyKey means "no idempotency key".
let res = try await db.put("orders", cells: [1: 1, 2: "Alice", 3: 99.5])
print(res)
```

`upsert`, `delete`, and `deleteByPk` are the same shape: single-op
transactions.

### Batch: `beginTransaction()` + `Transaction`

When several writes must succeed or fail together, stage them on a
`Transaction` and commit once. All ops go to the server in a single HTTP
request and commit atomically.

```swift
let txn = db.beginTransaction()
txn.put("orders", cells: [1: 10, 2: "Dave", 3: 50.0], returning: false)
txn.put("orders", cells: [1: 11, 2: "Eve",  3: 75.0], returning: false)
txn.deleteByPk("orders", pk: 2)

let results = try await txn.commit()
print("committed \(results.count) ops")
```

The `returning:` argument to `Transaction.put` asks the daemon to echo the
written row back in the result - useful for reading server-assigned values.

```swift
let txn = db.beginTransaction()
txn.put("orders", cells: [1: 42, 2: "Hal", 3: 12.0], returning: true)
let res = try await txn.commit()
print("server echoed: \(res[0])")
```

`Transaction.upsert(_:cells:updateCells:returning:)` applies `updateCells` on
a primary-key conflict. A `nil` `updateCells` means "do nothing on conflict".

## Idempotency keys for safe retries

Networks drop requests and daemons crash after committing but before replying.
An idempotency key makes a commit safe to retry: the daemon remembers the key
and replays the **original** result on a duplicate commit, even across
restarts.

Pass the key with `commit(idempotencyKey:)` (or on `put`/`upsert`):

```swift
// A handler that must not double-charge, even if the client retries or the
// connection drops after the daemon committed.
func charge(db: MongrelDBClient, orderID: Int) async throws {
    let txn = db.beginTransaction()
    txn.put("charges", cells: [1: orderID, 2: 199.0], returning: false)

    // Use a stable, business-meaningful key derived from the request. On a
    // retry with the same key the daemon returns the first commit's result
    // instead of inserting a second row.
    _ = try await txn.commit(idempotencyKey: "charge:\(orderID)")
}
```

Rules for keys:

- Any non-empty string works. Prefer content-derived, globally-unique values
  (e.g. `"charge:\(orderID)"`).
- `nil` (the default) disables idempotency - a retry will commit again.
- The key scopes the **entire batch**, not individual ops. Reuse the exact
  same ops and key together when retrying.

A safe retry loop:

```swift
func commitWithRetry(db: MongrelDBClient, build: (MongrelDBClient) -> Transaction, key: String) async throws {
    for attempt in 0..<3 {
        // Build a fresh Transaction inside the loop so retries always start clean.
        let txn = build(db)
        do {
            _ = try await txn.commit(idempotencyKey: key)
            return
        } catch let e as ConflictError {
            throw e // a real constraint violation - do not retry
        } catch let e as AuthError {
            throw e // caller must fix credentials - do not retry
        } catch {
            // QueryError / network - the idempotency key makes it safe to retry.
            if attempt == 2 { throw e }
            try await Task.sleep(nanoseconds: UInt64(1 << attempt) * 1_000_000_000)
        }
    }
}
```

Build the transaction inside the retry loop so a failed `commit` (which flips
the `Transaction` to "committed" via a precondition) is replaced by a fresh one
carrying the same ops and the same key.

## Handling constraint violations

Constraint violations arrive as HTTP 409, mapped to `ConflictError`. It carries
the structured `code` and the offending `opIndex`:

```swift
let txn = db.beginTransaction()
txn.put("orders", cells: [1: 1], returning: false) // duplicate PK

do {
    _ = try await txn.commit()
} catch let e as ConflictError {
    switch e.code {
    case "UNIQUE_VIOLATION":
        print("duplicate at op \(e.opIndex.map(String.init) ?? "n/a"): \(e.message)")
    case "FK_VIOLATION":
        print("missing parent at op \(e.opIndex.map(String.init) ?? "n/a"): \(e.message)")
    case "CHECK_VIOLATION":
        print("check failed at op \(e.opIndex.map(String.init) ?? "n/a"): \(e.message)")
    default:
        print("other conflict: \(e.message)")
    }
}
```

The error envelope from the daemon looks like:

```json
{"status": "aborted", "error": {"code": "UNIQUE_VIOLATION", "message": "...", "op_index": 0}}
```

`opIndex` points at the offending op within the batch so you can report which
row caused the failure.

For simple category checks, a typed `catch` is enough:

```swift
do { _ = try await txn.commit() }
catch is ConflictError { /* any constraint violation */ }
catch is NotFoundError { /* table or row missing */ }
catch is AuthError { /* bad credentials */ }
```

## Rollback after failure

There are two notions of "rollback":

1. **Server-side.** When `commit` throws `ConflictError`, the engine has
   already discarded the entire batch. Nothing was written; there is no server
   rollback to perform.
2. **Client-side.** `Transaction.rollback()` clears the locally staged ops.
   Call it to release the `Transaction` when you decide not to commit (for
   example, after a validation error in your own code, before ever sending).

```swift
let txn = db.beginTransaction()
txn.put("orders", cells: [1: 1, 2: "Iris", 3: 5.0], returning: false)

guard businessRuleOk() else {
    // Throw the staged ops away locally. Nothing has been sent to the daemon.
    txn.rollback()
    return
}

do {
    _ = try await txn.commit()
} catch is ConflictError {
    // On conflict the server already rolled back; nothing more to do.
}
```

`rollback` and `commit` both trap with a precondition failure if the
transaction was already committed. Treat that as a programming error to fix
upstream, not a runtime condition to catch.

### Recovering from a failed batch

Because a failed commit rejects the whole batch, the usual recovery is to
re-issue the ops that are still valid. A `Transaction` does not expose its
staged ops, so keep your own array if you need surgical retry.

## Summary

| Goal | Use |
|------|-----|
| One independent write | `put` / `upsert` / `delete` / `deleteByPk` |
| Several writes that must commit together | `beginTransaction()` + `commit()` |
| Retry safely after a network blip | `commit(idempotencyKey:)` with a stable key |
| Distinguish constraint classes | `catch let e as ConflictError`, read `e.code` and `e.opIndex` |
| Abort before sending | `rollback()` |

See [errors.md](errors.md) for the full error hierarchy and [queries.md](queries.md)
for read patterns.
