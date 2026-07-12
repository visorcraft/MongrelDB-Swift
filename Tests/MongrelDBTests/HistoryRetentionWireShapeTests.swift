import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import MongrelDB

/// Wire-shape conformance tests for the history-retention endpoints.
///
/// These tests run offline via a `URLProtocol` stub that records the exact
/// request method, path, and body the client sends. They pin the contract
/// that `historyRetentionEpochs()` issues a GET, `setHistoryRetentionEpochs(_:)`
/// issues a PUT with the new value, and `earliestRetainedEpoch()` issues a GET.
final class HistoryRetentionWireShapeTests: XCTestCase {

    // MARK: - URLProtocol stub

    private final class CaptureProtocol: URLProtocol {
        struct CapturedRequest {
            let url: URL
            let method: String?
            let body: Data?
        }

        static var captured: [CapturedRequest] = []
        // Configurable response so error-propagation tests can drive non-2xx
        // paths. Reset to the 200 defaults in setUp().
        static var statusCode: Int = 200
        static var body: Data = #"{"history_retention_epochs":1024,"earliest_retained_epoch":7}"#
            .data(using: .utf8)!
        private static let lock = NSLock()

        static func reset() {
            lock.lock()
            captured.removeAll()
            statusCode = 200
            body = #"{"history_retention_epochs":1024,"earliest_retained_epoch":7}"#
                .data(using: .utf8)!
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
                statusCode: Self.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    // MARK: - Setup

    override func setUp() {
        super.setUp()
        CaptureProtocol.reset()
    }

    private func makeClient() -> MongrelDBClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CaptureProtocol.self]
        let session = URLSession(configuration: config)
        return MongrelDBClient(baseURL: "http://127.0.0.1:8453", session: session)
    }

    // MARK: - Tests

    func testHistoryRetentionEpochsSendsGet() async throws {
        let db = makeClient()
        let epochs = try await db.historyRetentionEpochs()
        XCTAssertEqual(epochs, 1024)

        let captured = CaptureProtocol.captured
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured[0].method, "GET")
        XCTAssertTrue(captured[0].url.path.hasSuffix("/history/retention"))
    }

    func testEarliestRetainedEpochSendsGet() async throws {
        let db = makeClient()
        let epoch = try await db.earliestRetainedEpoch()
        XCTAssertEqual(epoch, 7)

        let captured = CaptureProtocol.captured
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured[0].method, "GET")
        XCTAssertTrue(captured[0].url.path.hasSuffix("/history/retention"))
    }

    func testSetHistoryRetentionEpochsSendsPut() async throws {
        let db = makeClient()
        let response = try await db.setHistoryRetentionEpochs(2048)
        XCTAssertEqual(response["history_retention_epochs"] as? Int, 1024)
        XCTAssertEqual(response["earliest_retained_epoch"] as? Int, 7)

        let captured = CaptureProtocol.captured
        XCTAssertEqual(captured.count, 1)
        let req = captured[0]
        XCTAssertEqual(req.method, "PUT")
        XCTAssertTrue(req.url.path.hasSuffix("/history/retention"))

        let body = req.body ?? Data()
        let json = try XCTUnwrap(
            try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(json["history_retention_epochs"] as? Int, 2048)

        // The PUT body must carry only the new window size; the read-only
        // earliest_retained_epoch field must never be echoed back to the server.
        XCTAssertNil(json["earliest_retained_epoch"])
        XCTAssertFalse(body.range(of: "earliest_retained_epoch") != nil,
                       "PUT body must not contain earliest_retained_epoch")

        let contentType = req.value(forHTTPHeaderField: "Content-Type")
        XCTAssertEqual(contentType, "application/json")
    }

    // MARK: - Error propagation

    func testNon2xx500MapsToQueryError() async throws {
        CaptureProtocol.statusCode = 500
        CaptureProtocol.body = #"{"error":{"message":"boom","code":"INTERNAL"}}"#.data(using: .utf8)!

        let db = makeClient()
        do {
            _ = try await db.historyRetentionEpochs()
            XCTFail("expected a QueryError for status 500")
        } catch let error as QueryError {
            XCTAssertEqual(error.status, 500, "QueryError should carry status 500")
            XCTAssertEqual(error.code, "INTERNAL", "QueryError should surface the server code")
        } catch {
            XCTFail("expected QueryError for 500, got \(type(of: error))")
        }

        // The failed request must still have been captured so callers can audit
        // the exact method/path even on the error path.
        let captured = CaptureProtocol.captured
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured[0].method, "GET")
    }

    func testNon2xx404MapsToNotFoundError() async throws {
        CaptureProtocol.statusCode = 404
        CaptureProtocol.body = #"{"error":{"message":"missing","code":"NOT_FOUND"}}"#.data(using: .utf8)!

        let db = makeClient()
        do {
            _ = try await db.setHistoryRetentionEpochs(2048)
            XCTFail("expected a NotFoundError for status 404")
        } catch let error as NotFoundError {
            XCTAssertEqual(error.status, 404, "NotFoundError should carry status 404")
            XCTAssertEqual(error.code, "NOT_FOUND", "NotFoundError should surface the server code")
        } catch {
            XCTFail("expected NotFoundError for 404, got \(type(of: error))")
        }

        // A 404 on the PUT path must still issue a PUT to the right endpoint.
        let captured = CaptureProtocol.captured
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured[0].method, "PUT")
        XCTAssertTrue(captured[0].url.path.hasSuffix("/history/retention"))
    }
}
