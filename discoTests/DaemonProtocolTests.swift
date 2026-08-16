import Foundation
import XCTest
@testable import disco

@MainActor
final class DaemonProtocolTests: XCTestCase {
    func testEventRoutingReadsSnakeCaseSessionAndRunIDs() throws {
        let sessionID = UUID()
        let runID = UUID()
        let data = try JSONSerialization.data(withJSONObject: [
            "event": "message.delta",
            "data": [
                "session_id": sessionID.uuidString,
                "run_id": runID.uuidString,
                "delta": "hello",
            ],
        ])
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let envelope = try decoder.decode(DaemonEventEnvelope.self, from: data)
        let event = DaemonEvent(eventName: envelope.event, data: envelope.data)

        XCTAssertEqual(event.sessionID, sessionID)
        XCTAssertEqual(event.runID, runID)
    }

    func testSessionCreateResponseDecodesItsResultWrapper() throws {
        let sessionID = UUID()
        let projectID = UUID()
        let data = try JSONSerialization.data(withJSONObject: [
            "session": [
                "id": sessionID.uuidString,
                "project_id": projectID.uuidString,
                "provider_id": "deepseek_api",
                "vendor": "deepseek",
                "model": "deepseek-chat",
                "created_at": "2026-08-16T12:00:00Z",
                "updated_at": "2026-08-16T12:00:00Z",
            ],
        ])
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let result = try decoder.decode(DaemonSessionCreateResult.self, from: data)

        XCTAssertEqual(result.session.id, sessionID.uuidString)
        XCTAssertEqual(result.session.projectId, projectID.uuidString)
        XCTAssertEqual(result.session.providerId, "deepseek_api")
    }
}
