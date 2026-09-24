pub mod clock;
mod domain_ffi;
pub mod domains;
pub mod encrypted_state;
pub mod ios_policy;
pub mod lifecycle;
pub mod policy;
pub mod protection;
pub mod restrictions;
pub mod transaction;

pub use domain_ffi::{
    hp_domain_index_contains, hp_domain_index_create, hp_domain_index_export, hp_domain_index_free,
    HpDomainIndex, HP_DOMAIN_FORMAT_BLOCK_LIST_PROJECT, HP_DOMAIN_FORMAT_HARD_PAUSE_SUPPLEMENT,
};

use std::panic::{catch_unwind, AssertUnwindSafe};

use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use serde::de::DeserializeOwned;
use serde::Deserialize;
use serde_json::{json, Value};

#[derive(Deserialize)]
struct Request {
    version: u32,
    op: String,
    args: Value,
}

#[derive(Deserialize)]
struct StateAt {
    state: lifecycle::LifecycleState,
    now: f64,
}

#[derive(Deserialize)]
struct RequestBreak {
    state: lifecycle::LifecycleState,
    now: f64,
    delay: f64,
    duration: f64,
}

#[derive(Deserialize)]
struct RequestFullUnlock {
    state: lifecycle::LifecycleState,
    now: f64,
    delay: f64,
    profile: lifecycle::LifecycleProfile,
}

#[derive(Deserialize)]
struct ClockArgs {
    checkpoint: clock::ClockCheckpoint,
    reading: clock::ClockReading,
}

#[derive(Deserialize)]
struct SealArgs {
    payload_b64: String,
    master_key_b64: String,
    purpose: String,
    nonce_b64: String,
}

#[derive(Deserialize)]
struct OpenArgs {
    envelope: encrypted_state::Envelope,
    master_key_b64: String,
    purpose: String,
}

#[derive(Deserialize)]
struct ModeArgs {
    mode: protection::ProtectionMode,
}

#[derive(Deserialize)]
struct TextArgs {
    value: String,
}

#[derive(Deserialize)]
struct RulesArgs {
    rules: policy::Rules,
    allow_legacy_application_identity: bool,
}

#[derive(Deserialize)]
struct RulesComparison {
    current: policy::Rules,
    previous: policy::Rules,
}

#[derive(Deserialize)]
struct DraftArgs {
    draft: policy::Draft,
    mutation: bool,
    allow_legacy_application_identity: bool,
}

fn args<T: DeserializeOwned>(value: Value) -> Result<T, &'static str> {
    serde_json::from_value(value).map_err(|_| "invalid_args")
}

fn decode_b64(value: &str) -> Result<Vec<u8>, &'static str> {
    STANDARD.decode(value).map_err(|_| "invalid_base64")
}

fn valid_now(now: f64) -> Result<(), &'static str> {
    if now.is_finite() {
        Ok(())
    } else {
        Err("invalid_time")
    }
}

/// Versioned wire dispatch. Typed module functions remain the implementation of each rule.
pub fn dispatch(input: &[u8]) -> Value {
    let result = dispatch_result(input);
    match result {
        Ok(value) => json!({"ok": true, "result": value}),
        Err(code) => json!({"ok": false, "error": {"code": code}}),
    }
}

