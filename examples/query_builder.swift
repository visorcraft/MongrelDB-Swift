// Example: query builder conditions with the MongrelDB Swift client.
//
// Add this file to an executable target that depends on the MongrelDB product,
// then `swift run`. Requires a mongreldb-server daemon running on
// http://127.0.0.1:8453.
//
// Creates a table, inserts five rows with varying scores, then uses the native
// query builder to fetch rows by a range condition and by an exact primary-key
// match. Cleans up by dropping the table.

import Foundation
import MongrelDB

let url = "http://127.0.0.1:8453"
// Unique suffix per run so repeated/concurrent runs never collide.
let table = "example_query_\(String(UUID().uuidString.prefix(8)))"

@main
struct QueryBuilderExample {
    static func main() async {
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

            // Five rows with varying scores.
            _ = try await db.put(table, cells: [1: 1, 2: "Alice", 3: 40.0])
            _ = try await db.put(table, cells: [1: 2, 2: "Bob", 3: 65.0])
            _ = try await db.put(table, cells: [1: 3, 2: "Carol", 3: 82.0])
            _ = try await db.put(table, cells: [1: 4, 2: "Dave", 3: 91.0])
            _ = try await db.put(table, cells: [1: 5, 2: "Eve", 3: 12.5])
            print("Inserted 5 rows")

            // Range condition: scores in [60.0, 90.0]. "column" maps to
            // column_id, so pass the numeric column id (3), not the name.
            let rng = try await db.query(table)
                .where("range_f64", params: ["column": 3, "min": 60.0, "max": 90.0, "min_inclusive": true, "max_inclusive": true])
                .execute()
            print("Range query (score in [60,90]) returned \(rng.count) rows:")
            for row in rng {
                print("  \(row)")
            }

            // Primary-key condition: fetch the single row with id == 4.
            let pk = try await db.query(table)
                .where("pk", params: ["value": 4])
                .execute()
            print("PK query (id == 4) returned \(pk.count) rows:")
            for row in pk {
                print("  \(row)")
            }

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
