// Example: basic CRUD operations with the MongrelDB Swift client.
//
// Add this file to an executable target that depends on the MongrelDB product,
// then `swift run`. Requires a mongreldb-server daemon running on
// http://127.0.0.1:8453.
//
// Creates a table, inserts three rows, counts them, queries all rows, upserts
// (updates) one row by primary key, deletes one row, then drops the table.
// Progress is printed at every step.

import MongrelDB

let url = "http://127.0.0.1:8453"
let table = "example_crud"

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

        do {
            // Create the table. Schema: id (int64 PK), name (varchar), score (float64).
            let tid = try await db.createTable(table, columns: [
                ["id": 1, "name": "id", "ty": "int64", "primary_key": true, "nullable": false],
                ["id": 2, "name": "name", "ty": "varchar", "primary_key": false, "nullable": false],
                ["id": 3, "name": "score", "ty": "float64", "primary_key": false, "nullable": false],
            ])
            print("Created table \(table) (id \(tid))")

            // Insert three rows. Cells map column id -> value.
            _ = try await db.put(table, cells: [1: 1, 2: "Alice", 3: 95.5])
            _ = try await db.put(table, cells: [1: 2, 2: "Bob", 3: 82.0])
            _ = try await db.put(table, cells: [1: 3, 2: "Carol", 3: 78.3])
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
                                    cells: [1: 1, 2: "Alice", 3: 100.0],
                                    updateCells: [2: "Alice", 3: 100.0])
            print("Upserted Alice's score to 100.0")
            print("Total rows after upsert: \(try await db.count(table))")

            // Delete Carol (primary key 3).
            try await db.deleteByPk(table, pk: 3)
            print("Deleted Carol; remaining rows: \(try await db.count(table))")

            // Cleanup.
            try await db.dropTable(table)
            print("Dropped table \(table)")
        } catch {
            FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }
}