fn dispatch_result(input: &[u8]) -> Result<Value, &'static str> {
    let request: Request = serde_json::from_slice(input).map_err(|_| "invalid_request")?;
    if request.version != 1 {
        return Err("unsupported_version");
    }
    match request.op.as_str() {
        "clock.project" => {
            let input: ClockArgs = args(request.args)?;
            Ok(json!(clock::project(&input.checkpoint, &input.reading)))
        }
        "lifecycle.request_break" => {
            let mut input: RequestBreak = args(request.args)?;
            lifecycle::request_break(&mut input.state, input.now, input.delay, input.duration)
                .map_err(lifecycle::LifecycleError::code)?;
            Ok(json!({"state": input.state, "phase": lifecycle::phase(&input.state, input.now)}))
        }
        "lifecycle.request_full_unlock" => {
            let mut input: RequestFullUnlock = args(request.args)?;
            lifecycle::request_full_unlock(&mut input.state, input.now, input.delay, input.profile)
                .map_err(lifecycle::LifecycleError::code)?;
            Ok(json!({"state": input.state, "phase": lifecycle::phase(&input.state, input.now)}))
        }
        "lifecycle.cancel_break" => {
            let mut input: StateAt = args(request.args)?;
            valid_now(input.now)?;
            lifecycle::cancel_break(&mut input.state).map_err(lifecycle::LifecycleError::code)?;
            Ok(json!({"state": input.state, "phase": lifecycle::phase(&input.state, input.now)}))
        }
        "lifecycle.reconcile" => {
            let mut input: StateAt = args(request.args)?;
            valid_now(input.now)?;
            let changed = lifecycle::reconcile(&mut input.state, input.now);
            Ok(
                json!({"state": input.state, "changed": changed, "phase": lifecycle::phase(&input.state, input.now)}),
            )
        }
        "lifecycle.phase" => {
            let input: StateAt = args(request.args)?;
            valid_now(input.now)?;
            Ok(json!(lifecycle::phase(&input.state, input.now)))
        }
        "transaction.stages" => {
            let plan: transaction::TransactionPlan = args(request.args)?;
            Ok(json!({"stages": plan.ordered_stages()}))
        }
        "crypto.seal" => {
            let input: SealArgs = args(request.args)?;
            let payload = decode_b64(&input.payload_b64)?;
            let master_key = decode_b64(&input.master_key_b64)?;
            let nonce = decode_b64(&input.nonce_b64)?;
            let envelope = encrypted_state::seal(&payload, &master_key, &input.purpose, &nonce)
                .map_err(encrypted_state::EncryptedStateError::code)?;
            Ok(json!({"envelope": envelope}))
        }
        "crypto.open" => {
            let input: OpenArgs = args(request.args)?;
            let master_key = decode_b64(&input.master_key_b64)?;
            let payload = encrypted_state::open(&input.envelope, &master_key, &input.purpose)
                .map_err(encrypted_state::EncryptedStateError::code)?;
            Ok(json!({"payload_b64": STANDARD.encode(payload)}))
        }
        "protection.allows_breaks" => {
            let input: ModeArgs = args(request.args)?;
            Ok(json!({"allows_breaks": input.mode.allows_breaks()}))
        }
        "ios.validate_durations" => {
            let input: ios_policy::PolicyValues = args(request.args)?;
            ios_policy::validate_values(&input, false)?;
            Ok(json!({}))
        }
        "ios.validate_stored_policy" => {
            let input: ios_policy::PolicyValues = args(request.args)?;
            ios_policy::validate_values(&input, true)?;
            Ok(json!({}))
        }
        "ios.normalize_policy" => {
            let input: ios_policy::PolicyValues = args(request.args)?;
            Ok(json!(ios_policy::normalize_values(&input)?))
        }
        "ios.validate_targets" => {
            let input: ios_policy::TargetCounts = args(request.args)?;
            ios_policy::validate_targets(&input)?;
            Ok(json!({}))
        }
        "restrictions.compose" => {
            let input: restrictions::Request = args(request.args)?;
            Ok(json!(restrictions::compose(input)))
        }
        "restrictions.union" => {
            let input: restrictions::UnionRequest = args(request.args)?;
            Ok(json!(restrictions::union(input)))
        }
        "policy.normalize_domain" => {
            let input: TextArgs = args(request.args)?;
            Ok(json!({"value": policy::normalize_domain(&input.value)}))
        }
        "policy.is_literal_ip_address" => {
            let input: TextArgs = args(request.args)?;
            Ok(json!({"value": policy::is_literal_ip_address(&input.value)}))
        }
        "policy.parse_url_pattern" => {
            let input: TextArgs = args(request.args)?;
            Ok(json!({"value": policy::parse_pattern(&input.value)}))
        }
        "policy.exact_domain" => {
            let input: TextArgs = args(request.args)?;
            Ok(json!({"value": policy::exact_domain(&input.value)}))
        }
        "policy.network_domains" => {
            let input: TextArgs = args(request.args)?;
            Ok(json!({"value": policy::network_domains(&input.value)}))
        }
        "policy.matches_url" => {
            let input: policy::URLMatch = args(request.args)?;
            Ok(json!({"value": policy::matches_url(&input)}))
        }
        "policy.normalize_rules" => {
            let input: policy::Rules = args(request.args)?;
            Ok(json!({"rules": policy::normalize_rules(input)}))
        }
        "policy.add_rules" => {
            let input: policy::RuleAdditions = args(request.args)?;
            Ok(json!({"rules": policy::add_rules(input)}))
        }
        "policy.includes_all_rules" => {
            let input: RulesComparison = args(request.args)?;
            Ok(json!({"value": policy::includes_all_rules(&input.current, &input.previous)}))
        }
        "policy.validate_rules" => {
            let input: RulesArgs = args(request.args)?;
            policy::validate_rules(&input.rules, input.allow_legacy_application_identity)?;
            Ok(json!({}))
        }
        "policy.validate_draft" => {
            let input: DraftArgs = args(request.args)?;
            let name = policy::validate_draft(
                &input.draft,
                input.mutation,
                input.allow_legacy_application_identity,
            )?;
            Ok(json!({"name": name}))
        }
        _ => Err("unknown_operation"),
    }
}

/// Ownership of returned bytes transfers to the caller. Release once with hp_core_free.
#[repr(C)]
pub struct HpCoreBuffer {
    pub ptr: *mut u8,
    pub len: usize,
}

/// Returns 0 with a JSON response, -1 for bad pointers/size, or -2 for an
/// unexpected internal failure. JSON validation errors use the response body.
///
/// # Safety
/// `input` must point to `input_len` readable bytes; `out` must be writable.
#[no_mangle]
pub unsafe extern "C" fn hp_core_call(
    input: *const u8,
    input_len: usize,
    out: *mut HpCoreBuffer,
) -> i32 {
    if input.is_null() || out.is_null() || input_len > 48 * 1024 * 1024 {
        return -1;
    }
    unsafe {
        *out = HpCoreBuffer {
            ptr: std::ptr::null_mut(),
            len: 0,
        };
    }
    let result = catch_unwind(AssertUnwindSafe(|| {
        let input = unsafe { std::slice::from_raw_parts(input, input_len) };
        serde_json::to_vec(&dispatch(input))
    }));
    let Ok(Ok(bytes)) = result else {
        return -2;
    };
    let boxed = bytes.into_boxed_slice();
    let len = boxed.len();
    let ptr = Box::into_raw(boxed).cast::<u8>();
    unsafe { *out = HpCoreBuffer { ptr, len } };
    0
}

/// # Safety
/// `buffer` must be an unmodified value returned by hp_core_call and freed once.
#[no_mangle]
pub unsafe extern "C" fn hp_core_free(buffer: HpCoreBuffer) {
    if !buffer.ptr.is_null() {
        let ptr = std::ptr::slice_from_raw_parts_mut(buffer.ptr, buffer.len);
        unsafe { drop(Box::from_raw(ptr)) };
    }
}
