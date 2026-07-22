// Example: atomic batch transactions with the MongrelDB Swift client.
//
// Add this file to an executable target that depends on the MongrelDB product,
// then `swift run`. Requires a mongreldb-server daemon running on
// http://127.0.0.1:8453.
//
// Creates a table, stages three inserts in a single transaction, commits them
// atomically, verifies the count, then demonstrates idempotent retries by
// re-committing with the same idempotency key (the daemon returns the original
// result and applies no duplicate rows). Cleans up by dropping the table.

import Foundation
import MongrelDB

@main
struct TransactionsExample {
    static func main() async {
        let url = "http://127.0.0.1:8453"
        // Unique suffix per run so repeated/concurrent runs never collide.
        let suffix = String(UUID().uuidString.prefix(8))
        let table = "example_txn_\(suffix)"
        // Idempotency key must be unique per run so retry logic isn't confused
        // with a previous run's committed batch.
        let idempotencyKey = "example-txn-\(suffix)"

        let db = MongrelDBClient(baseURL: url)

        guard await db.health() else {
            FileHandle.standardError.write("daemon not reachable at \(url)\n".data(using: .utf8)!)
            exit(1)
        }
        print("Connected to MongrelDB")

        // The table is dropped on both the success path (end of the do block)
        // and the error path (catch) so cleanup always happens. (Swift does not
        // allow `await` inside a `defer` block, so we drop explicitly in each.)
        do {
            _ = try await db.createTable(table, columns: [
                ["id": 1, "name": "id", "ty": "int64", "primary_key": true, "nullable": false],
                ["id": 2, "name": "name", "ty": "varchar", "primary_key": false, "nullable": false],
                ["id": 3, "name": "score", "ty": "float64", "primary_key": false, "nullable": false],
            ])
            print("Created table \(table)")

            // Stage three puts and commit them atomically. Either every op
            // lands or none do; a constraint violation rolls back the batch.
            let txn = db.beginTransaction()
            txn.put(table, cells: [1: 1, 2: "Alice", 3: 95.5], returning: false)
            txn.put(table, cells: [1: 2, 2: "Bob", 3: 82.0], returning: false)
            txn.put(table, cells: [1: 3, 2: "Carol", 3: 78.3], returning: false)
            print("Staged \(txn.count) operations")

            let results = try await txn.commit()
            print("Committed atomically: \(results.count) operations applied")

            print("Verified row count after commit: \(try await db.count(table))")

            // Idempotent retry: stage the same batch again with an idempotency
            // key, then commit a second time with the SAME key. The daemon
            // replays the original result and applies no extra rows.
            let retry = db.beginTransaction()
            retry.put(table, cells: [1: 4, 2: "Dave", 3: 60.0], returning: false)
            _ = try await retry.commit(idempotencyKey: idempotencyKey)
            print("After first idempotent commit: \(try await db.count(table)) rows")

            let retry2 = db.beginTransaction()
            retry2.put(table, cells: [1: 4, 2: "Dave", 3: 60.0], returning: false)
            _ = try await retry2.commit(idempotencyKey: idempotencyKey)
            print("After duplicate idempotent commit (same key): \(try await db.count(table)) rows (no double-apply)")

            // Cleanup on the success path.
            try? await db.dropTable(table)
            print("Dropped table \(table)")
        } catch {
            FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
            // Cleanup on the error path too, so the table never leaks.
            try? await db.dropTable(table)
            exit(1)
        }
    }
}
