import CloudKit
import Foundation
import XCTest
@testable import Moves

final class SyncDiagnosticsTests: XCTestCase {
    func testCocoa134419IsARecognizedRetryableSystemDeferral() {
        let error = NSError(domain: NSCocoaErrorDomain, code: 134419)

        let details = MovesSyncDiagnostics.errorDetails(for: error, stage: .cloudKitExport)

        XCTAssertEqual(details.disposition, .retryable)
        XCTAssertEqual(
            details.message,
            "Synchronization was postponed by the system. Pending changes may not have uploaded yet."
        )
    }

    func testSuccessfulExportSupersedesPriorDeferredFailures() {
        let firstDeferral = event(.cloudKitExport, started: 10, ended: 20, succeeded: false, hasError: true)
        let secondDeferral = event(.cloudKitExport, started: 30, ended: 40, succeeded: false, hasError: true)
        let success = event(.cloudKitExport, started: 50, ended: 60, succeeded: true, hasError: false)
        let events = [firstDeferral, secondDeferral, success]

        XCTAssertNil(MovesSyncDiagnostics.activeError(in: events))
        XCTAssertEqual(MovesSyncDiagnostics.consecutiveFailureCount(in: events, for: .cloudKitExport), 0)
        XCTAssertEqual(success.endedAt, Date(timeIntervalSince1970: 60))
    }

    func testRepeatedDeferralsRemainVisibleUntilLaterSuccess() {
        let firstDeferral = event(.cloudKitExport, started: 10, ended: 20, succeeded: false, hasError: true)
        let secondDeferral = event(.cloudKitExport, started: 30, ended: 40, succeeded: false, hasError: true)
        let events = [firstDeferral, secondDeferral]

        XCTAssertEqual(MovesSyncDiagnostics.activeError(in: events)?.id, secondDeferral.id)
        XCTAssertEqual(MovesSyncDiagnostics.consecutiveFailureCount(in: events, for: .cloudKitExport), 2)
    }

    func testUnknownSynchronizationStateHasNoInventedError() {
        XCTAssertNil(MovesSyncDiagnostics.activeError(in: []))
        XCTAssertEqual(MovesSyncDiagnostics.consecutiveFailureCount(in: [], for: .cloudKitImport), 0)
    }

    private func event(
        _ stage: MovesSyncDiagnostics.Stage,
        started: TimeInterval,
        ended: TimeInterval,
        succeeded: Bool,
        hasError: Bool
    ) -> MovesSyncDiagnostics.Event {
        MovesSyncDiagnostics.Event(
            id: UUID(),
            stage: stage,
            startedAt: Date(timeIntervalSince1970: started),
            endedAt: Date(timeIntervalSince1970: ended),
            succeeded: succeeded,
            errorSummary: hasError ? "deferred" : nil,
            placeCount: nil,
            moveCount: nil,
            newestCreatedAt: nil,
            errorDetails: hasError ? MovesSyncDiagnostics.ErrorDetails(
                stage: stage,
                disposition: .retryable,
                domain: NSCocoaErrorDomain,
                code: 134419,
                message: "deferred",
                recoverySuggestion: nil,
                occurredAt: Date(timeIntervalSince1970: ended)
            ) : nil
        )
    }
}
