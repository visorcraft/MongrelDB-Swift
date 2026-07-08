# Authentication & Authorization

A `mongreldb-server` daemon runs in one of three modes:

1. **Open** (default) — no auth required.
2. **Bearer token** (`--auth-token <TOKEN>`) — every request must carry an
   `Authorization: Bearer <TOKEN>` header.
3. **HTTP Basic** (`--auth-users`) — every request must carry an
   `Authorization: Basic <base64(user:pass)>` header.

The Swift client supports all three through `MongrelDBClient` initializer
arguments. This guide shows each mode, how to inspect what was sent, and how
to manage users and roles via SQL when the server is in Basic mode.

---

## Bearer token mode

Start the daemon with a token:

```sh
mongreldb-server --auth-token s3cret-token
```

Connect with `token:`. The token is sent as `Authorization: Bearer ...` on
every request.

```swift
let db = MongrelDBClient(baseURL: "http://127.0.0.1:8453", token: "s3cret-token")

let ok = await db.health()
print("healthy: \(ok)")
```

A missing or wrong token surfaces as `AuthError` (HTTP 401/403).

### Where the token comes from

Hard-coding secrets in source is bad practice. Read it from the environment:

```swift
guard let token = ProcessInfo.processInfo.environment["MONGRELDB_TOKEN"], !token.isEmpty else {
    fatalError("MONGRELDB_TOKEN not set")
}
let db = MongrelDBClient(token: token)
```

## Basic auth mode

Start the daemon with a users file or inline users:

```sh
mongreldb-server --auth-users
```

Connect with `username:` / `password:`:

```swift
let db = MongrelDBClient(
    baseURL: "http://127.0.0.1:8453",
    username: "admin",
    password: "s3cret"
)
```

The client base64-encodes `username:password` and sets
`Authorization: Basic ...` on every request.

## Token takes precedence

If you supply both, `token:` wins and Basic credentials are ignored. This lets
you layer an override without branching:

```swift
let db = MongrelDBClient(
    baseURL: url,
    username: "fallback",
    password: "user",
    token: "overrides-everything"
)
```

## Custom session and timeouts

`session:` installs a custom `URLSession` (e.g. with a custom configuration for
TLS, proxies, or caching). `timeout:` sets the per-request timeout.

```swift
let config = URLSessionConfiguration.default
config.timeoutIntervalForRequest = 60
let db = MongrelDBClient(
    baseURL: url,
    token: token,
    session: URLSession(configuration: config),
    timeout: 60
)
```

## Verifying what gets sent

The auth header is applied inside `MongrelDBClient.send(...)`, called from
every request. For debugging, point the client at a local echo server or watch
the daemon logs. A quick check with a tiny server:

```swift
// Point MongrelDBClient at a server that prints the Authorization header, then
// call db.health(). The printed value is what the daemon will see.
```

## User and role management via SQL

When the daemon is in Basic auth mode, users and roles live in the catalog and
are managed with SQL. Run these statements through `sql(_:)`.

### Create a user

```swift
_ = try await db.sql("CREATE USER alice WITH PASSWORD 'hunter2'")
```

### Alter a user

Change a password:

```swift
_ = try await db.sql("ALTER USER alice WITH PASSWORD 'new-password'")
```

Grant the admin role:

```swift
_ = try await db.sql("ALTER USER alice ADMIN")
```

`ALTER USER ... ADMIN` is how you promote a user to full administrative
privileges (table creation/drop, compaction, user management). Use it
sparingly.

### Drop a user

```swift
_ = try await db.sql("DROP USER alice")
```

### Roles and grants

```swift
_ = try await db.sql("CREATE ROLE analyst")
_ = try await db.sql("GRANT SELECT ON orders TO analyst")
_ = try await db.sql("GRANT analyst TO alice")
_ = try await db.sql("REVOKE SELECT ON orders FROM analyst")
_ = try await db.sql("DROP ROLE analyst")
```

Exact grant syntax mirrors the server's SQL flavor; consult the server's SQL
reference for the full `GRANT`/`REVOKE` grammar available in your build.

## Common pitfalls

**Auth errors look like other errors without a typed catch.** A 401/403 throws
`AuthError`; a 404 throws `NotFoundError`. Always discriminate by type rather
than string-matching `error.localizedDescription`.

**Forgetting to set auth in production.** A client built with
`MongrelDBClient(baseURL:)` and no credentials sends no credentials. Against an
auth-enabled daemon, every call throws `AuthError`. Centralize client
construction so the auth option is never accidentally dropped.

**Sharing one client across tasks is fine; sharing credentials across users is
not.** A `MongrelDBClient` is safe for concurrent use, but it carries one
identity. If you serve multiple authenticated users, build a client per user
(or per request) with that user's token.

**Token in version control.** Put secrets in the environment, a secret
manager, or a file outside the repo. Never commit a real token.

## Next steps

- [errors.md](errors.md) — `AuthError` and the rest of the error hierarchy
- [quickstart.md](quickstart.md) — the full end-to-end walkthrough
