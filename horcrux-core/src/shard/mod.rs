//! Shard storage, encryption, and management.

pub mod crypto;
pub mod storage;

use serde::{Deserialize, Serialize};

/// Manages shard lifecycle: creation, storage, backup, refresh.
#[derive(Debug)]
pub struct ShardManager {
    shards: Vec<ShardInfo>,
}

/// Metadata about a stored shard.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ShardInfo {
    /// Unique shard identifier
    pub shard_id: String,
    /// Associated wallet public key
    pub public_key: Vec<u8>,
    /// Party index for this shard
    pub party_index: u16,
    /// Threshold required
    pub threshold: u16,
    /// Total parties
    pub total_parties: u16,
    /// Which curve this shard is for
    pub curve: crate::mpc::CurveType,
    /// Creation timestamp (unix seconds)
    pub created_at: u64,
    /// Whether the shard data is stored locally
    pub is_local: bool,
}

impl ShardManager {
    pub fn new() -> Self {
        Self { shards: Vec::new() }
    }

    /// Register a new shard after DKG completion.
    pub fn add_shard(&mut self, info: ShardInfo) {
        self.shards.push(info);
    }

    /// List all known shards.
    pub fn list_shards(&self) -> &[ShardInfo] {
        &self.shards
    }

    /// Find shards for a given public key.
    pub fn shards_for_key(&self, public_key: &[u8]) -> Vec<&ShardInfo> {
        self.shards
            .iter()
            .filter(|s| s.public_key == public_key)
            .collect()
    }
}

impl Default for ShardManager {
    fn default() -> Self {
        Self::new()
    }
}
