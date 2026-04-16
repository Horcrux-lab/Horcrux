//! Shard storage — local encrypted persistence.

use super::crypto::EncryptedShard;
use std::path::PathBuf;

/// Errors from shard storage operations.
#[derive(Debug, thiserror::Error)]
pub enum ShardStorageError {
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),
    #[error("serialization failed: {0}")]
    Serialization(#[from] serde_json::Error),
}

/// Handles reading/writing encrypted shards to local storage.
pub struct ShardStorage {
    base_dir: PathBuf,
}

impl ShardStorage {
    pub fn new(base_dir: PathBuf) -> Self {
        Self { base_dir }
    }

    /// Save an encrypted shard to disk.
    pub fn save(
        &self,
        shard_id: &str,
        encrypted: &EncryptedShard,
    ) -> Result<(), ShardStorageError> {
        let path = self.base_dir.join(format!("{shard_id}.shard"));
        let data = serde_json::to_vec(encrypted)?;
        std::fs::create_dir_all(&self.base_dir)?;
        std::fs::write(&path, data)?;
        Ok(())
    }

    /// Load an encrypted shard from disk.
    pub fn load(&self, shard_id: &str) -> Result<EncryptedShard, ShardStorageError> {
        let path = self.base_dir.join(format!("{shard_id}.shard"));
        let data = std::fs::read(&path)?;
        Ok(serde_json::from_slice(&data)?)
    }

    /// List all shard IDs in storage.
    pub fn list_shard_ids(&self) -> Result<Vec<String>, ShardStorageError> {
        let entries = std::fs::read_dir(&self.base_dir)?;

        let mut ids = Vec::new();
        for entry in entries.flatten() {
            if let Some(name) = entry.file_name().to_str() {
                if let Some(id) = name.strip_suffix(".shard") {
                    ids.push(id.to_string());
                }
            }
        }
        Ok(ids)
    }

    /// Delete a shard from storage.
    pub fn delete(&self, shard_id: &str) -> Result<(), ShardStorageError> {
        let path = self.base_dir.join(format!("{shard_id}.shard"));
        std::fs::remove_file(&path)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::shard::crypto::{encrypt_shard, EncryptedShard};

    fn temp_storage() -> (ShardStorage, tempfile::TempDir) {
        let dir = tempfile::tempdir().unwrap();
        let storage = ShardStorage::new(dir.path().to_path_buf());
        (storage, dir)
    }

    fn sample_encrypted() -> EncryptedShard {
        encrypt_shard(b"secret-data", b"device-key-32-bytes-long-enough!", b"1234").unwrap()
    }

    #[test]
    fn save_and_load_roundtrip() {
        let (storage, _dir) = temp_storage();
        let encrypted = sample_encrypted();
        storage.save("shard-1", &encrypted).unwrap();
        let loaded = storage.load("shard-1").unwrap();
        assert_eq!(encrypted.ciphertext, loaded.ciphertext);
        assert_eq!(encrypted.nonce, loaded.nonce);
        assert_eq!(encrypted.salt, loaded.salt);
    }

    #[test]
    fn load_nonexistent_returns_error() {
        let (storage, _dir) = temp_storage();
        let result = storage.load("does-not-exist");
        assert!(result.is_err());
    }

    #[test]
    fn list_shard_ids_empty() {
        let (storage, _dir) = temp_storage();
        let ids = storage.list_shard_ids().unwrap();
        assert!(ids.is_empty());
    }

    #[test]
    fn list_shard_ids_returns_saved() {
        let (storage, _dir) = temp_storage();
        storage.save("alpha", &sample_encrypted()).unwrap();
        storage.save("beta", &sample_encrypted()).unwrap();
        let mut ids = storage.list_shard_ids().unwrap();
        ids.sort();
        assert_eq!(ids, vec!["alpha", "beta"]);
    }

    #[test]
    fn delete_removes_shard() {
        let (storage, _dir) = temp_storage();
        storage.save("to-delete", &sample_encrypted()).unwrap();
        assert!(storage.load("to-delete").is_ok());
        storage.delete("to-delete").unwrap();
        assert!(storage.load("to-delete").is_err());
    }

    #[test]
    fn delete_nonexistent_returns_error() {
        let (storage, _dir) = temp_storage();
        assert!(storage.delete("ghost").is_err());
    }

    #[test]
    fn save_creates_directory() {
        let dir = tempfile::tempdir().unwrap();
        let nested = dir.path().join("sub").join("dir");
        let storage = ShardStorage::new(nested);
        storage.save("test", &sample_encrypted()).unwrap();
        let loaded = storage.load("test").unwrap();
        assert!(!loaded.ciphertext.is_empty());
    }
}
