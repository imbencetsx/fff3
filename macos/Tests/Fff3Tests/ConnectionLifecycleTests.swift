import XCTest
@testable import Fff3

final class ConnectionLifecycleTests: XCTestCase {
    func testRetryMustWaitForCancellationCallback() throws {
        var state = ConnectionLifecycle()
        let token = try XCTUnwrap(state.begin())
        XCTAssertTrue(state.cancel(generation: token))
        XCTAssertNil(state.begin(), "A retry must not overlap the still-pending CoreBluetooth cancellation")
        XCTAssertTrue(state.disconnected())
        XCTAssertNotNil(state.begin())
    }

    func testOldConnectionTimerCannotCancelAReadyOrNewConnection() throws {
        var state = ConnectionLifecycle()
        let old = try XCTUnwrap(state.begin())
        XCTAssertTrue(state.connected())
        XCTAssertTrue(state.ready())
        XCTAssertFalse(state.cancel(generation: old))
        XCTAssertTrue(state.disconnected())
        let new = try XCTUnwrap(state.begin())
        XCTAssertNotEqual(old, new)
        XCTAssertFalse(state.cancel(generation: old))
        XCTAssertTrue(state.connected())
        XCTAssertTrue(state.ready())
    }

    func testDuplicateDropCannotScheduleDuplicateRetries() throws {
        var state = ConnectionLifecycle()
        _ = try XCTUnwrap(state.begin())
        XCTAssertTrue(state.disconnected())
        XCTAssertFalse(state.disconnected())
        _ = try XCTUnwrap(state.begin())
        XCTAssertTrue(state.connected())
        XCTAssertTrue(state.ready())
        XCTAssertNil(state.begin())
    }

    func testBluetoothOffAndCloseInvalidatePendingWork() throws {
        var state = ConnectionLifecycle()
        let token = try XCTUnwrap(state.begin())
        state.suspend()
        XCTAssertFalse(state.cancel(generation: token))
        XCTAssertFalse(state.disconnected())
        _ = try XCTUnwrap(state.begin())
        state.close()
        XCTAssertNil(state.begin())
        XCTAssertFalse(state.connected())
    }

    func testOldWriteTimeoutCannotConsumeTheNextAcknowledgement() {
        var acknowledgements = WriteAcknowledgementToken()
        let old = acknowledgements.begin()
        XCTAssertTrue(acknowledgements.complete(old))
        let current = acknowledgements.begin()
        XCTAssertFalse(acknowledgements.complete(old))
        XCTAssertEqual(acknowledgements.pending, current)
        XCTAssertTrue(acknowledgements.complete(current))
    }
}
