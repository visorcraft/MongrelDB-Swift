import Foundation

/// Stages operations locally and commits them atomically in a single
/// `/kit/txn` request. The engine enforces unique, foreign-key, check, and
/// trigger constraints at commit time; on any violation all operations roll
/// back and ``commit(idempotencyKey:)`` throws a ``ConflictError`` carrying the
/// server's structured error code and offending op index.
///
/// A `Transaction` is single-use: after ``commit(idempotencyKey:)`` or
/// ``rollback()`` it must not be reused. Calling either a second time traps
/// with a precondition failure.
///
/// Start one with ``MongrelDBClient/beginTransaction()``:
/// ```swift
/// let txn = db.beginTransaction()
/// try await txn.put("orders", cells: [1: 10, 2: "Dave"], returning: false)
/// try await txn.put("orders", cells: [1: 11, 2: "Eve"], returning: false)
/// try await txn.deleteByPk("orders", pk: 2)
/// let results = try await txn.commit() // atomic — all or nothing
/// ```
public final class Transaction {
    /// The error used when `commit` or `rollback` is called on a transaction
    /// that has already been committed or rolled back.
    public static let alreadyCommittedMessage = "mongreldb: transaction already committed"

    private let client: MongrelDBClient
    private var ops: [[String: Any]] = []
    private var committed: Bool = false

    init(client: MongrelDBClient) {
        self.client = client
    }

    /// Stages an insert. `returning`, when `true`, asks the daemon to echo the
    /// row in the per-operation result. Staging is local (no network I/O) —
    /// flush the batch with ``commit(idempotencyKey:)``.
    /// - Parameters:
    ///   - table: the target table
    ///   - cells: a column-id-to-value map
    ///   - returning: whether to echo the row in the result
    /// - Returns: this transaction, for chaining
    @discardableResult
    public func put(_ table: String, cells: [Int: Any], returning: Bool) -> Transaction {
        precondition(!committed, Self.alreadyCommittedMessage)
        let body: [String: Any] = [
            "table": table,
            "cells": MongrelDBClient.flattenCells(cells),
            "returning": returning,
        ]
        ops.append(["put": body])
        return self
    }

    /// Stages an insert-or-update. `updateCells`, when non-nil, supplies the
    /// values written on a primary-key conflict; `nil` means DO NOTHING.
    /// - Parameters:
    ///   - table: the target table
    ///   - cells: the column-id-to-value map to insert
    ///   - updateCells: the values written on conflict, or `nil`
    ///   - returning: whether to echo the row in the result
    /// - Returns: this transaction, for chaining
    @discardableResult
    public func upsert(
        _ table: String,
        cells: [Int: Any],
        updateCells: [Int: Any]?,
        returning: Bool
    ) -> Transaction {
        precondition(!committed, Self.alreadyCommittedMessage)
        var body: [String: Any] = [
            "table": table,
            "cells": MongrelDBClient.flattenCells(cells),
            "returning": returning,
        ]
        if let updateCells {
            body["update_cells"] = MongrelDBClient.flattenCells(updateCells)
        }
        ops.append(["upsert": body])
        return self
    }

    /// Stages a delete by the internal row id.
    /// - Parameters:
    ///   - table: the target table
    ///   - rowId: the internal row id
    /// - Returns: this transaction, for chaining
    @discardableResult
    public func delete(_ table: String, rowId: Int) -> Transaction {
        precondition(!committed, Self.alreadyCommittedMessage)
        ops.append(["delete": ["table": table, "row_id": rowId]])
        return self
    }

    /// Stages a delete by primary-key value.
    /// - Parameters:
    ///   - table: the target table
    ///   - pk: the primary-key value
    /// - Returns: this transaction, for chaining
    @discardableResult
    public func deleteByPk(_ table: String, pk: Any) -> Transaction {
        precondition(!committed, Self.alreadyCommittedMessage)
        ops.append(["delete_by_pk": ["table": table, "pk": pk]])
        return self
    }

    /// The number of staged operations.
    public var count: Int { ops.count }

    /// Sends all staged operations atomically and returns the per-operation
    /// results. `idempotencyKey`, when non-nil and non-empty, makes the commit
    /// safe to retry — the daemon returns the original response on duplicate
    /// commits, even after a crash.
    ///
    /// - Parameter idempotencyKey: an idempotency key, or `nil`
    /// - Returns: the per-operation results, or an empty array if nothing was staged
    /// - Throws: ``ConflictError`` if a constraint violation rolled back the
    ///   batch; a precondition failure if called twice on the same transaction.
    public func commit(idempotencyKey: String? = nil) async throws -> [[String: Any]] {
        precondition(!committed, Self.alreadyCommittedMessage)
        committed = true
        if ops.isEmpty { return [] }
        return try await client.commitTxn(ops, idempotencyKey: idempotencyKey)
    }

    /// Discards all staged operations.
    ///
    /// - Precondition: the transaction has not already been committed or rolled back.
    public func rollback() {
        precondition(!committed, Self.alreadyCommittedMessage)
        ops.removeAll()
        committed = true
    }
}
