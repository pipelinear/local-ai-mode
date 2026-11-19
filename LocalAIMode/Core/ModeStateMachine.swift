import Foundation

enum ModeEvent: Equatable, Sendable {
    case requestActivation
    case resumeRequested
    case confirm
    case cancel
    case activationStep(ActivationStep)
    case activationFinished
    /// Activation failed before anything irreversible happened (nothing was closed).
    case activationAborted
    case requestDeactivation
    case deactivationStep(DeactivationStep)
    case deactivationFinished
    case recoveryDetected
    case recoveryDismissed
}

/// Pure state machine guarding mode transitions. Every transition request goes through `handle(_:)`;
/// a rejected event leaves the state untouched, which is how overlapping ON/OFF requests are refused.
struct ModeStateMachine: Sendable {
    private(set) var state: ModeState = .normal
    /// True when the pending confirmation resumes an interrupted session instead of starting a new one.
    private(set) var isResuming = false

    init(state: ModeState = .normal) { self.state = state }

    @discardableResult
    mutating func handle(_ event: ModeEvent) -> Bool {
        guard let next = nextState(for: event) else { return false }
        switch event {
        case .requestActivation: isResuming = false
        case .resumeRequested: isResuming = true
        case .activationFinished, .activationAborted, .cancel, .deactivationFinished, .recoveryDismissed: isResuming = false
        default: break
        }
        state = next
        return true
    }

    func canHandle(_ event: ModeEvent) -> Bool { nextState(for: event) != nil }

    private func nextState(for event: ModeEvent) -> ModeState? {
        switch (state, event) {
        case (.normal, .requestActivation):
            return .awaitingConfirmation
        case (.recoveryNeeded, .resumeRequested):
            return .awaitingConfirmation
        case (.awaitingConfirmation, .confirm):
            return .activating(.savingSnapshot)
        case (.awaitingConfirmation, .cancel):
            return isResuming ? .recoveryNeeded : .normal
        case (.activating, .activationStep(let step)):
            return .activating(step)
        case (.activating, .activationFinished):
            return .active
        case (.activating, .activationAborted):
            return isResuming ? .recoveryNeeded : .normal
        case (.active, .requestDeactivation), (.recoveryNeeded, .requestDeactivation):
            return .deactivating(.unloadingModels)
        case (.deactivating, .deactivationStep(let step)):
            return .deactivating(step)
        case (.deactivating, .deactivationFinished):
            return .normal
        case (.normal, .recoveryDetected):
            return .recoveryNeeded
        case (.recoveryNeeded, .recoveryDismissed):
            return .normal
        default:
            return nil
        }
    }
}
