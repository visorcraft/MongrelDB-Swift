import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import MongrelDB

/// Offline unit tests for durable HLC recovery, `retrieve_text`, and multi-retriever search (0.64+).
final class DurableRetrieveTests: XCTestCase {

    // MARK: - QueryStatus / CommitHlc structural decode

    /// Fixture mirrors mongreldb-server GET /queries/{id} (0.64+).
    private static let queryStatusFixture: [String: Any] = {
        let hlc: [String: Any] = [
            "physical_micros": 1_700_000_000_000_000,
            "logical": 3,
            "node_tiebreaker": 7,
        ]
        let outcome: [String: Any] = [
            "committed": true,
            "committed_statements": 1,
            "last_commit_epoch": 17,
            "last_commit_epoch_text": "17",
            "last_commit_hlc": hlc,
            "first_commit_statement_index": 0,
            "last_commit_statement_index": 0,
            "completed_statements": 1,
            "statement_index": 0,
            "serialization": "succeeded",
            "serialization_state": "succeeded",
            "terminal_state": "committed",
        ]
        return [
            "query_id": "abcdefabcdefabcdefabcdefabcdefab",
            "status": "committed",
            "state": "completed",
            "server_state": "completed",
            "terminal_state": "committed",
            "operation": "INSERT",
            "committed": true,
            "committed_statements": 1,
            "last_commit_epoch": 17,
            "last_commit_epoch_text": "17",
            "last_commit_hlc": hlc,
            "first_commit_statement_index": 0,
            "last_commit_statement_index": 0,
            "completed_statements": 1,
            "statement_index": 0,
            "cancel_outcome": NSNull(),
            "cancellation_reason": "none",
            "retryable": false,
            "outcome": outcome,
            "durable": outcome,
            "terminal_error": NSNull(),
        ]
    }()

    func testQueryStatusParsesStructuralHlcWithoutStringParsing() {
        let status = QueryStatus.fromJSON(Self.queryStatusFixture)
        XCTAssertEqual(status.committed, true)
        XCTAssertEqual(status.queryId, "abcdefabcdefabcdefabcdefabcdefab")
        XCTAssertEqual(status.status, "committed")

        let hlc = status.commitHlc()
        XCTAssertNotNil(hlc)
        XCTAssertEqual(hlc?.physicalMicros, 1_700_000_000_000_000)
        XCTAssertEqual(hlc?.logical, 3)
        XCTAssertEqual(hlc?.nodeTiebreaker, 7)
        XCTAssertEqual(status.serializationState(), "succeeded")
        // Structural access — no string-parsing of free-form status text.
        XCTAssertEqual(status.outcome.lastCommitEpoch, 17)
        XCTAssertEqual(status.durable?.lastCommitHlc?.physicalMicros, 1_700_000_000_000_000)
    }

    func testQueryStatusPrefersNestedDurableHlc() {
        var fixture = Self.queryStatusFixture
        fixture["last_commit_hlc"] = [
            "physical_micros": 1,
            "logical": 0,
            "node_tiebreaker": 0,
        ] as [String: Any]
        let durableHlc: [String: Any] = [
            "physical_micros": 99,
            "logical": 1,
            "node_tiebreaker": 2,
        ]
        var durable = (fixture["durable"] as? [String: Any]) ?? [:]
        durable["last_commit_hlc"] = durableHlc
        fixture["durable"] = durable

        let status = QueryStatus.fromJSON(fixture)
        XCTAssertEqual(status.commitHlc()?.physicalMicros, 99)
        XCTAssertEqual(status.commitHlc()?.logical, 1)
        XCTAssertEqual(status.commitHlc()?.nodeTiebreaker, 2)
    }

    func testQueryStatusParseJSONRoundTrip() throws {
        let data = try JSONSerialization.data(
            withJSONObject: Self.queryStatusFixture,
            options: []
        )
        let status = try QueryStatus.parseJSON(data)
        XCTAssertEqual(status.serializationState(), "succeeded")
        XCTAssertEqual(status.commitHlc()?.physicalMicros, 1_700_000_000_000_000)
    }

    // MARK: - Multi-retriever SearchBuilder

    func testMultiRetrieverSearchBuildIncludesTwoRetrieversAndFusion() throws {
        let client = MongrelDBClient(baseURL: "http://127.0.0.1:9")
        let payload = try client.search("docs")
            .annRetriever(name: "ann", columnId: 3, query: [0.1, 0.2], k: 10, weight: 1.0)
            .sparseRetriever(name: "sparse", columnId: 4, terms: [[1, 0.5]], k: 10, weight: 0.5)
            .fusion(constant: 60)
            .limit(5)
            .build()
        let retrievers = try XCTUnwrap(payload["retrievers"] as? [[String: Any]])
        XCTAssertEqual(retrievers.count, 2)
        XCTAssertNotNil(payload["fusion"])
        XCTAssertEqual(payload["table"] as? String, "docs")
        XCTAssertEqual(payload["limit"] as? Int, 5)
    }

