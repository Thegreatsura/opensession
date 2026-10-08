import XCTest
@testable import OS1

/// Both review sheets send through `ReviewSubmitGate`, whether by the Submit
/// button or Cmd+Enter: one request per attempt, never past a disabled Submit.
final class ReviewSubmitGateTests: XCTestCase {
    func testValidSubmissionClaimsTheSend() {
        var gate = ReviewSubmitGate()
        XCTAssertTrue(gate.begin(enabled: true))
        XCTAssertTrue(gate.inFlight)
    }

    func testDisabledSubmitSendsNothing() {
        var gate = ReviewSubmitGate()
        XCTAssertFalse(gate.begin(enabled: false))
        XCTAssertFalse(gate.inFlight)
    }

    func testRepeatedChordWhileInFlightSendsOnce() {
        var gate = ReviewSubmitGate()
        XCTAssertTrue(gate.begin(enabled: true))
        XCTAssertFalse(gate.begin(enabled: true), "a second Cmd+Enter while posting sends nothing")
        XCTAssertFalse(gate.begin(enabled: true))
        XCTAssertTrue(gate.inFlight)
    }

    func testFailureReopensTheGate() {
        var gate = ReviewSubmitGate()
        XCTAssertTrue(gate.begin(enabled: true))
        gate.finish()
        XCTAssertFalse(gate.inFlight)
        XCTAssertTrue(gate.begin(enabled: true), "a failed review can be retried")
    }

    func testCompositionHoldsTheChord() {
        var gate = ReviewSubmitGate()
        XCTAssertFalse(gate.begin(enabled: true, composing: true))
        XCTAssertFalse(gate.inFlight)
    }

    func testApprovalNeedsNoSummary() {
        XCTAssertTrue(ReviewSubmitGate.summaryAllows(event: "APPROVE", summary: ""))
        XCTAssertTrue(ReviewSubmitGate.summaryAllows(event: "APPROVE", summary: "LGTM"))
    }

    func testCommentAndChangeRequestNeedABody() {
        for event in ["COMMENT", "REQUEST_CHANGES"] {
            XCTAssertFalse(ReviewSubmitGate.summaryAllows(event: event, summary: ""))
            XCTAssertFalse(ReviewSubmitGate.summaryAllows(event: event, summary: " \n\t"))
            XCTAssertTrue(ReviewSubmitGate.summaryAllows(event: event, summary: "Needs a test"))
        }
    }
}
