import XCTest
@testable import Local_AI_Mode

final class ModeStateMachineTests: XCTestCase {
    func testFullActivationAndDeactivationCycle() {
        var m = ModeStateMachine()
        XCTAssertTrue(m.handle(.requestActivation))
        XCTAssertEqual(m.state, .awaitingConfirmation)
        XCTAssertTrue(m.handle(.confirm))
        XCTAssertEqual(m.state, .activating(.savingSnapshot))
        for step in [ActivationStep.closingApps, .optimizingPerformance, .startingOllama, .loadingModel, .verifying] {
            XCTAssertTrue(m.handle(.activationStep(step)))
            XCTAssertEqual(m.state, .activating(step))
        }
        XCTAssertTrue(m.handle(.activationFinished))
        XCTAssertEqual(m.state, .active)
        XCTAssertTrue(m.handle(.requestDeactivation))
        XCTAssertTrue(m.handle(.deactivationStep(.restoringApps)))
        XCTAssertTrue(m.handle(.deactivationFinished))
        XCTAssertEqual(m.state, .normal)
    }

    func testRequestsDuringTransitionAreRejected() {
        var m = ModeStateMachine()
        m.handle(.requestActivation); m.handle(.confirm)
        XCTAssertFalse(m.handle(.requestActivation))
        XCTAssertFalse(m.handle(.requestDeactivation))
        XCTAssertEqual(m.state, .activating(.savingSnapshot))

        var d = ModeStateMachine(state: .active)
        d.handle(.requestDeactivation)
        XCTAssertFalse(d.handle(.requestDeactivation))
        XCTAssertFalse(d.handle(.requestActivation))
        XCTAssertEqual(d.state, .deactivating(.unloadingModels))
    }

    func testCannotDeactivateFromNormalOrActivateWhenActive() {
        var m = ModeStateMachine()
        XCTAssertFalse(m.handle(.requestDeactivation))
        var a = ModeStateMachine(state: .active)
        XCTAssertFalse(a.handle(.requestActivation))
    }

    func testStepsOnlyApplyInMatchingPhase() {
        var m = ModeStateMachine()
        XCTAssertFalse(m.handle(.activationStep(.closingApps)))
        XCTAssertFalse(m.handle(.deactivationStep(.restoringApps)))
        XCTAssertEqual(m.state, .normal)
    }

    func testCancelReturnsToNormal() {
        var m = ModeStateMachine()
        m.handle(.requestActivation)
        XCTAssertTrue(m.handle(.cancel))
        XCTAssertEqual(m.state, .normal)
    }

    func testRecoveryResumeAndCancelReturnsToRecovery() {
        var m = ModeStateMachine()
        XCTAssertTrue(m.handle(.recoveryDetected))
        XCTAssertFalse(m.handle(.requestActivation), "Must resolve recovery first")
        XCTAssertTrue(m.handle(.resumeRequested))
        XCTAssertTrue(m.isResuming)
        XCTAssertTrue(m.handle(.cancel))
        XCTAssertEqual(m.state, .recoveryNeeded)
    }

    func testRecoveryRestoreRunsDeactivation() {
        var m = ModeStateMachine(state: .recoveryNeeded)
        XCTAssertTrue(m.handle(.requestDeactivation))
        XCTAssertEqual(m.state, .deactivating(.unloadingModels))
    }

    func testAbortedActivationReturnsToPreviousRestingState() {
        var m = ModeStateMachine()
        m.handle(.requestActivation); m.handle(.confirm)
        XCTAssertTrue(m.handle(.activationAborted))
        XCTAssertEqual(m.state, .normal)

        var r = ModeStateMachine(state: .recoveryNeeded)
        r.handle(.resumeRequested); r.handle(.confirm)
        XCTAssertTrue(r.handle(.activationAborted))
        XCTAssertEqual(r.state, .recoveryNeeded)
    }
}
