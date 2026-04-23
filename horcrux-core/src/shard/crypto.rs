//! Shard encryption — AES-256-GCM with key derived from device key + PIN.

use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Key, Nonce};
use hkdf::Hkdf;
use rand::rngs::OsRng;
use rand::RngCore;
use sha2::Sha256;
use zeroize::{Zeroize, Zeroizing};

const NONCE_SIZE: usize = 12;
const KEY_SIZE: usize = 32;

/// Encrypted shard blob stored on disk.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct EncryptedShard {
    /// AES-256-GCM nonce
    pub nonce: Vec<u8>,
    /// Encrypted shard data + authentication tag
    pub ciphertext: Vec<u8>,
    /// Salt used for key derivation
    pub salt: Vec<u8>,
}

/// Errors from shard encryption operations.
#[derive(Debug, thiserror::Error)]
pub enum ShardCryptoError {
    #[error("key derivation failed: {0}")]
    KeyDerivation(String),
    #[error("encryption failed: {0}")]
    Encryption(String),
    #[error("decryption failed: {0}")]
    Decryption(String),
}

/// Derive an AES-256 key from device key + user PIN.
pub fn derive_key(
    device_key: &[u8],
    pin: &[u8],
    salt: &[u8],
) -> Result<[u8; KEY_SIZE], ShardCryptoError> {
    let mut ikm = Vec::with_capacity(device_key.len() + pin.len());
    ikm.extend_from_slice(device_key);
    ikm.extend_from_slice(pin);

    let hk = Hkdf::<Sha256>::new(Some(salt), &ikm);
    let mut key = [0u8; KEY_SIZE];
    hk.expand(b"horcrux-shard-encryption", &mut key)
        .map_err(|e| ShardCryptoError::KeyDerivation(format!("{e}")))?;

    ikm.zeroize();
    Ok(key)
}

/// Encrypt a shard's secret data.
pub fn encrypt_shard(
    plaintext: &[u8],
    device_key: &[u8],
    pin: &[u8],
) -> Result<EncryptedShard, ShardCryptoError> {
    let mut salt = [0u8; 16];
    OsRng.fill_bytes(&mut salt);

    let mut key = derive_key(device_key, pin, &salt)?;

    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(&key));

    let mut nonce_bytes = [0u8; NONCE_SIZE];
    OsRng.fill_bytes(&mut nonce_bytes);
    let nonce = Nonce::from_slice(&nonce_bytes);

    let ciphertext = cipher
        .encrypt(nonce, plaintext)
        .map_err(|e| ShardCryptoError::Encryption(format!("{e}")))?;

    key.zeroize();

    Ok(EncryptedShard {
        nonce: nonce_bytes.to_vec(),
        ciphertext,
        salt: salt.to_vec(),
    })
}

