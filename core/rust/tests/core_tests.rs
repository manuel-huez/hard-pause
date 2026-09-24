use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use hard_pause_core::clock::{project, ClockCheckpoint, ClockReading};
use hard_pause_core::domains::{DomainListFormat, PortableDomainList};
use hard_pause_core::encrypted_state::{open, seal};
use hard_pause_core::lifecycle::{
    cancel_break, phase, reconcile, request_break, request_full_unlock, LifecycleProfile,
    LifecycleState,
};
use hard_pause_core::protection::ProtectionMode;
use hard_pause_core::transaction::{IntentFailurePolicy, TransactionPlan, TransactionStage};
use hard_pause_core::{
    dispatch, hp_core_call, hp_core_free, hp_domain_index_contains, hp_domain_index_create,
    hp_domain_index_export, hp_domain_index_free, HpCoreBuffer, HpDomainIndex,
    HP_DOMAIN_FORMAT_HARD_PAUSE_SUPPLEMENT,
};
use serde::Deserialize;
use serde_json::json;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Trace {
    profile: String,
    natural_end_at: Option<f64>,
    commands: Vec<TraceCommand>,
}

#[derive(Deserialize)]
struct TraceCommand {
    kind: String,
    at: f64,
    delay: Option<f64>,
    duration: Option<f64>,
    phase: String,
}

#[test]
fn apple_lifecycle_fixtures() {
    let traces: Vec<Trace> =
        serde_json::from_str(include_str!("fixtures/apple-lifecycle.json")).unwrap();
    for trace in traces {
        let mut state = LifecycleState {
            is_active: true,
            natural_end_at: trace.natural_end_at,
            pending_request: None,
            break_ends_at: None,
        };
        for command in trace.commands {
            match command.kind.as_str() {
                "break" => request_break(
                    &mut state,
                    command.at,
                    command.delay.unwrap_or(0.0),
                    command.duration.unwrap_or(0.0),
                )
                .unwrap(),
                "unlock" => request_full_unlock(
                    &mut state,
                    command.at,
                    command.delay.unwrap_or(0.0),
                    if trace.profile == "macOS" {
                        LifecycleProfile::MacOS
                    } else {
                        LifecycleProfile::IOS
                    },
                )
                .unwrap(),
                "cancelBreak" => cancel_break(&mut state).unwrap(),
                "reconcile" => {
                    reconcile(&mut state, command.at);
                }
                other => panic!("unknown command: {other}"),
            }
            assert_eq!(phase(&state, command.at).name(), command.phase);
        }
    }
}

#[test]
fn changed_boot_and_invalid_readings_do_not_advance() {
    let checkpoint = ClockCheckpoint {
        logical_time: 60.0,
        elapsed_since_boot: Some(160.0),
        boot_identifier: Some("boot-a".into()),
    };
    let changed = project(
        &checkpoint,
        &ClockReading {
            elapsed_since_boot: 10_000.0,
            boot_identifier: Some("boot-b".into()),
        },
    );
    assert_eq!(changed.logical_time, 60.0);
    assert!(!changed.is_same_boot);
    for elapsed_since_boot in [f64::NAN, f64::INFINITY, -1.0, 159.0] {
        let invalid = project(
            &checkpoint,
            &ClockReading {
                elapsed_since_boot,
                boot_identifier: Some("boot-a".into()),
            },
        );
        assert_eq!(invalid.logical_time, 60.0);
        assert_eq!(invalid.verified_elapsed, 0.0);
    }
    let resumed = project(
        &ClockCheckpoint {
            logical_time: changed.logical_time,
            elapsed_since_boot: Some(10_000.0),
            boot_identifier: Some("boot-b".into()),
        },
        &ClockReading {
            elapsed_since_boot: 10_120.0,
            boot_identifier: Some("boot-b".into()),
        },
    );
    assert_eq!(resumed.logical_time, 180.0);
}

