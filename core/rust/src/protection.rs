use serde::{Deserialize, Serialize};

/// Native permission protection remains an adapter responsibility.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
pub enum ProtectionMode {
    #[serde(rename = "softLock")]
    SoftLock,
    #[serde(rename = "lockdown")]
    Lockdown,
}

impl ProtectionMode {
    pub const fn allows_breaks(self) -> bool {
        matches!(self, Self::SoftLock)
    }
}