/// Decrypt a shard's secret data.
/// The returned `Zeroizing<Vec<u8>>` automatically zeroes memory when dropped.
pub fn decrypt_shard(
    encrypted: &EncryptedShard,
    device_key: &[u8],
    pin: &[u8],
) -> Result<Zeroizing<Vec<u8>>, ShardCryptoError> {
    let mut key = derive_key(device_key, pin, &encrypted.salt)?;

    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(&key));
    let nonce = Nonce::from_slice(&encrypted.nonce);

    let plaintext = cipher
        .decrypt(nonce, encrypted.ciphertext.as_ref())
        .map_err(|e| ShardCryptoError::Decryption(format!("{e}")))?;

    key.zeroize();

    Ok(Zeroizing::new(plaintext))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encrypt_decrypt_roundtrip() {
        let shard_data = b"secret-shard-data-for-party-1";
        let device_key = b"device-secure-enclave-key-bytes!";
        let pin = b"123456";

        let encrypted = encrypt_shard(shard_data, device_key, pin).unwrap();
        let decrypted = decrypt_shard(&encrypted, device_key, pin).unwrap();

        assert_eq!(shard_data.as_slice(), &*decrypted);
    }

    #[test]
    fn test_wrong_pin_fails() {
        let shard_data = b"secret-shard-data";
        let device_key = b"device-secure-enclave-key-bytes!";

        let encrypted = encrypt_shard(shard_data, device_key, b"correct").unwrap();
        let result = decrypt_shard(&encrypted, device_key, b"wrong");

        assert!(result.is_err());
    }

    #[test]
    fn test_wrong_device_key_fails() {
        let shard_data = b"secret-shard-data";
        let encrypted =
            encrypt_shard(shard_data, b"device-key-A--------------------", b"pin").unwrap();
        let result = decrypt_shard(&encrypted, b"device-key-B--------------------", b"pin");
        assert!(result.is_err());
    }

    #[test]
    fn test_nonce_salt_unique_across_calls() {
        // Same inputs must produce different ciphertexts (fresh random
        // salt+nonce per call). If this ever regresses, two shards
        // encrypted to the same device/PIN would be bit-identical.
        let data = b"aaaa";
        let e1 = encrypt_shard(data, b"dk".repeat(16).as_slice(), b"pin").unwrap();
        let e2 = encrypt_shard(data, b"dk".repeat(16).as_slice(), b"pin").unwrap();
        assert_ne!(e1.nonce, e2.nonce);
        assert_ne!(e1.salt, e2.salt);
        assert_ne!(e1.ciphertext, e2.ciphertext);
    }

    #[test]
    fn test_ciphertext_tamper_rejected() {
        let encrypted =
            encrypt_shard(b"sensitive", b"device-key".repeat(4).as_slice(), b"pin").unwrap();
        let mut tampered = encrypted.clone();
        // Flip a bit in the middle of the ciphertext.
        let mid = tampered.ciphertext.len() / 2;
        tampered.ciphertext[mid] ^= 0x01;
        let result = decrypt_shard(&tampered, b"device-key".repeat(4).as_slice(), b"pin");
        assert!(
            result.is_err(),
            "AES-GCM must reject bitflips (MAC failure)"
        );
    }

    #[test]
    fn test_derive_key_deterministic() {
        let k1 = derive_key(b"dk", b"pin", b"salt").unwrap();
        let k2 = derive_key(b"dk", b"pin", b"salt").unwrap();
        assert_eq!(k1, k2);
    }

    #[test]
    fn test_derive_key_diverges_on_salt() {
        let k1 = derive_key(b"dk", b"pin", b"salt1").unwrap();
        let k2 = derive_key(b"dk", b"pin", b"salt2").unwrap();
        assert_ne!(k1, k2);
    }
}

#[cfg(test)]
mod prop_tests {
    //! Property-based coverage for the shard-encryption round-trip.
    //!
    //! These proptests (256 cases each → ~1 024 randomized encrypt/decrypt
    //! invocations per CI run) guard the invariants that unit tests can't
    //! exhaustively enumerate:
    //!
    //! 1. **Round-trip**: `decrypt(encrypt(x)) == x` for any plaintext /
    //!    device-key / PIN triple.
    //! 2. **Wrong-PIN rejection**: a mismatched PIN must yield `Err`
    //!    (AES-GCM MAC failure), never a different plaintext.
    //! 3. **Wrong-device-key rejection**: same, for the Secure-Enclave
    //!    material.
    //! 4. **Freshness**: two encryptions of the same input are always
    //!    bit-distinct (fresh random salt + nonce per call).
    //!
    //! If any of these regress, shard confidentiality or uniqueness
    //! across devices / backups is compromised.
    use super::*;
    use proptest::prelude::*;