#[test]
fn transaction_order_and_mode() {
    let stages = TransactionPlan {
        requires_schedule_prerequisite: true,
        has_tightening: true,
        intent_failure_policy: IntentFailurePolicy::Stop,
        saves_candidate: true,
        has_relaxation: true,
    }
    .ordered_stages();
    assert_eq!(
        stages,
        [
            TransactionStage::PrepareSchedulePrerequisite,
            TransactionStage::SaveIntent,
            TransactionStage::ApplyTightening,
            TransactionStage::SaveCandidate,
            TransactionStage::ClearIntent,
            TransactionStage::ApplyRelaxation,
        ]
    );
    assert!(ProtectionMode::SoftLock.allows_breaks());
    assert!(!ProtectionMode::Lockdown.allows_breaks());
}

#[test]
fn domain_formats_and_matching() {
    let valid: Vec<_> = (0..1000)
        .map(|index| format!("site{index}.example"))
        .collect();
    let body = valid.join("\n");
    let upstream = format!("# License: MIT\n# Entries: 1,001\n{body}\n*.bad.example\n");
    let parsed = PortableDomainList::parse(
        upstream.as_bytes(),
        &DomainListFormat::BlockListProject {
            minimum_count: 1000,
        },
    )
    .unwrap();
    assert_eq!(parsed.domains.len(), 1000);
    assert_eq!(parsed.skipped_entries, 1);
    for invalid in [
        "# Entries: 2\nadult.example\n",
        "<html>network error</html>",
        "# Entries: 1\nhttps://adult.example/path\n",
        "# Entries: 1\n*.adult.example\n",
        "# Entries: 1\n127.0.0.1\n",
        "# Entries: 1\ncom\n",
        "# Entries: 1\na..example\n",
    ] {
        assert!(PortableDomainList::parse(
            invalid.as_bytes(),
            &DomainListFormat::BlockListProject { minimum_count: 1 }
        )
        .is_err());
    }
    let supplement = |entries: &[&str]| {
        format!(
            "# Format: hard-pause-domain-list-v1\n# Category: adult\n# Revision: 2026-09-17\n# License: CC0-1.0\n# Provenance: manual-review\n# Entries: {}\n{}\n",
            entries.len(),
            entries.join("\n")
        )
    };
    let parsed = PortableDomainList::parse(
        supplement(&["adult.example"]).as_bytes(),
        &DomainListFormat::HardPauseSupplement {
            category: "adult".into(),
        },
    )
    .unwrap();
    assert!(parsed.contains("video.deep.adult.example"));
    assert!(parsed.contains("ADULT.EXAMPLE."));
    assert!(!parsed.contains("notadult.example"));
    assert!(!parsed.contains("adult.example.safe.test"));
    let alternate_newlines = "# Format: hard-pause-domain-list-v1\r# Category: adult\u{2028}# Revision: 2026-09-17\r# License: CC0-1.0\r# Provenance: manual-review\r# Entries: 1\radult.example";
    assert!(PortableDomainList::parse(
        alternate_newlines.as_bytes(),
        &DomainListFormat::HardPauseSupplement {
            category: "adult".into(),
        },
    )
    .unwrap()
    .contains("adult.example"));
    for invalid in [
        supplement(&["adult.example", "adult.example"]),
        supplement(&["*.adult.example"]),
        supplement(&["https://adult.example"]),
        supplement(&["127.0.0.1"]),
    ] {
        assert!(PortableDomainList::parse(
            invalid.as_bytes(),
            &DomainListFormat::HardPauseSupplement {
                category: "adult".into(),
            },
        )
        .is_err());
    }
    let repository_supplement = include_bytes!("../../../data/adult-domains/supplement.txt");
    assert!(PortableDomainList::parse(
        repository_supplement,
        &DomainListFormat::HardPauseSupplement {
            category: "adult".into()
        }
    )
    .unwrap()
    .domains
    .is_empty());
}

