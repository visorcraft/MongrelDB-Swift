import Foundation

/// Builds a request for the daemon's `POST /kit/search` endpoint:
/// multi-retriever hybrid search with reciprocal-rank fusion and optional
/// exact-vector rerank. Wire format matches KitSearchRequest (flattened retrievers).
public final class SearchBuilder {
    private let client: MongrelDBClient
    private let table: String
    private var must: [[String: Any]] = []
    private var retrievers: [[String: Any]] = []
    private var fusion: [String: Any] = ["reciprocal_rank": ["constant": 60]]
    private var rerank: [String: Any]?
    private var limit: Int = 10
    private var projection: [Int]?
    private var explain: Bool = false
    private var cursor: String?

    init(client: MongrelDBClient, table: String) {
        self.client = client
        self.table = table
    }

    /// Hard filter (same condition shapes as `QueryBuilder.where`).
    @discardableResult
    public func `must`(_ type: String, params: [String: Any] = [:]) -> SearchBuilder {
        must.append([type: QueryBuilder.normalizeCondition(condType: type, params: params)])
        return self
    }

    @discardableResult
    public func annRetriever(
        name: String,
        columnId: Int,
        query: [Double],
        k: Int = 64,
        weight: Double = 1.0
    ) -> SearchBuilder {
        retrievers.append([
            "name": name,
            "weight": weight,
            "ann": [
                "column_id": columnId,
                "query": query,
                "k": k,
            ] as [String: Any],
        ])
        return self
    }

    /// `terms` is a list of `[tokenId, weight]` pairs.
    @discardableResult
    public func sparseRetriever(
        name: String,
        columnId: Int,
        terms: [[Double]],
        k: Int = 64,
        weight: Double = 1.0
    ) -> SearchBuilder {
        let pairs: [[Any]] = terms.map { t in [Int(t[0]), t[1]] }
        retrievers.append([
            "name": name,
            "weight": weight,
            "sparse": [
                "column_id": columnId,
                "query": pairs,
                "k": k,
            ] as [String: Any],
        ])
        return self
    }

    @discardableResult
    public func minHashRetriever(
        name: String,
        columnId: Int,
        members: [String],
        k: Int = 64,
        weight: Double = 1.0
    ) -> SearchBuilder {
        retrievers.append([
            "name": name,
            "weight": weight,
            "min_hash": [
                "column_id": columnId,
                "members": members,
                "k": k,
            ] as [String: Any],
        ])
        return self
    }

    @discardableResult
    public func fusion(constant: Int = 60) -> SearchBuilder {
        fusion = ["reciprocal_rank": ["constant": max(1, constant)]]
        return self
    }

    /// `metric` is `cosine`, `dot_product`, or `euclidean`.
    @discardableResult
    public func exactRerank(
        embeddingColumn: Int,
        query: [Double],
        metric: String = "cosine",
        candidateLimit: Int = 64,
        weight: Double = 1.0
    ) -> SearchBuilder {
        rerank = [
            "exact_vector": [
                "embedding_column": embeddingColumn,
                "query": query,
                "metric": metric,
                "candidate_limit": candidateLimit,
                "weight": weight,
            ] as [String: Any],
        ]
        return self
    }

    @discardableResult
    public func limit(_ limit: Int) -> SearchBuilder {
        self.limit = limit
        return self
    }

    @discardableResult
    public func projection(_ columnIds: [Int]) -> SearchBuilder {
        projection = columnIds
        return self
    }

    @discardableResult
    public func explain(_ on: Bool = true) -> SearchBuilder {
        explain = on
        return self
    }

    @discardableResult
    public func cursor(_ cursor: String?) -> SearchBuilder {
        self.cursor = cursor
        return self
    }

    public func build() throws -> [String: Any] {
        guard !retrievers.isEmpty else {
            throw MongrelDBError(message: "search requires at least one retriever")
        }
        guard limit > 0 else {
            throw MongrelDBError(message: "search limit must be positive")
        }
        var payload: [String: Any] = [
            "table": table,
            "retrievers": retrievers,
            "fusion": fusion,
            "limit": limit,
        ]
        if !must.isEmpty { payload["must"] = must }
        if let rerank { payload["rerank"] = rerank }
        if let projection { payload["projection"] = projection }
        if explain { payload["explain"] = true }
        if let cursor, !cursor.isEmpty { payload["cursor"] = cursor }
        return payload
    }

    /// Execute hybrid search. Returns body with `hits` (and optional cursors).
    public func execute() async throws -> [String: Any] {
        let body = try build()
        let data = try await client.post("/kit/search", body)
        if data.isEmpty {
            return ["hits": []]
        }
        let obj = try JSONSerialization.jsonObject(with: data)
        return (obj as? [String: Any]) ?? ["hits": []]
    }
}
