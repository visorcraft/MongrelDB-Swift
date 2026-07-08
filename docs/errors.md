# Error handling

Every non-2xx response from the daemon is mapped to a typed Swift error. This
is the complete reference: the error hierarchy, the HTTP-status mapping, the
daemon's error envelope, and recovery patterns for each category.

---

## The error model

All client errors conform to `Error` via the `MongrelDBError` base class. The
client throws a specific subclass for each failure category:

| Type | Meaning | Typical cause |
|------|---------|---------------|
| `MongrelDBError` | Base class for all client errors | (catch this to handle any failure) |
| `AuthError` | HTTP 401 or 403 | Missing/bad credentials against an auth-enabled daemon |
| `NotFoundError` | HTTP 404 | Missing table, schema, or resource |
| `ConflictError` | HTTP 409 | Unique, foreign-key, check, or trigger violation at commit |
| `QueryError` | HTTP 400 or 5xx, plus transport | Malformed request, server failure, transport error |

Every `MongrelDBError` carries:

| Property | Meaning |
|----------|---------|
| `e.message` | The human-readable message from the daemon |
| `e.status` | The HTTP status code, or `-1` when unknown (transport failure) |
| `e.code` | The server's structured error code (e.g. `"UNIQUE_VIOLATION"`); `nil` when absent |
| `e.opIndex` | The offending op index within a batch, when reported; `nil` otherwise |
| `e.cause` | The underlying error for transport failures, when applicable |

## The daemon's error envelope

```json
{
  "status": "aborted",
  "error": {
    "code": "UNIQUE_VIOLATION",
    "message": "duplicate key in column 1",
    "op_index": 0
  }
}
```

Structured codes you will commonly see in `code`:

| `code` | Meaning |
|--------|---------|
| `UNIQUE_VIOLATION` | A unique/PK constraint rejected the commit |
| `FK_VIOLATION` | A foreign-key reference was missing |
| `CHECK_VIOLATION` | A check constraint or trigger rejected the commit |
| `NOT_FOUND` | A named resource (table, schema) does not exist |

## HTTP status → error mapping

| HTTP status | Type | Notes |
|-------------|------|-------|
| 401, 403 | `AuthError` | Bad/missing credentials |
| 404 | `NotFoundError` | Resource not found |
| 409 | `ConflictError` | Constraint violation at commit |
| 400 | `QueryError` | Malformed request / bad query |
| 5xx | `QueryError` | Daemon-side failure |
| other non-2xx | `QueryError` | Catch-all |
| 2xx | (no error) | Success |

Transport failures (unreachable host, broken pipe, decode errors) are also
mapped to `QueryError`, with `status == -1` and the underlying error in
`cause`.

## Discriminating errors

### By category - typed `catch`

```swift
do {
    _ = try await db.schemaFor("missing_table")
} catch let e as NotFoundError {
    print("table does not exist")
} catch is ConflictError {
    print("unexpected conflict on a read")
} catch is AuthError {
    print("bad credentials")
} catch is QueryError {
    print("server error or malformed request")
} catch {
    print("other error: \(error)")
}
```

### By details - read the fields

```swift
do {
    _ = try await txn.commit()
} catch let e as ConflictError {
    print("status=\(e.status) code=\(e.code ?? "nil") op=\(e.opIndex.map(String.init) ?? "n/a") msg=\(e.message)")
}
```

## Recovery patterns

### Auth failure - do not retry blindly

A retry will not fix bad credentials. Surface the error to the caller or
operator.

```swift
catch let e as AuthError {
    throw AuthError(message: "credentials rejected; refresh token: \(e.message)", status: e.status)
}
```

### Not found - fall back, do not crash

For lookups by primary key, a 404 may be a normal "absent" result.

```swift
do {
    _ = try await db.schemaFor(tableName)
} catch is NotFoundError {
    return [:] // table missing - treat as empty
}
```

Note: a `pk` query against an existing table returns zero rows, not a 404;
`NotFoundError` here means the table itself is missing.

### Constraint conflict - report the offending op

```swift
do {
    _ = try await txn.commit()
} catch let e as ConflictError {
    if let i = e.opIndex {
        print("op \(i) violated \(e.code ?? "?"): \(e.message)")
    } else {
        print("conflict \(e.code ?? "?"): \(e.message)")
    }
    throw e
}
```

The engine already rolled back the whole batch - there is nothing to undo.

### Transient failure - retry with an idempotency key

`QueryError` covers transport and 5xx failures. With an idempotency key,
retrying a transaction is safe (see [transactions.md](transactions.md)).

```swift
func run(db: MongrelDBClient, build: (MongrelDBClient) -> Transaction, key: String) async throws {
    // build is a closure that returns a fresh Transaction with the same ops.
    do {
        _ = try await build(db).commit(idempotencyKey: key)
    } catch is AuthError, is ConflictError {
        throw MongrelDBError(message: "not transient") // caller must not retry
    } catch {
        throw error // QueryError / network - caller may retry with the same key
    }
}
```

### Transaction-state error

Calling `commit` or `rollback` twice on the same `Transaction` traps with a
precondition failure. That is a programming bug - fix the control flow rather
than catching it.

## Quick reference

```swift
// Category checks (most specific first):
do { /* ... */ }
catch let e as AuthError      // 401/403
catch let e as NotFoundError  // 404
catch let e as ConflictError  // 409
catch let e as QueryError     // 400/5xx/network
catch let e as MongrelDBError // base

// Detail extraction:
catch let e as ConflictError {
    // e.code    // String?, e.g. "UNIQUE_VIOLATION"
    // e.opIndex // Int?
    // e.message // String
    // e.status  // Int
}
```

## Next steps

- [transactions.md](transactions.md) - constraint handling and retries in context
- [auth.md](auth.md) - credential management
