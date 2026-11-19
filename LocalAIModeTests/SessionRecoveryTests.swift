import XCTest
@testable import Local_AI_Mode

final class SessionRecoveryTests: XCTestCase {
    var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("LAIMTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    func testCleanWhenNoJournal() {
        XCTAssertEqual(RecoveryAssessment.assess(store: SessionStore(directory: dir)), .clean)
    }

    func testInterruptedSessionDetectedByNewStoreInstance() throws {
        let snap = SnapshotSerializationTests.sampleSnapshot()
        try SessionStore(directory: dir).beginSession(snapshot: snap, model: "m")
        // Simulate relaunch: a brand-new store reading the same directory.
        let relaunched = SessionStore(directory: dir)
        guard case .interrupted(let journal) = RecoveryAssessment.assess(store: relaunched) else {
            return XCTFail("Expected interrupted session")
        }
        XCTAssertEqual(journal.snapshot.id, snap.id)
        XCTAssertEqual(journal.phase, .activating)
    }

    func testBeginSessionRefusesToOverwriteSnapshot() throws {
        let store = SessionStore(directory: dir)
        let first = SnapshotSerializationTests.sampleSnapshot()
        try store.beginSession(snapshot: first, model: nil)
        XCTAssertThrowsError(try store.beginSession(snapshot: SnapshotSerializationTests.sampleSnapshot(), model: nil)) { error in
            XCTAssertEqual(error as? SessionStoreError, .sessionAlreadyActive)
        }
        XCTAssertEqual(store.loadJournal()?.snapshot.id, first.id)
    }

    func testUpdatePersistsPhaseAndClosedFlags() throws {
        let store = SessionStore(directory: dir)
        try store.beginSession(snapshot: SnapshotSerializationTests.sampleSnapshot(), model: nil)
        try store.update { j in
            j.phase = .active
            j.snapshot.applications[0].wasClosedByAIMode = true
        }
        let j = try XCTUnwrap(SessionStore(directory: dir).loadJournal())
        XCTAssertEqual(j.phase, .active)
        XCTAssertTrue(j.snapshot.applications[0].wasClosedByAIMode)
    }

    func testRestorePendingIsDistinguished() throws {
        let store = SessionStore(directory: dir)
        try store.beginSession(snapshot: SnapshotSerializationTests.sampleSnapshot(), model: nil)
        try store.update { $0.phase = .restorePending }
        guard case .restorePending = RecoveryAssessment.assess(store: store) else { return XCTFail() }
    }

    func testEndSessionKeepsLastSnapshotForEmergencyRestore() throws {
        let store = SessionStore(directory: dir)
        let snap = SnapshotSerializationTests.sampleSnapshot()
        try store.beginSession(snapshot: snap, model: nil)
        store.endSession()
        XCTAssertNil(store.loadJournal())
        XCTAssertEqual(store.loadLastSnapshot()?.id, snap.id)
        XCTAssertEqual(RecoveryAssessment.assess(store: store), .clean)
    }

    func testCorruptJournalDetectedAndQuarantined() throws {
        let store = SessionStore(directory: dir)
        try Data("{not json".utf8).write(to: store.journalURL)
        XCTAssertEqual(RecoveryAssessment.assess(store: store), .corrupt)
        store.quarantineCorruptJournal()
        XCTAssertEqual(RecoveryAssessment.assess(store: store), .clean)
    }

    func testUpdateWithoutSessionThrows() {
        XCTAssertThrowsError(try SessionStore(directory: dir).update { $0.phase = .active })
    }
}
