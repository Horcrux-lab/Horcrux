//! Shard storage — local encrypted persistence.

use super::crypto::EncryptedShard;
use std::path::PathBuf;

/// Handles reading/writing encrypted shards to local storage.
pub struct ShardStorage {
    base_dir: PathBuf,
}

impl ShardStorage {
    pub fn new(base_dir: PathBuf) -> Self {
        Self { base_dir }
    }

    /// Save an encrypted shard to disk.
    pub fn save(&self, shard_id: &str, encrypted: &EncryptedShard) -> Result<(), String> {
        let path = self.base_dir.join(format!("{}.shard", shard_id));
        let data =
            serde_json::to_vec(encrypted).map_err(|e| format!("serialization failed: {}", e))?;
        std::fs::create_dir_all(&self.base_dir)
            .map_err(|e| format!("failed to create dir: {}", e))?;
        std::fs::write(&path, data).map_err(|e| format!("failed to write shard: {}", e))?;
        Ok(())
    }

    /// Load an encrypted shard from disk.
    pub fn load(&self, shard_id: &str) -> Result<EncryptedShard, String> {
        let path = self.base_dir.join(format!("{}.shard", shard_id));
        let data = std::fs::read(&path).map_err(|e| format!("failed to read shard: {}", e))?;
        serde_json::from_slice(&data).map_err(|e| format!("deserialization failed: {}", e))
    }

    /// List all shard IDs in storage.
    pub fn list_shard_ids(&self) -> Result<Vec<String>, String> {
        let entries =
            std::fs::read_dir(&self.base_dir).map_err(|e| format!("failed to read dir: {}", e))?;

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
    pub fn delete(&self, shard_id: &str) -> Result<(), String> {
        let path = self.base_dir.join(format!("{}.shard", shard_id));
        std::fs::remove_file(&path).map_err(|e| format!("failed to delete shard: {}", e))
    }
}
