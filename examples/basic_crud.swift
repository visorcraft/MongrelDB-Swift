// Example: basic CRUD operations with the MongrelDB Swift client.
//
// Add this file to an executable target that depends on the MongrelDB product,
// then `swift run`. Requires a mongreldb-server daemon running on
// http://127.0.0.1:8453.
//
// Creates a table with a plain int/varchar/float schema plus an `enum` tier
// column whose variants and default are passed verbatim in the column dict,
// inserts three rows, counts them, queries all rows, upserts (updates) one row
// by primary key, deletes one row, then drops the table. Progress is printed
// at every step.

import Foundation
import MongrelDB

let url = "http://127.0.0.1:8453"
// Unique suffix per run so repeated/concurrent runs never collide on the same
// table name. Foundation provides UUID (also needed for FileHandle/exit).
let suffix = String(UUID().uuidString.prefix(8))
let table = "example_crud_\(suffix)"

@main
struct BasicCrud {
    static func main() async {
        let db = MongrelDBClient(baseURL: url)

        // Health check; bail out if the daemon is unreachable.
        guard await db.health() else {
            FileHandle.standardError.write("daemon not reachable at \(url)\n".data(using: .utf8)!)
            exit(1)
        }
        print("Connected to MongrelDB")

        // The table is dropped on both the success path (end of the do block)
        // and the error path (catch) so cleanup always happens. (Swift does not
        // allow `await` inside a `defer` block, so we drop explicitly in each.)
        do {
            // Create the table. Schema: id (int64 PK), name (varchar),
            // tier (enum with variants and a default), score (float64).
            // Each column dict is sent verbatim to the engine, so any extra
            // keys it understands (enum_variants, default_value, ...) pass
            // through untouched.
            let tid = try await db.createTable(table, columns: [
                ["id": 1, "name": "id", "ty": "int64", "primary_key": true, "nullable": false],
                ["id": 2, "name": "name", "ty": "varchar", "primary_key": false, "nullable": false],
                [
                    "id": 3, "name": "tier", "ty": "enum",
                    "enum_variants": ["bronze", "silver", "gold"],
                    "default_value": "bronze",
                ],
                ["id": 4, "name": "score", "ty": "float64", "primary_key": false, "nullable": false],
            ])
            print("Created table \(table) (id \(tid))")

            // Insert three rows. Cells map column id -> value. Omitting
            // column 3 (tier) on Bob's row lets the server-side default fire.
            _ = try await db.put(table, cells: [1: 1, 2: "Alice", 3: "gold",   4: 95.5])
            _ = try await db.put(table, cells: [1: 2, 2: "Bob",                 4: 82.0])
            _ = try await db.put(table, cells: [1: 3, 2: "Carol", 3: "bronze", 4: 78.3])
            print("Inserted 3 rows")

            print("Total rows: \(try await db.count(table))")

            // Query all rows (no conditions).
            let all = try await db.query(table).execute()
            print("Query returned \(all.count) rows:")
            for row in all {
                print("  \(row)")
            }

            // Upsert (update) Alice's score. updateCells supplies the values
            // written on a primary-key conflict.
            _ = try await db.upsert(table,
                                    cells: [1: 1, 2: "Alice", 3: "gold", 4: 100.0],
                                    updateCells: [2: "Alice", 3: "gold", 4: 100.0])
            print("Upserted Alice's score to 100.0")
            print("Total rows after upsert: \(try await db.count(table))")

            // Delete Carol (primary key 3).
            try await db.deleteByPk(table, pk: 3)
            print("Deleted Carol; remaining rows: \(try await db.count(table))")

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
