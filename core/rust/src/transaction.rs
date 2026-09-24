use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum IntentFailurePolicy {
    NotUsed,
    Stop,
    ContinueForSafety,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
pub struct TransactionPlan {
    pub requires_schedule_prerequisite: bool,
    pub has_tightening: bool,
    pub intent_failure_policy: IntentFailurePolicy,
    pub saves_candidate: bool,
    pub has_relaxation: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum TransactionStage {
    PrepareSchedulePrerequisite,
    SaveIntent,
    ApplyTightening,
    SaveCandidate,
    ClearIntent,
    ApplyRelaxation,
}

impl TransactionPlan {
    pub fn ordered_stages(self) -> Vec<TransactionStage> {
        use TransactionStage as Stage;
        let mut stages = Vec::with_capacity(6);
        if self.requires_schedule_prerequisite {
            stages.push(Stage::PrepareSchedulePrerequisite);
        }
        if self.has_tightening && self.intent_failure_policy != IntentFailurePolicy::NotUsed {
            stages.push(Stage::SaveIntent);
        }
        if self.has_tightening {
            stages.push(Stage::ApplyTightening);
        }
        if self.saves_candidate {
            stages.push(Stage::SaveCandidate);
        }
        if self.has_tightening && self.intent_failure_policy != IntentFailurePolicy::NotUsed {
            stages.push(Stage::ClearIntent);
        }
        if self.has_relaxation {
            stages.push(Stage::ApplyRelaxation);
        }
        stages
    }
}
