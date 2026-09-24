use serde::{Deserialize, Serialize};

use crate::protection::ProtectionMode;

const MAXIMUM_DURATION: f64 = i64::MAX as f64 / 2.0;
const MAXIMUM_WEB_DOMAINS: usize = 50;

#[derive(Deserialize)]
pub struct PolicyValues {
    pub protection_mode: ProtectionMode,
    pub wait_duration: String,
    pub full_unlock_delay: Option<String>,
    pub break_duration: String,
    pub fixed_duration: Option<String>,
    pub prevents_app_removal: bool,
    pub requires_automatic_date_and_time: bool,
}

#[derive(Serialize)]
pub struct NormalizedValues {
    pub wait_duration: f64,
    pub full_unlock_delay: f64,
    pub break_duration: f64,
    pub fixed_duration: Option<f64>,
    pub prevents_app_removal: bool,
    pub requires_automatic_date_and_time: bool,
}

#[derive(Deserialize)]
pub struct TargetCounts {
    pub manual_domains: usize,
    pub selected_web_domains: usize,
    pub selected_applications: usize,
    pub selected_categories: usize,
    pub blocks_adult_websites: bool,
    pub require_target: bool,
}

fn duration(value: &str) -> Result<f64, &'static str> {
    let value = value.parse::<f64>().map_err(|_| "invalid_duration")?;
    if value.is_finite() && (0.0..MAXIMUM_DURATION).contains(&value) {
        Ok(value)
    } else {
        Err("invalid_duration")
    }
}

pub fn validate_values(values: &PolicyValues, stored: bool) -> Result<(), &'static str> {
    duration(&values.wait_duration)?;
    duration(&values.break_duration)?;
    if let Some(value) = &values.full_unlock_delay {
        duration(value)?;
    }
    if let Some(value) = &values.fixed_duration {
        duration(value)?;
        if !values.protection_mode.allows_breaks() {
            return Err("fixed_duration_unavailable");
        }
    }
    if stored
        && !values.protection_mode.allows_breaks()
        && (!values.prevents_app_removal || !values.requires_automatic_date_and_time)
    {
        return Err("device_protection_required");
    }
    Ok(())
}

pub fn normalize_values(values: &PolicyValues) -> Result<NormalizedValues, &'static str> {
    validate_values(values, false)?;
    let wait_duration = duration(&values.wait_duration)?.max(3_600.0);
    Ok(NormalizedValues {
        wait_duration,
        full_unlock_delay: values
            .full_unlock_delay
            .as_deref()
            .map(duration)
            .transpose()?
            .unwrap_or(wait_duration)
            .max(3_600.0),
        break_duration: duration(&values.break_duration)?.max(900.0),
        fixed_duration: values
            .fixed_duration
            .as_deref()
            .map(duration)
            .transpose()?
            .map(|value| value.max(3_600.0)),
        prevents_app_removal: values.prevents_app_removal
            || !values.protection_mode.allows_breaks(),
        requires_automatic_date_and_time: values.requires_automatic_date_and_time
            || !values.protection_mode.allows_breaks(),
    })
}

pub fn validate_targets(counts: &TargetCounts) -> Result<(), &'static str> {
    if counts.manual_domains > MAXIMUM_WEB_DOMAINS {
        return Err("too_many_manual_domains");
    }
    if counts.selected_web_domains > MAXIMUM_WEB_DOMAINS {
        return Err("too_many_selected_domains");
    }
    if counts.require_target
        && counts.manual_domains == 0
        && counts.selected_web_domains == 0
        && counts.selected_applications == 0
        && counts.selected_categories == 0
        && !counts.blocks_adult_websites
    {
        return Err("no_blocking_target");
    }
    Ok(())
}
