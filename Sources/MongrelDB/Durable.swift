import Foundation

// MARK: - CommitHlc

/// Structural hybrid logical clock from durable recovery (0.64+).
///
/// Wire fields: `physical_micros`, `logical`, `node_tiebreaker`.
public struct CommitHlc: Equatable, Sendable {
    public let physicalMicros: UInt64
    public let logical: UInt32
    public let nodeTiebreaker: UInt32

    public init(physicalMicros: UInt64, logical: UInt32 = 0, nodeTiebreaker: UInt32 = 0) {
        self.physicalMicros = physicalMicros
        self.logical = logical
        self.nodeTiebreaker = nodeTiebreaker
    }

    /// Parses a `last_commit_hlc` JSON object. Returns `nil` when `physical_micros` is absent.
    public static func fromJSON(_ raw: Any?) -> CommitHlc? {
        guard let obj = raw as? [String: Any],
              let physical = MongrelDBClient.asUInt64(obj["physical_micros"]) else {
            return nil
        }
        let logical = Self.asUInt32(obj["logical"]) ?? 0
        let tie = Self.asUInt32(obj["node_tiebreaker"]) ?? 0
        return CommitHlc(physicalMicros: physical, logical: logical, nodeTiebreaker: tie)
    }

    private static func asUInt32(_ v: Any?) -> UInt32? {
        switch v {
        case let n as NSNumber: return n.uint32Value
        case let i as UInt32: return i
        case let i as Int where i >= 0 && i <= Int(UInt32.max): return UInt32(i)
        case let s as String: return UInt32(s)
        default: return nil
        }
    }
}

// MARK: - DurableOutcome

/// Nested durable recovery payload on query status/cancel responses
/// (parity with the server `DurableOutcome` / `outcome` JSON object).
public struct DurableOutcome: Equatable, Sendable {
    public let committed: Bool?
    public let committedStatements: Int?
    public let lastCommitEpoch: UInt64?
    public let lastCommitEpochText: String?
    public let lastCommitHlc: CommitHlc?
    public let firstCommitStatementIndex: Int?
    public let lastCommitStatementIndex: Int?
    public let completedStatements: Int?
    public let statementIndex: Int?
    public let serialization: String
    public let serializationState: String?
    public let terminalState: String?

    public init(
        committed: Bool? = nil,
        committedStatements: Int? = nil,
        lastCommitEpoch: UInt64? = nil,
        lastCommitEpochText: String? = nil,
        lastCommitHlc: CommitHlc? = nil,
        firstCommitStatementIndex: Int? = nil,
        lastCommitStatementIndex: Int? = nil,
        completedStatements: Int? = nil,
        statementIndex: Int? = nil,
        serialization: String = "",
        serializationState: String? = nil,
        terminalState: String? = nil
    ) {
        self.committed = committed
        self.committedStatements = committedStatements
        self.lastCommitEpoch = lastCommitEpoch
        self.lastCommitEpochText = lastCommitEpochText
        self.lastCommitHlc = lastCommitHlc
        self.firstCommitStatementIndex = firstCommitStatementIndex
        self.lastCommitStatementIndex = lastCommitStatementIndex
        self.completedStatements = completedStatements
        self.statementIndex = statementIndex
        self.serialization = serialization
        self.serializationState = serializationState
        self.terminalState = terminalState
    }

    /// Parses an `outcome` / `durable` JSON object (empty when `raw` is not a dictionary).
    public static func fromJSON(_ raw: Any?) -> DurableOutcome {
        guard let obj = raw as? [String: Any] else {
            return DurableOutcome()
        }
        let committed: Bool?
        if obj.keys.contains("committed") {
            if obj["committed"] is NSNull {
                committed = nil
            } else {
                committed = obj["committed"] as? Bool
            }
        } else {
            committed = nil
        }
        return DurableOutcome(
            committed: committed,
            committedStatements: MongrelDBClient.asInt(obj["committed_statements"]),
            lastCommitEpoch: MongrelDBClient.asUInt64(obj["last_commit_epoch"]),
            lastCommitEpochText: obj["last_commit_epoch_text"] as? String,
            lastCommitHlc: CommitHlc.fromJSON(obj["last_commit_hlc"]),
            firstCommitStatementIndex: MongrelDBClient.asInt(obj["first_commit_statement_index"]),
            lastCommitStatementIndex: MongrelDBClient.asInt(obj["last_commit_statement_index"]),
            completedStatements: MongrelDBClient.asInt(obj["completed_statements"]),
            statementIndex: MongrelDBClient.asInt(obj["statement_index"]),
            serialization: (obj["serialization"] as? String) ?? "",
            serializationState: obj["serialization_state"] as? String,
            terminalState: obj["terminal_state"] as? String
        )
    }
}

