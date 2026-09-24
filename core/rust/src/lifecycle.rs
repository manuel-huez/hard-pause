use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum RequestKind {
    BreakAccess,
    FullUnlock,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
pub struct PendingRequest {
    pub kind: RequestKind,
    pub ready_at: f64,
    pub break_ends_at: Option<f64>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
pub struct LifecycleState {
    pub is_active: bool,
    pub natural_end_at: Option<f64>,
    pub pending_request: Option<PendingRequest>,
    pub break_ends_at: Option<f64>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
pub enum LifecycleProfile {
    #[serde(rename = "macOS")]
    MacOS,
    #[serde(rename = "iOS")]
    IOS,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LifecycleError {
    Inactive,
    PendingRequestExists,
    BreakAlreadyActive,
    NoPendingBreakRequest,
    InvalidTime,
}

impl LifecycleError {
    pub const fn code(self) -> &'static str {
        match self {
            Self::Inactive => "inactive",
            Self::PendingRequestExists => "pending_request_exists",
            Self::BreakAlreadyActive => "break_already_active",
            Self::NoPendingBreakRequest => "no_pending_break_request",
            Self::InvalidTime => "invalid_time",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum LifecyclePhase {
    Inactive,
    Active {
        natural_end_remaining: Option<f64>,
    },
    WaitingForBreak {
        remaining: f64,
        natural_end_remaining: Option<f64>,
    },
    WaitingForFullUnlock {
        remaining: f64,
        natural_end_remaining: Option<f64>,
    },
    BreakActive {
        remaining: f64,
        full_unlock_remaining: Option<f64>,
        natural_end_remaining: Option<f64>,
    },
}

impl LifecyclePhase {
    pub const fn name(&self) -> &'static str {
        match self {
            Self::Inactive => "inactive",
            Self::Active { .. } => "active",
            Self::WaitingForBreak { .. } => "waitingForBreak",
            Self::WaitingForFullUnlock { .. } => "waitingForFullUnlock",
            Self::BreakActive { .. } => "breakActive",
        }
    }
}

pub fn request_break(
    state: &mut LifecycleState,
    now: f64,
    delay: f64,
    duration: f64,
) -> Result<(), LifecycleError> {
    if !state.is_active {
        return Err(LifecycleError::Inactive);
    }
    if state.pending_request.is_some() {
        return Err(LifecycleError::PendingRequestExists);
    }
    if state.break_ends_at.is_some_and(|end| now < end) {
        return Err(LifecycleError::BreakAlreadyActive);
    }
    let ready_at = now + delay;
    let break_ends_at = ready_at + duration;
    if !now.is_finite() || !delay.is_finite() || !duration.is_finite() || !break_ends_at.is_finite()
    {
        return Err(LifecycleError::InvalidTime);
    }
    state.pending_request = Some(PendingRequest {
        kind: RequestKind::BreakAccess,
        ready_at,
        break_ends_at: Some(break_ends_at),
    });
    state.break_ends_at = None;
    Ok(())
}

pub fn request_full_unlock(
    state: &mut LifecycleState,
    now: f64,
    delay: f64,
    profile: LifecycleProfile,
) -> Result<(), LifecycleError> {
    if !state.is_active {
        return Err(LifecycleError::Inactive);
    }
    if state.pending_request.is_some() {
        return Err(LifecycleError::PendingRequestExists);
    }
    let ready_at = now + delay;
    if !now.is_finite() || !delay.is_finite() || !ready_at.is_finite() {
        return Err(LifecycleError::InvalidTime);
    }
    state.pending_request = Some(PendingRequest {
        kind: RequestKind::FullUnlock,
        ready_at,
        break_ends_at: None,
    });
    if profile == LifecycleProfile::IOS {
        state.break_ends_at = None;
    }
    Ok(())
}

pub fn cancel_break(state: &mut LifecycleState) -> Result<(), LifecycleError> {
    if !state.is_active {
        return Err(LifecycleError::Inactive);
    }
    if !state
        .pending_request
        .as_ref()
        .is_some_and(|request| request.kind == RequestKind::BreakAccess)
    {
        return Err(LifecycleError::NoPendingBreakRequest);
    }
    state.pending_request = None;
    Ok(())
}

pub fn reconcile(state: &mut LifecycleState, now: f64) -> bool {
    let before = state.clone();
    if !state.is_active || !now.is_finite() {
        return false;
    }
    if state.natural_end_at.is_some_and(|end| now >= end) {
        deactivate(state);
        return *state != before;
    }
    if let Some(request) = state.pending_request.as_ref().filter(|r| now >= r.ready_at) {
        match request.kind {
            RequestKind::FullUnlock => {
                deactivate(state);
                return *state != before;
            }
            RequestKind::BreakAccess => {
                state.break_ends_at = request.break_ends_at.filter(|end| now < *end);
                state.pending_request = None;
            }
        }
    }
    if state.break_ends_at.is_some_and(|end| now >= end) {
        state.break_ends_at = None;
    }
    *state != before
}

pub fn phase(state: &LifecycleState, now: f64) -> LifecyclePhase {
    if !state.is_active {
        return LifecyclePhase::Inactive;
    }
    let natural_end_remaining = state.natural_end_at.map(|end| (end - now).max(0.0));
    if let Some(end) = state.break_ends_at.filter(|end| now < *end) {
        let full_unlock_remaining = state.pending_request.as_ref().and_then(|request| {
            (request.kind == RequestKind::FullUnlock).then_some((request.ready_at - now).max(0.0))
        });
        return LifecyclePhase::BreakActive {
            remaining: end - now,
            full_unlock_remaining,
            natural_end_remaining,
        };
    }
    if let Some(request) = &state.pending_request {
        let remaining = (request.ready_at - now).max(0.0);
        return if request.kind == RequestKind::BreakAccess {
            LifecyclePhase::WaitingForBreak {
                remaining,
                natural_end_remaining,
            }
        } else {
            LifecyclePhase::WaitingForFullUnlock {
                remaining,
                natural_end_remaining,
            }
        };
    }
    LifecyclePhase::Active {
        natural_end_remaining,
    }
}

fn deactivate(state: &mut LifecycleState) {
    state.is_active = false;
    state.natural_end_at = None;
    state.pending_request = None;
    state.break_ends_at = None;
}
