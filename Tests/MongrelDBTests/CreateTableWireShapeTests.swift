import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import MongrelDB

/// Wire-shape conformance tests for ``MongrelDBClient/createTable(_:columns:constraints:)``.
///
/// The client serialises each caller's column dictionary verbatim to JSON; it
/// is a thin pass-through, not a typed DSL. The engine understands a wider set
/// of keys than the Swift client knows about: `enum_variants` (required when
/// `ty: "enum"`) and `default_value` (alias for `default_expr`) are the two
/// most common. A future refactor that filters, renames, or drops user-supplied
/// keys would silently lose schema fidelity - the engine would reject `enum`
/// columns without `enum_variants`, and default expressions would never fire.
///
/// These tests pin the contract by capturing the actual HTTP request body via
/// a `URLProtocol` stub. They run offline; no daemon is required.
final class CreateTableWireShapeTests: XCTestCase {

    // MARK: - URLProtocol stub

    /// `URLProtocol` subclass that records every request URL, method, and body
    /// served by the session it is registered on, and answers with a minimal
    /// valid `create_table` response so the client's decoder path also runs.
    private final class CaptureProtocol: URLProtocol {
        struct CapturedRequest {
            let url: URL
            let method: String?
            let body: Data?
        }

        /// Captures requests across all instances. Guarded by `lock` because
        /// URLProtocol callbacks may fire from URLSession's internal queues.
        static var captured: [CapturedRequest] = []
        private static let lock = NSLock()

        static func reset() {
            lock.lock()
            captured.removeAll()
            lock.unlock()
        }

        private static func record(_ request: URLRequest) {
            let entry = CapturedRequest(
                url: request.url!,
                method: request.httpMethod,
                body: request.httpBody
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
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            let payload = #"{"table_id":1}"#.data(using: .utf8)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: payload)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    // MARK: - Setup

    override func setUp() {
        super.setUp()
        CaptureProtocol.reset()
    }

    /// Builds a client whose `URLSession` is bound to the capture protocol, so
    /// every request the client makes is recorded before the stub answers.
    private func makeClient() -> MongrelDBClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CaptureProtocol.self]
        let session = URLSession(configuration: config)
        return MongrelDBClient(baseURL: "http://127.0.0.1:8453", session: session)
    }

    // MARK: - Tests

    /// When a column carries `enum_variants` and `default_value`, both keys
    /// must reach the daemon byte-for-byte. The engine rejects an `enum` column
    /// without `enum_variants` and silently ignores a renamed/stripped default.
    func testCreateTableSendsEnumVariantsAndDefaultValueVerbatim() async throws {
        let db = makeClient()
        _ = try await db.createTable("orders", columns: [
            [
                "id": 1, "name": "id", "ty": "int64",
                "primary_key": true, "nullable": false,
            ],
            [
                "id": 2, "name": "status", "ty": "enum",
                "enum_variants": ["draft", "open", "closed"],
                "default_value": "draft",
            ],
            ["id": 3, "name": "retries", "ty": "int64", "default_value": 3],
            ["id": 4, "name": "enabled", "ty": "bool", "default_value": true],
            ["id": 5, "name": "optional", "ty": "varchar", "default_value": NSNull()],
            ["id": 6, "name": "created_at", "ty": "timestamp", "default_expr": "now"],
        ], constraints: [
            "checks": [[
                "id": 1,
                "name": "ck_status",
                "expr": ["IsNotNull": 2],
            ]],
        ])

        let captured = CaptureProtocol.captured
        XCTAssertEqual(captured.count, 1, "expected exactly one captured request")
        let req = captured[0]
        XCTAssertEqual(req.method, "POST", "expected POST method")
        XCTAssertTrue(
            req.url?.path.hasSuffix("/kit/create_table") ?? false,
            "expected /kit/create_table, got \(req.url?.path ?? "?")"
        )
        let body = req.body ?? Data()
        let json = String(data: body, encoding: .utf8) ?? ""
        XCTAssertTrue(
            json.contains("\"enum_variants\""),
            "expected enum_variants key in body, got: \(json)"
        )
        XCTAssertTrue(
            json.contains("\"default_value\""),
            "expected default_value key in body, got: \(json)"
        )
        XCTAssertTrue(
            json.contains("\"draft\""),
            "expected default value draft in body, got: \(json)"
        )
        XCTAssertTrue(json.contains("\"default_value\":3"))
        XCTAssertTrue(json.contains("\"default_value\":true"))
        XCTAssertTrue(json.contains("\"default_value\":null"))
        XCTAssertTrue(json.contains("\"default_expr\":\"now\""))
        XCTAssertTrue(json.contains("\"constraints\""), "expected constraints in body: \(json)")
        XCTAssertTrue(json.contains("\"checks\""), "expected checks in body: \(json)")
        XCTAssertTrue(json.contains("\"IsNotNull\""), "expected check expression in body: \(json)")
    }

    /// Regression: columns that do NOT supply `enum_variants` or `default_value`
    /// must not have those keys injected. Key presence vs. absence is what the
    /// engine uses to distinguish "no default" from "default = null".
    func testCreateTableOmitsAbsentEnumVariantsAndDefaultValue() async throws {
        let db = makeClient()
        _ = try await db.createTable("orders", columns: [
            [
                "id": 1, "name": "id", "ty": "int64",
                "primary_key": true, "nullable": false,
            ],
            [
                "id": 2, "name": "score", "ty": "float64",
                "primary_key": false, "nullable": false,
            ],
        ])

        let captured = CaptureProtocol.captured
        XCTAssertEqual(captured.count, 1)
        let json = String(data: captured[0].body ?? Data(), encoding: .utf8) ?? ""
        XCTAssertFalse(
            json.contains("enum_variants"),
            "did not expect enum_variants when not provided, got: \(json)"
        )
        XCTAssertFalse(
            json.contains("default_value"),
            "did not expect default_value when not provided, got: \(json)"
        )
    }
}