#[test]
fn cryptokit_envelope_vector_and_purpose_binding() {
    let key = [7_u8; 32];
    let nonce = [9_u8; 12];
    let envelope = seal(b"hello", &key, "primary", &nonce).unwrap();
    assert_eq!(
        STANDARD.decode(&envelope.ciphertext).unwrap(),
        [0x2d, 0x2a, 0xee, 0x23, 0x5f]
    );
    assert_eq!(
        STANDARD.decode(&envelope.tag).unwrap(),
        [
            0x0e, 0x7f, 0x8b, 0xb6, 0x6e, 0x6f, 0xd1, 0xab, 0x86, 0xe3, 0x2f, 0x62, 0xe4, 0x5d,
            0x3c, 0x46
        ]
    );
    assert_eq!(open(&envelope, &key, "primary").unwrap(), b"hello");
    assert!(open(&envelope, &key, "pending").is_err());
    let decoded: hard_pause_core::encrypted_state::Envelope =
        serde_json::from_slice(&serde_json::to_vec(&envelope).unwrap()).unwrap();
    assert_eq!(open(&decoded, &key, "primary").unwrap(), b"hello");
}

#[test]
fn versioned_dispatch_and_owned_c_buffer() {
    let request = json!({
        "version": 1,
        "op": "protection.allows_breaks",
        "args": {"mode": "softLock"}
    });
    let bytes = serde_json::to_vec(&request).unwrap();
    let expected = dispatch(&bytes);
    assert_eq!(expected["result"]["allows_breaks"], true);
    let mut output = HpCoreBuffer {
        ptr: std::ptr::null_mut(),
        len: 0,
    };
    let status = unsafe { hp_core_call(bytes.as_ptr(), bytes.len(), &mut output) };
    assert_eq!(status, 0);
    let response = unsafe { std::slice::from_raw_parts(output.ptr, output.len) };
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(response).unwrap(),
        expected
    );
    unsafe { hp_core_free(output) };
    assert_eq!(
        dispatch(br#"{"version":2,"op":"clock.project","args":{}}"#)["error"]["code"],
        "unsupported_version"
    );
}

#[test]
fn retained_domain_index_matches_subdomains_and_rejects_bad_lists() {
    let data = b"# Format: hard-pause-domain-list-v1\n# Category: adult\n# Revision: 2026-09-17\n# License: CC0-1.0\n# Provenance: manual-review\n# Entries: 1\nadult.example\n";
    let category = b"adult";
    let mut index: *mut HpDomainIndex = std::ptr::null_mut();
    assert_eq!(
        unsafe {
            hp_domain_index_create(
                data.as_ptr(),
                data.len(),
                HP_DOMAIN_FORMAT_HARD_PAUSE_SUPPLEMENT,
                0,
                category.as_ptr(),
                category.len(),
                &mut index,
            )
        },
        0
    );
    assert!(!index.is_null());
    let mut exported = HpCoreBuffer {
        ptr: std::ptr::null_mut(),
        len: 0,
    };
    assert_eq!(unsafe { hp_domain_index_export(index, &mut exported) }, 0);
    let snapshot: serde_json::Value =
        serde_json::from_slice(unsafe { std::slice::from_raw_parts(exported.ptr, exported.len) })
            .unwrap();
    assert_eq!(snapshot["domains"], json!(["adult.example"]));
    unsafe { hp_core_free(exported) };
    for (host, expected) in [
        ("adult.example", true),
        ("video.deep.adult.example", true),
        ("ADULT.EXAMPLE.", true),
        ("notadult.example", false),
        ("adult.example.safe.test", false),
    ] {
        let mut contains = 2;
        assert_eq!(
            unsafe { hp_domain_index_contains(index, host.as_ptr(), host.len(), &mut contains) },
            0
        );
        assert_eq!(contains, u8::from(expected), "{host}");
    }
    let mut contains = 2;
    assert_eq!(
        unsafe { hp_domain_index_contains(index, [0xff].as_ptr(), 1, &mut contains) },
        -1
    );
    assert_eq!(contains, 0);
    unsafe { hp_domain_index_free(index) };

    let invalid = b"# Format: hard-pause-domain-list-v1\n# Category: adult\n# Revision: 2026-09-17\n# License: CC0-1.0\n# Provenance: manual-review\n# Entries: 2\nadult.example\n";
    index = std::ptr::null_mut();
    assert_eq!(
        unsafe {
            hp_domain_index_create(
                invalid.as_ptr(),
                invalid.len(),
                HP_DOMAIN_FORMAT_HARD_PAUSE_SUPPLEMENT,
                0,
                category.as_ptr(),
                category.len(),
                &mut index,
            )
        },
        -2
    );
    assert!(index.is_null());
}
