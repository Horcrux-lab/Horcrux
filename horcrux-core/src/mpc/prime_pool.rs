//! Paillier safe-prime pool.
//!
//! CGGMP21's aux-info round needs a pair of 4·SECURITY_BITS safe primes per
//! participant. Generating them is CPU-bound and, on iOS where GMP runs
//! without assembly, often takes 30–300 seconds. The DKG ceremony stalls
//! visibly on the user.
//!
//! This module caches pre-generated `PregeneratedPrimes` on disk. During
//! idle time (e.g. didBecomeActive on iOS) the host asks the pool to
//! pre-fill. When a DKG or refresh ceremony starts, it pops one entry in
//! microseconds.
//!
//! Trust model:
//! - Each prime pair is **single-use**. After `try_take` reads a file it is
//!   deleted before being returned — never reused across ceremonies.
//! - Entries are generated with `OsRng` (iOS `SecRandomCopyBytes`), so each
//!   pair is independent.
//! - The caller (iOS) is responsible for placing the pool directory under
//!   appropriate Data Protection; this module only speaks `std::fs`.
//!
//! Concurrency:
//! - `try_take` uses rename-to-claim so multiple callers never hand out the
//!   same entry. A failed rename means another thread already took it.
//! - `generate_one` writes to a temp file then atomically renames into place.

use cggmp21::security_level::SecurityLevel128;
use cggmp21::PregeneratedPrimes;
use rand::rngs::OsRng;
use rand::RngCore;
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{OnceLock, RwLock};
use std::time::{SystemTime, UNIX_EPOCH};

/// Serialized form on disk. We wrap the primes with a version tag so future
/// incompatible changes can be detected and orphaned files cleaned up.
#[derive(Serialize, Deserialize)]
struct Envelope {
    version: u8,
    primes: PregeneratedPrimes<SecurityLevel128>,
}

const CURRENT_VERSION: u8 = 1;
const FILE_PREFIX: &str = "primes_secp256k1_L128_";
const FILE_SUFFIX: &str = ".bin";
const TAKEN_SUFFIX: &str = ".taken";

static POOL_DIR: OnceLock<RwLock<Option<PathBuf>>> = OnceLock::new();

fn slot() -> &'static RwLock<Option<PathBuf>> {
    POOL_DIR.get_or_init(|| RwLock::new(None))
}

/// Install the pool directory. Creates the directory if missing.
/// Re-calls overwrite the previous configuration.
pub fn init(dir: impl Into<PathBuf>) -> Result<(), String> {
    let dir = dir.into();
    fs::create_dir_all(&dir).map_err(|e| format!("create pool dir: {e}"))?;
    // Sweep stale .taken files from a previous crash.
    if let Ok(entries) = fs::read_dir(&dir) {
        for e in entries.flatten() {
            if e.file_name().to_string_lossy().ends_with(TAKEN_SUFFIX) {
                let _ = fs::remove_file(e.path());
            }
        }
    }
    *slot().write().map_err(|e| format!("lock: {e}"))? = Some(dir);
    Ok(())
}

/// Current number of available pregenerated prime pairs.
pub fn count() -> u32 {
    let guard = match slot().read() {
        Ok(g) => g,
        Err(_) => return 0,
    };
    let Some(dir) = guard.as_ref() else {
        return 0;
    };
    count_in(dir)
}

fn count_in(dir: &Path) -> u32 {
    fs::read_dir(dir)
        .map(|it| {
            it.flatten()
                .filter(|e| {
                    let n = e.file_name();
                    let s = n.to_string_lossy();
                    s.starts_with(FILE_PREFIX) && s.ends_with(FILE_SUFFIX)
                })
                .count() as u32
        })
        .unwrap_or(0)
}