// MARK: - QueryStatus

/// Decoded `GET /queries/{query_id}` body for SQL control / durable recovery (0.64+).
///
/// Not `Sendable` because ``raw`` retains the untyped JSON object (`[String: Any]`).
public struct QueryStatus: Equatable {
    public let queryId: String
    public let status: String
    public let state: String
    public let serverState: String
    public let terminalState: String?
    public let committed: Bool?
    public let outcome: DurableOutcome
    public let durable: DurableOutcome?
    public let lastCommitHlc: CommitHlc?
    /// Original JSON object (untyped extras such as `terminal_error` / `trace`).
    public let raw: [String: Any]

    public init(
        queryId: String,
        status: String,
        state: String,
        serverState: String,
        terminalState: String?,
        committed: Bool?,
        outcome: DurableOutcome,
        durable: DurableOutcome?,
        lastCommitHlc: CommitHlc?,
        raw: [String: Any]
    ) {
        self.queryId = queryId
        self.status = status
        self.state = state
        self.serverState = serverState
        self.terminalState = terminalState
        self.committed = committed
        self.outcome = outcome
        self.durable = durable
        self.lastCommitHlc = lastCommitHlc
        self.raw = raw
    }

    /// Parses a query-status JSON object. Structural access only — no free-form status text.
    public static func fromJSON(_ raw: [String: Any]) -> QueryStatus {
        let outcome = DurableOutcome.fromJSON(raw["outcome"])
        let durable: DurableOutcome?
        if raw["durable"] is [String: Any] {
            durable = DurableOutcome.fromJSON(raw["durable"])
        } else {
            durable = nil
        }
        let topHlc = CommitHlc.fromJSON(raw["last_commit_hlc"])
        let committed: Bool?
        if raw.keys.contains("committed") {
            if raw["committed"] is NSNull {
                committed = nil
            } else {
                committed = raw["committed"] as? Bool
            }
        } else {
            committed = nil
        }
        let state = (raw["state"] as? String) ?? ""
        let serverState = (raw["server_state"] as? String) ?? state
        return QueryStatus(
            queryId: (raw["query_id"] as? String) ?? "",
            status: (raw["status"] as? String) ?? "",
            state: state,
            serverState: serverState,
            terminalState: raw["terminal_state"] as? String,
            committed: committed,
            outcome: outcome,
            durable: durable,
            lastCommitHlc: topHlc,
            raw: raw
        )
    }

    /// Decodes a raw response body into ``QueryStatus``.
    public static func parseJSON(_ data: Data) throws -> QueryStatus {
        let parsed = try JSON.decode(data)
        guard let obj = parsed as? [String: Any] else {
            throw QueryError("mongreldb: decode query status: unexpected JSON")
        }
        return fromJSON(obj)
    }

    /// Authoritative HLC: nested `durable` → `outcome` → top-level `last_commit_hlc`.
    public func commitHlc() -> CommitHlc? {
        if let hlc = durable?.lastCommitHlc { return hlc }
        if let hlc = outcome.lastCommitHlc { return hlc }
        return lastCommitHlc
    }

    /// Prefers nested durable/outcome `serialization_state`, then `serialization`.
    public func serializationState() -> String {
        if let d = durable {
            if let s = d.serializationState, !s.isEmpty { return s }
            if !d.serialization.isEmpty { return d.serialization }
        }
        if let s = outcome.serializationState, !s.isEmpty { return s }
        return outcome.serialization
    }

    public static func == (lhs: QueryStatus, rhs: QueryStatus) -> Bool {
        lhs.queryId == rhs.queryId
            && lhs.status == rhs.status
            && lhs.state == rhs.state
            && lhs.serverState == rhs.serverState
            && lhs.terminalState == rhs.terminalState
            && lhs.committed == rhs.committed
            && lhs.outcome == rhs.outcome
            && lhs.durable == rhs.durable
            && lhs.lastCommitHlc == rhs.lastCommitHlc
    }
}
