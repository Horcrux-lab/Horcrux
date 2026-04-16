//! Shard encryption — AES-256-GCM with key derived from device key + PIN.

use aes_gcm::{Aes256Gcm, Key, Nonce};
use aes_gcm::aead::{Aead, KeyInit};
use hkdf::Hkdf;
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

/// Derive an AES-256 key from device key + user PIN.
pub fn derive_key(device_key: &[u8], pin: &[u8], salt: &[u8]) -> [u8; KEY_SIZE] {
    let mut ikm = Vec::with_capacity(device_key.len() + pin.len());
    ikm.extend_from_slice(device_key);
    ikm.extend_from_slice(pin);

    let hk = Hkdf::<Sha256>::new(Some(salt), &ikm);
    let mut key = [0u8; KEY_SIZE];
    hk.expand(b"horcrux-shard-encryption", &mut key)
        .expect("HKDF expand failed");

    ikm.zeroize();
    key
}

/// Encrypt a shard's secret data.
pub fn encrypt_shard(
    plaintext: &[u8],
    device_key: &[u8],
    pin: &[u8],
) -> Result<EncryptedShard, String> {
    let mut salt = [0u8; 16];
    rand::thread_rng().fill_bytes(&mut salt);

    let mut key = derive_key(device_key, pin, &salt);

    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(&key));

    let mut nonce_bytes = [0u8; NONCE_SIZE];
    rand::thread_rng().fill_bytes(&mut nonce_bytes);
    let nonce = Nonce::from_slice(&nonce_bytes);

    let ciphertext = cipher
        .encrypt(nonce, plaintext)
        .map_err(|e| format!("encryption failed: {}", e))?;

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
) -> Result<Zeroizing<Vec<u8>>, String> {
    let mut key = derive_key(device_key, pin, &encrypted.salt);

    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(&key));
    let nonce = Nonce::from_slice(&encrypted.nonce);

    let plaintext = cipher
        .decrypt(nonce, encrypted.ciphertext.as_ref())
        .map_err(|e| format!("decryption failed: {}", e))?;

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
}
