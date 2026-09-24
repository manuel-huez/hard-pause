use hard_pause_core::ios_policy::{
    normalize_values, validate_targets, validate_values, PolicyValues, TargetCounts,
};
use hard_pause_core::protection::ProtectionMode;

fn values(mode: ProtectionMode) -> PolicyValues {
    PolicyValues {
        protection_mode: mode,
        wait_duration: "1".into(),
        full_unlock_delay: None,
        break_duration: "2".into(),
        fixed_duration: None,
        prevents_app_removal: false,
        requires_automatic_date_and_time: false,
    }
}

#[test]
fn ios_values_preserve_the_legacy_delay_and_lockdown_requirements() {
    let pause = normalize_values(&values(ProtectionMode::SoftLock)).unwrap();
    assert_eq!(pause.wait_duration, 3_600.0);
    assert_eq!(pause.full_unlock_delay, 3_600.0);
    assert_eq!(pause.break_duration, 900.0);
    assert!(!pause.prevents_app_removal);

    let lockdown = values(ProtectionMode::Lockdown);
    let normalized = normalize_values(&lockdown).unwrap();
    assert!(normalized.prevents_app_removal);
    assert!(normalized.requires_automatic_date_and_time);
    assert_eq!(
        validate_values(&lockdown, true),
        Err("device_protection_required")
    );

    let mut fixed = values(ProtectionMode::Lockdown);
    fixed.fixed_duration = Some("3600".into());
    assert_eq!(
        validate_values(&fixed, false),
        Err("fixed_duration_unavailable")
    );
}

#[test]
fn ios_values_reject_invalid_durations_and_empty_activation() {
    for invalid in ["NaN", "inf", "-1", "4611686018427387904"] {
        let mut policy = values(ProtectionMode::SoftLock);
        policy.wait_duration = invalid.into();
        assert_eq!(validate_values(&policy, false), Err("invalid_duration"));
    }
    let empty = TargetCounts {
        manual_domains: 0,
        selected_web_domains: 0,
        selected_applications: 0,
        selected_categories: 0,
        blocks_adult_websites: false,
        require_target: true,
    };
    assert_eq!(validate_targets(&empty), Err("no_blocking_target"));
    assert_eq!(
        validate_targets(&TargetCounts {
            selected_categories: 1,
            ..empty
        }),
        Ok(())
    );
}