    // MARK: - retrieveText / queryStatus / cancelQuery wire shape

    private final class CaptureProtocol: URLProtocol {
        struct CapturedRequest {
            let url: URL
            let method: String?
            let body: Data?
        }

        static var captured: [CapturedRequest] = []
        static var responseBody: Data = Data()
        static var statusCode: Int = 200
        private static let lock = NSLock()

        static func reset() {
            lock.lock()
            captured.removeAll()
            responseBody = Data()
            statusCode = 200
            lock.unlock()
        }

        static func setResponseJSON(_ obj: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: obj, options: [])
            lock.lock()
            responseBody = data
            lock.unlock()
        }

        private static func record(_ request: URLRequest) {
            // URLSession may put the body in httpBodyStream rather than httpBody.
            var body = request.httpBody
            if body == nil, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var data = Data()
                let bufSize = 1024
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
                defer { buffer.deallocate() }
                while stream.hasBytesAvailable {
                    let n = stream.read(buffer, maxLength: bufSize)
                    if n > 0 {
                        data.append(buffer, count: n)
                    } else {
                        break
                    }
                }
                body = data
            }
            let entry = CapturedRequest(
                url: request.url!,
                method: request.httpMethod,
                body: body
            )
            lock.lock()
            captured.append(entry)
            lock.unlock()
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.record(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: Self.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.responseBody)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func makeClient() -> MongrelDBClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CaptureProtocol.self]
        let session = URLSession(configuration: config)
        return MongrelDBClient(baseURL: "http://127.0.0.1:8453", session: session)
    }

    override func setUp() {
        super.setUp()
        CaptureProtocol.reset()
    }

    func testRetrieveTextPostsKitEndpoint() async throws {
        try CaptureProtocol.setResponseJSON([
            "hits": [["row_id": 1]],
            "provenance": ["model": "test"],
        ])
        let db = makeClient()
        let result = try await db.retrieveText(
            "docs",
            embeddingColumn: 3,
            text: "cat sat",
            k: 5
        )
        let hits = try XCTUnwrap(result["hits"] as? [[String: Any]])
        XCTAssertEqual(hits.count, 1)

        let captured = CaptureProtocol.captured
        XCTAssertEqual(captured.count, 1)
        let req = captured[0]
        XCTAssertEqual(req.method, "POST")
        XCTAssertTrue(
            req.url.path.hasSuffix("/kit/retrieve_text"),
            "expected /kit/retrieve_text, got \(req.url.path)"
        )
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: req.body ?? Data()) as? [String: Any]
        )
        XCTAssertEqual(json["table"] as? String, "docs")
        XCTAssertEqual(json["embedding_column"] as? Int, 3)
        XCTAssertEqual(json["text"] as? String, "cat sat")
        XCTAssertEqual(json["k"] as? Int, 5)
    }

    func testQueryStatusGetAndCancelQueryPost() async throws {
        try CaptureProtocol.setResponseJSON(Self.queryStatusFixture)
        let db = makeClient()
        let status = try await db.queryStatus("abcdefabcdefabcdefabcdefabcdefab")
        XCTAssertEqual(status.commitHlc()?.logical, 3)

        XCTAssertEqual(CaptureProtocol.captured.count, 1)
        XCTAssertEqual(CaptureProtocol.captured[0].method, "GET")
        XCTAssertTrue(
            CaptureProtocol.captured[0].url.path.contains("/queries/"),
            CaptureProtocol.captured[0].url.path
        )

        CaptureProtocol.reset()
        try CaptureProtocol.setResponseJSON(["status": "cancel_requested"])
        let cancel = try await db.cancelQuery("abcdefabcdefabcdefabcdefabcdefab")
        XCTAssertEqual(cancel["status"] as? String, "cancel_requested")
        XCTAssertEqual(CaptureProtocol.captured.count, 1)
        XCTAssertEqual(CaptureProtocol.captured[0].method, "POST")
        XCTAssertTrue(
            CaptureProtocol.captured[0].url.path.hasSuffix("/cancel"),
            CaptureProtocol.captured[0].url.path
        )
    }

    func testVersionIs0640() {
        XCTAssertEqual(MongrelDBVersion.string, "0.64.2")
    }
}
