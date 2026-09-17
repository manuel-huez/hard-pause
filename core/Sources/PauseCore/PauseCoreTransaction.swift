enum PauseCoreIntentFailurePolicy: Equatable, Sendable {
    case notUsed
    case stop
    /// Continue applying a safety tightening, such as an emergency relock.
    case continueForSafety
}

enum PauseCoreTransactionStage: Equatable, Sendable {
    case prepareSchedulePrerequisite
    case saveIntent(PauseCoreIntentFailurePolicy)
    case applyTightening
    case saveCandidate
    case clearIntent
    case applyRelaxation
}

/// Describes the common safety order. Native runtimes execute and persist each stage.
struct PauseCoreTransactionPlan: Equatable, Sendable {
    let requiresSchedulePrerequisite: Bool
    let hasTightening: Bool
    let intentFailurePolicy: PauseCoreIntentFailurePolicy
    let savesCandidate: Bool
    let hasRelaxation: Bool

    var orderedStages: [PauseCoreTransactionStage] {
        var stages: [PauseCoreTransactionStage] = []
        if requiresSchedulePrerequisite {
            stages.append(.prepareSchedulePrerequisite)
        }
        if hasTightening, intentFailurePolicy != .notUsed {
            stages.append(.saveIntent(intentFailurePolicy))
        }
        if hasTightening {
            stages.append(.applyTightening)
        }
        if savesCandidate {
            stages.append(.saveCandidate)
        }
        if hasTightening, intentFailurePolicy != .notUsed {
            stages.append(.clearIntent)
        }
        if hasRelaxation {
            stages.append(.applyRelaxation)
        }
        return stages
    }
}