/// Try to pop one entry from the pool. Returns `None` if empty or disabled.
pub fn try_take() -> Option<PregeneratedPrimes<SecurityLevel128>> {
    let dir = slot().read().ok()?.as_ref()?.clone();
    let entries = fs::read_dir(&dir).ok()?;
    for e in entries.flatten() {
        let name = e.file_name();
        let s = name.to_string_lossy();
        if !(s.starts_with(FILE_PREFIX) && s.ends_with(FILE_SUFFIX)) {
            continue;
        }
        // Atomic claim via rename — only one racer wins.
        let taken = e.path().with_extension(format!("bin{TAKEN_SUFFIX}"));
        if fs::rename(e.path(), &taken).is_err() {
            continue;
        }
        let data = match fs::read(&taken) {
            Ok(d) => d,
            Err(_) => {
                let _ = fs::remove_file(&taken);
                continue;
            }
        };
        let _ = fs::remove_file(&taken);
        match serde_json::from_slice::<Envelope>(&data) {
            Ok(env) if env.version == CURRENT_VERSION => return Some(env.primes),
            _ => continue, // skip corrupted / wrong-version entries
        }
    }
    None
}

/// Generate one prime pair and stash it in the pool. Blocks the calling
/// thread (expected to be a low-priority background thread on iOS).
pub fn generate_one() -> Result<(), String> {
    let dir = slot()
        .read()
        .map_err(|e| format!("lock: {e}"))?
        .as_ref()
        .ok_or_else(|| "pool not initialized".to_string())?
        .clone();
    let mut rng = OsRng;
    let primes = PregeneratedPrimes::<SecurityLevel128>::generate(&mut rng);
    let env = Envelope {
        version: CURRENT_VERSION,
        primes,
    };
    let bytes = serde_json::to_vec(&env).map_err(|e| format!("serialize: {e}"))?;
    // M3 (audit `docs/security-audit-2026-04.md`): use a wall-clock + 64 bit
    // OsRng nonce for the on-disk filename so two background producers
    // hitting `generate_one()` on the same nanosecond can't collide on a
    // tmp path and clobber each other's writes. Atomic rename then
    // promotes tmp → final, so a partial write is never observed by
    // `try_take`. The previous nanosecond-only nonce was theoretically
    // racy on multi-core devices that happened to schedule both threads
    // through the same clock tick.
    let ns = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let mut salt_buf = [0u8; 8];
    OsRng.fill_bytes(&mut salt_buf);
    let salt = u64::from_le_bytes(salt_buf);
    let nonce = format!("{ns:x}-{salt:016x}");
    let tmp = dir.join(format!("{FILE_PREFIX}{nonce}.tmp"));
    let final_path = dir.join(format!("{FILE_PREFIX}{nonce}{FILE_SUFFIX}"));
    fs::write(&tmp, &bytes).map_err(|e| format!("write tmp: {e}"))?;
    fs::rename(&tmp, &final_path).map_err(|e| format!("rename: {e}"))?;
    Ok(())
}

/// Take one from the pool or fall back to generating synchronously.
pub fn take_or_generate() -> PregeneratedPrimes<SecurityLevel128> {
    if let Some(p) = try_take() {
        return p;
    }
    let mut rng = OsRng;
    PregeneratedPrimes::<SecurityLevel128>::generate(&mut rng)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    use tempfile::tempdir;

    // The pool is a process-wide singleton. Tests must run serially.
    static LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn roundtrip_generate_and_take() {
        let _g = LOCK.lock().unwrap();
        let d = tempdir().unwrap();
        init(d.path()).unwrap();
        assert_eq!(count(), 0);
        generate_one().unwrap();
        assert_eq!(count(), 1);
        let p = try_take();
        assert!(p.is_some());
        assert_eq!(count(), 0);
        assert!(try_take().is_none());
    }

    #[test]
    fn take_or_generate_never_none() {
        let _g = LOCK.lock().unwrap();
        let d = tempdir().unwrap();
        init(d.path()).unwrap();
        let _ = take_or_generate();
    }
}