    proptest! {
        #![proptest_config(ProptestConfig { cases: 256, ..ProptestConfig::default() })]

        #[test]
        fn prop_roundtrip_any_inputs(
            plaintext in prop::collection::vec(any::<u8>(), 0..1024),
            device_key in prop::collection::vec(any::<u8>(), 16..64),
            pin in prop::collection::vec(any::<u8>(), 4..32),
        ) {
            let enc = encrypt_shard(&plaintext, &device_key, &pin).unwrap();
            let dec = decrypt_shard(&enc, &device_key, &pin).unwrap();
            prop_assert_eq!(plaintext.as_slice(), &*dec);
        }

        #[test]
        fn prop_wrong_pin_rejected(
            plaintext in prop::collection::vec(any::<u8>(), 1..256),
            device_key in prop::collection::vec(any::<u8>(), 16..32),
            pin_a in prop::collection::vec(any::<u8>(), 4..16),
            pin_b in prop::collection::vec(any::<u8>(), 4..16),
        ) {
            prop_assume!(pin_a != pin_b);
            let enc = encrypt_shard(&plaintext, &device_key, &pin_a).unwrap();
            prop_assert!(decrypt_shard(&enc, &device_key, &pin_b).is_err());
        }

        #[test]
        fn prop_wrong_device_key_rejected(
            plaintext in prop::collection::vec(any::<u8>(), 1..256),
            dk_a in prop::collection::vec(any::<u8>(), 16..32),
            dk_b in prop::collection::vec(any::<u8>(), 16..32),
            pin in prop::collection::vec(any::<u8>(), 4..16),
        ) {
            prop_assume!(dk_a != dk_b);
            let enc = encrypt_shard(&plaintext, &dk_a, &pin).unwrap();
            prop_assert!(decrypt_shard(&enc, &dk_b, &pin).is_err());
        }

        #[test]
        fn prop_freshness_across_calls(
            plaintext in prop::collection::vec(any::<u8>(), 1..256),
            device_key in prop::collection::vec(any::<u8>(), 16..32),
            pin in prop::collection::vec(any::<u8>(), 4..16),
        ) {
            let e1 = encrypt_shard(&plaintext, &device_key, &pin).unwrap();
            let e2 = encrypt_shard(&plaintext, &device_key, &pin).unwrap();
            prop_assert_ne!(&e1.nonce, &e2.nonce);
            prop_assert_ne!(&e1.salt, &e2.salt);
            prop_assert_ne!(&e1.ciphertext, &e2.ciphertext);
        }

        /// AES-GCM authenticates every byte of ciphertext + nonce + salt
        /// (salt is mixed into HKDF output that keys the cipher). Any
        /// single-byte flip at any position must cause MAC failure on
        /// decrypt. Unit test `test_ciphertext_tamper_rejected` covers
        /// one mid-ciphertext flip; this property sweeps the whole
        /// `(field, byte_index, bit_mask)` space to catch an authenticity
        /// regression — e.g. a future refactor that accidentally stops
        /// binding the salt to the derived key.
        #[test]
        fn prop_single_byte_tamper_rejected(
            plaintext in prop::collection::vec(any::<u8>(), 1..128),
            device_key in prop::collection::vec(any::<u8>(), 16..32),
            pin in prop::collection::vec(any::<u8>(), 4..16),
            field_sel in 0u8..3,
            bit_mask in 1u8..=255,
            offset_seed in any::<usize>(),
        ) {
            let enc = encrypt_shard(&plaintext, &device_key, &pin).unwrap();
            let mut tampered = enc.clone();
            match field_sel {
                0 => {
                    let len = tampered.ciphertext.len();
                    if len == 0 { return Ok(()); }
                    let idx = offset_seed % len;
                    tampered.ciphertext[idx] ^= bit_mask;
                }
                1 => {
                    let len = tampered.nonce.len();
                    if len == 0 { return Ok(()); }
                    let idx = offset_seed % len;
                    tampered.nonce[idx] ^= bit_mask;
                }
                _ => {
                    let len = tampered.salt.len();
                    if len == 0 { return Ok(()); }
                    let idx = offset_seed % len;
                    tampered.salt[idx] ^= bit_mask;
                }
            }
            prop_assert!(
                decrypt_shard(&tampered, &device_key, &pin).is_err(),
                "single-byte tamper must fail decrypt (field_sel={}, mask={:#04x})",
                field_sel,
                bit_mask
            );
        }
    }
}
