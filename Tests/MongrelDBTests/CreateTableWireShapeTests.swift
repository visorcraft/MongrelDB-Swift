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

    /// The full static-default matrix plus `default_expr`, `enum_variants`, and
    /// table checks must reach the daemon byte-for-byte. The engine rejects an
    /// `enum` column without `enum_variants` and silently ignores a
    /// renamed/stripped default.
    func testCreateTableSendsDefaultMatrixVerbatim() async throws {
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
            ["id": 7, "name": "now_literal", "ty": "varchar", "default_value": "now"],
            ["id": 8, "name": "uuid_literal", "ty": "varchar", "default_value": "uuid"],
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
            req.url.path.hasSuffix("/kit/create_table"),
            "expected /kit/create_table, got \(req.url.path)"
        )

        let body = req.body ?? Data()
        let json = try XCTUnwrap(
            try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            "request body is not valid JSON"
        )
        XCTAssertEqual(json["name"] as? String, "orders")

        let statusCol = Self.column(named: "status", in: json)
        XCTAssertNotNil(statusCol)
        XCTAssertTrue(statusCol?["enum_variants"] is [Any], "enum_variants must be an array")
        XCTAssertEqual(statusCol?["default_value"] as? String, "draft")

        XCTAssertEqual(Self.column(named: "retries", in: json)?["default_value"] as? Int, 3)
        XCTAssertEqual(Self.column(named: "enabled", in: json)?["default_value"] as? Bool, true)
        XCTAssertTrue(Self.column(named: "optional", in: json)?["default_value"] is NSNull)

        let createdAt = Self.column(named: "created_at", in: json)
        XCTAssertEqual(createdAt?["default_expr"] as? String, "now")
        XCTAssertNil(createdAt?["default_value"], "default_expr column should not also carry default_value")

        // Literal "now" and "uuid" strings are static defaults, not dynamic
        // expressions, so they travel through default_value.
        XCTAssertEqual(Self.column(named: "now_literal", in: json)?["default_value"] as? String, "now")
        XCTAssertFalse(Self.column(named: "now_literal", in: json)?.keys.contains("default_expr") ?? false)
        XCTAssertEqual(Self.column(named: "uuid_literal", in: json)?["default_value"] as? String, "uuid")
        XCTAssertFalse(Self.column(named: "uuid_literal", in: json)?.keys.contains("default_expr") ?? false)

        let checks = (json["constraints"] as? [String: Any])?["checks"] as? [Any]
        XCTAssertEqual(checks?.count, 1)
        let check = checks?.first as? [String: Any]
        XCTAssertEqual(check?["name"] as? String, "ck_status")
        XCTAssertNotNil((check?["expr"] as? [String: Any])?["IsNotNull"])
    }

    private static func column(named name: String, in json: [String: Any]) -> [String: Any]? {
        guard let columns = json["columns"] as? [[String: Any]] else { return nil }
        return columns.first { $0["name"] as? String == name }
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
