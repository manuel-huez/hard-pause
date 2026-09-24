enum PauseCoreIntentFailurePolicy: String, Equatable, Sendable, Encodable {
    case notUsed = "not_used"
    case stop
    case continueForSafety = "continue_for_safety"
}

enum PauseCoreTransactionStage: Equatable, Sendable {
    case prepareSchedulePrerequisite
    case saveIntent(PauseCoreIntentFailurePolicy)
    case applyTightening
    case saveCandidate
    case clearIntent
    case applyRelaxation
}

struct PauseCoreTransactionPlan: Equatable, Sendable, Encodable {
    let requiresSchedulePrerequisite: Bool
    let hasTightening: Bool
    let intentFailurePolicy: PauseCoreIntentFailurePolicy
    let savesCandidate: Bool
    let hasRelaxation: Bool

    private struct Result: Decodable { let stages: [String] }

    var orderedStages: [PauseCoreTransactionStage] {
        get throws {
            let result: Result = try RustCoreBridge.call("transaction.stages", self)
            return try result.stages.map { name in
                switch name {
                case "prepare_schedule_prerequisite": .prepareSchedulePrerequisite
                case "save_intent": .saveIntent(intentFailurePolicy)
                case "apply_tightening": .applyTightening
                case "save_candidate": .saveCandidate
                case "clear_intent": .clearIntent
                case "apply_relaxation": .applyRelaxation
                default: throw RustCoreBridge.Failure.unavailable
                }
            }
        }
    }
}
