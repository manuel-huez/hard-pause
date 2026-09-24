use aes_gcm::aead::{AeadInPlace, KeyInit};
use aes_gcm::{Aes256Gcm, Nonce, Tag};
use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use hkdf::Hkdf;
use serde::{Deserialize, Serialize};
use sha2::Sha256;

pub const FORMAT: &str = "hard-pause-aes-256-gcm-v1";
const KEY_SALT: &[u8] = b"HardPause/state-key/v1";
const KEY_INFO: &[u8] = b"AES-256-GCM";
const AAD_PREFIX: &str = "HardPause/state/v1/";

#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
pub struct Envelope {
    pub format: String,
    pub purpose: String,
    pub nonce: String,
    pub ciphertext: String,
    pub tag: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EncryptedStateError {
    InvalidKey,
    InvalidEnvelope,
    AuthenticationFailed,
}

impl EncryptedStateError {
    pub const fn code(self) -> &'static str {
        match self {
            Self::InvalidKey => "invalid_key",
            Self::InvalidEnvelope => "invalid_envelope",
            Self::AuthenticationFailed => "authentication_failed",
        }
    }
}

/// The caller supplies a unique 12-byte nonce. Key storage and nonce generation
/// belong to the platform adapter.
pub fn seal(
    payload: &[u8],
    master_key: &[u8],
    purpose: &str,
    nonce: &[u8],
) -> Result<Envelope, EncryptedStateError> {
    if nonce.len() != 12 {
        return Err(EncryptedStateError::InvalidEnvelope);
    }
    let key = derive_key(master_key)?;
    let cipher = Aes256Gcm::new_from_slice(&key).expect("derived key is 32 bytes");
    let mut ciphertext = payload.to_vec();
    let aad = format!("{AAD_PREFIX}{purpose}");
    let tag = cipher
        .encrypt_in_place_detached(Nonce::from_slice(nonce), aad.as_bytes(), &mut ciphertext)
        .map_err(|_| EncryptedStateError::AuthenticationFailed)?;
    Ok(Envelope {
        format: FORMAT.to_owned(),
        purpose: purpose.to_owned(),
        nonce: STANDARD.encode(nonce),
        ciphertext: STANDARD.encode(ciphertext),
        tag: STANDARD.encode(tag),
    })
}

pub fn open(
    envelope: &Envelope,
    master_key: &[u8],
    purpose: &str,
) -> Result<Vec<u8>, EncryptedStateError> {
    if envelope.format != FORMAT || envelope.purpose != purpose {
        return Err(EncryptedStateError::InvalidEnvelope);
    }
    let nonce = STANDARD
        .decode(&envelope.nonce)
        .map_err(|_| EncryptedStateError::InvalidEnvelope)?;
    let mut ciphertext = STANDARD
        .decode(&envelope.ciphertext)
        .map_err(|_| EncryptedStateError::InvalidEnvelope)?;
    let tag = STANDARD
        .decode(&envelope.tag)
        .map_err(|_| EncryptedStateError::InvalidEnvelope)?;
    if nonce.len() != 12 || tag.len() != 16 {
        return Err(EncryptedStateError::InvalidEnvelope);
    }
    let key = derive_key(master_key)?;
    let cipher = Aes256Gcm::new_from_slice(&key).expect("derived key is 32 bytes");
    let aad = format!("{AAD_PREFIX}{purpose}");
    cipher
        .decrypt_in_place_detached(
            Nonce::from_slice(&nonce),
            aad.as_bytes(),
            &mut ciphertext,
            Tag::from_slice(&tag),
        )
        .map_err(|_| EncryptedStateError::AuthenticationFailed)?;
    Ok(ciphertext)
}

fn derive_key(master_key: &[u8]) -> Result<[u8; 32], EncryptedStateError> {
    if master_key.len() != 32 {
        return Err(EncryptedStateError::InvalidKey);
    }
    let hkdf = Hkdf::<Sha256>::new(Some(KEY_SALT), master_key);
    let mut key = [0; 32];
    hkdf.expand(KEY_INFO, &mut key)
        .expect("32-byte output is valid for HKDF-SHA256");
    Ok(key)
}
