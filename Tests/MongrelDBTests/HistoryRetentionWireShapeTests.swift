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
            let payload = #"{"history_retention_epochs":1024,"earliest_retained_epoch":7}"#.data(using: .utf8)!
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

        let contentType = req.value(forHTTPHeaderField: "Content-Type")
        XCTAssertEqual(contentType, "application/json")
    }
}
