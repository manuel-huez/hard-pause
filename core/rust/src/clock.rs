use serde::{Deserialize, Serialize};

/// The adapter supplies a sleep-inclusive elapsed reading and a stable boot ID.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
pub struct ClockReading {
    pub elapsed_since_boot: f64,
    pub boot_identifier: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
pub struct ClockCheckpoint {
    pub logical_time: f64,
    pub elapsed_since_boot: Option<f64>,
    pub boot_identifier: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct ClockProjection {
    pub logical_time: f64,
    pub verified_elapsed: f64,
    pub is_same_boot: bool,
}

pub fn project(checkpoint: &ClockCheckpoint, reading: &ClockReading) -> ClockProjection {
    let paused = || ClockProjection {
        logical_time: checkpoint.logical_time,
        verified_elapsed: 0.0,
        is_same_boot: false,
    };
    let (Some(checkpoint_boot), Some(reading_boot), Some(checkpoint_elapsed)) = (
        checkpoint.boot_identifier.as_ref(),
        reading.boot_identifier.as_ref(),
        checkpoint.elapsed_since_boot,
    ) else {
        return paused();
    };
    if !checkpoint.logical_time.is_finite()
        || checkpoint_boot != reading_boot
        || !checkpoint_elapsed.is_finite()
        || checkpoint_elapsed < 0.0
        || !reading.elapsed_since_boot.is_finite()
        || reading.elapsed_since_boot < checkpoint_elapsed
    {
        return paused();
    }
    let delta = reading.elapsed_since_boot - checkpoint_elapsed;
    let logical_time = checkpoint.logical_time + delta;
    if !delta.is_finite() || !logical_time.is_finite() || logical_time < checkpoint.logical_time {
        return paused();
    }
    ClockProjection {
        logical_time,
        verified_elapsed: delta,
        is_same_boot: true,
    }
}
