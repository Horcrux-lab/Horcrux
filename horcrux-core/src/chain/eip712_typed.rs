//! EIP-712 typed data (v4) digest helper.
//!
//! This module provides a single entry point — [`eip712_digest_from_typed_data_json`] —
//! that consumes a JSON blob in the canonical
//! `eth_signTypedData_v4` shape (dApp / WalletConnect format):
//!
//! ```json
//! {
//!   "types": {
//!     "EIP712Domain": [ {"name":"name","type":"string"}, ... ],
//!     "Person":       [ {"name":"name","type":"string"}, {"name":"wallet","type":"address"} ],
//!     "Mail":         [ {"name":"from","type":"Person"}, {"name":"to","type":"Person"}, ... ]
//!   },
//!   "primaryType": "Mail",
//!   "domain":  { "name": "...", "chainId": 1, "verifyingContract": "0x..." },
//!   "message": { "from": { ... }, "to": { ... }, "contents": "..." }
//! }
//! ```
//!
//! and returns the 32-byte digest that the MPC ceremony will sign
//! (`keccak256(0x19 || 0x01 || domain_separator || struct_hash)`).
//!
//! **Security**: this helper rebuilds the domain separator from the
//! exact `types.EIP712Domain` field list declared in the payload
//! (dApps like Permit2 omit `version`, so a hard-coded 4-field
//! separator would produce the wrong digest). The audit-H8
//! replay-binding guards — non-zero `chainId`, non-zero
//! `verifyingContract`, non-empty `name` — are applied directly on
//! the JSON domain object whenever those fields are declared, so a
//! caller that tries to submit a domain with `chainId = 0` or
//! `verifyingContract = 0x000…000` hits the same rejection as the
//! UI-bound path. The JSON parser itself also rejects malformed
//! numerics, unknown types, and circular type references.
//!
//! **Out of scope** (explicitly not supported to keep the surface
//! small and audit-reviewable):
//! - EIP-712 v1 / v3 (pre-v4 nested-struct bugs)
//! - `bytes` / `string` arrays with empty elements mixed with
//!   non-empty — supported but producing a deterministic output
//! - recursive / self-referential types (detected; rejected)

use std::{
    collections::{BTreeMap, BTreeSet},
    format,
    string::{String, ToString},
    vec::Vec,
};

use serde_json::Value;

use super::{keccak256, ChainError};

/// Parse an `eth_signTypedData_v4` JSON blob and compute the EIP-712
/// digest. Returns the 32-byte signable hash on success.
pub fn eip712_digest_from_typed_data_json(json: &str) -> Result<[u8; 32], ChainError> {
    let root: Value =
        serde_json::from_str(json).map_err(|e| ChainError::Other(format!("invalid JSON: {e}")))?;
    let root_obj = root
        .as_object()
        .ok_or_else(|| ChainError::Other("typed data must be a JSON object".to_string()))?;

    // --- types -----------------------------------------------------
    let types_raw = root_obj
        .get("types")
        .and_then(Value::as_object)
        .ok_or_else(|| ChainError::Other("missing `types` object".to_string()))?;

    // Build: type_name -> Vec<(field_name, field_type)>
    let mut types: BTreeMap<String, Vec<(String, String)>> = BTreeMap::new();
    for (tname, fields) in types_raw {
        let arr = fields
            .as_array()
            .ok_or_else(|| ChainError::Other(format!("types.{tname} must be an array")))?;
        let mut out = Vec::with_capacity(arr.len());
        for f in arr {
            let fo = f
                .as_object()
                .ok_or_else(|| ChainError::Other(format!("types.{tname} field must be object")))?;
            let fname = fo
                .get("name")
                .and_then(Value::as_str)
                .ok_or_else(|| ChainError::Other(format!("types.{tname} field missing name")))?;
            let ftype = fo
                .get("type")
                .and_then(Value::as_str)
                .ok_or_else(|| ChainError::Other(format!("types.{tname} field missing type")))?;
            out.push((fname.to_string(), ftype.to_string()));
        }
        types.insert(tname.to_string(), out);
    }

    if !types.contains_key("EIP712Domain") {
        return Err(ChainError::Other(
            "types must include `EIP712Domain`".to_string(),
        ));
    }

    // --- domain ----------------------------------------------------
    // The EIP-712 spec lets dApps omit any of the five optional
    // `EIP712Domain` fields (name, version, chainId,
    // verifyingContract, salt). Permit2 is a real-world example: its
    // domain has only `{name, chainId, verifyingContract}` — no
    // `version`. Because the domain separator is
    // `hashStruct(EIP712Domain, domain)`, it MUST be built from the
    // exact field list declared in `types.EIP712Domain`, not a
    // hard-coded 4-field type. We therefore reuse the generic
    // `hash_struct` encoder on the domain object itself and apply the
    // audit-H8 replay-binding guards separately (we don't delegate to
    // `eip712_digest`, which assumes the fixed 4-field shape that's
    // used by the UI-bound call-site).
    let domain_val = root_obj
        .get("domain")
        .ok_or_else(|| ChainError::Other("missing `domain` object".to_string()))?;
    enforce_h8_guards(domain_val, types.get("EIP712Domain"))?;
    let domain_separator = hash_struct("EIP712Domain", domain_val, &types)?;

    // --- primary struct hash ---------------------------------------
    let primary_type = root_obj
        .get("primaryType")
        .and_then(Value::as_str)
        .ok_or_else(|| ChainError::Other("missing `primaryType`".to_string()))?;

    let message = root_obj
        .get("message")
        .ok_or_else(|| ChainError::Other("missing `message`".to_string()))?;

    let struct_hash = hash_struct(primary_type, message, &types)?;

    // Final digest: keccak256(0x19 || 0x01 || ds || hs)
    let mut pre = Vec::with_capacity(2 + 32 + 32);
    pre.push(0x19);
    pre.push(0x01);
    pre.extend_from_slice(&domain_separator);
    pre.extend_from_slice(&struct_hash);
    Ok(keccak256(&pre))
}

/// Audit H8 guards on the JSON-bound path. We read straight from the
/// dApp's domain object rather than routing through `Eip712Domain` so
/// the same field list (name / version / chainId / verifyingContract
/// / salt, any subset thereof) carries through to the separator. Any
/// one of the replay-binding values that the dApp *does* declare must
/// be non-trivial:
///   - `chainId` — rejected if present and zero (any-chain replay);
///   - `verifyingContract` — rejected if present and `0x000…000`
///     (any-contract replay);
///   - `name` — rejected if present and empty after trimming.
///
/// If a field is absent from `types.EIP712Domain` (so absent from the
/// separator), we do not require it.
fn enforce_h8_guards(
    domain_val: &Value,
    domain_type: Option<&Vec<(String, String)>>,
) -> Result<(), ChainError> {
    let obj = domain_val
        .as_object()
        .ok_or_else(|| ChainError::Other("domain must be an object".to_string()))?;
    let declared: BTreeSet<&str> = domain_type
        .into_iter()
        .flat_map(|v| v.iter().map(|(n, _)| n.as_str()))
        .collect();

    if declared.contains("chainId") {
        let cid = parse_u64(obj.get("chainId"), "domain.chainId")?;
        if cid == 0 {
            return Err(ChainError::Other(
                "EIP-712 domain chain_id must be non-zero (chain_id=0 allows cross-chain replay)"
                    .to_string(),
            ));
        }
    }
    if declared.contains("verifyingContract") {
        let v = obj
            .get("verifyingContract")
            .ok_or_else(|| ChainError::Other("missing domain.verifyingContract".to_string()))?;
        let addr = parse_address(v, "domain.verifyingContract")?;
        if addr == [0u8; 20] {
            return Err(ChainError::Other(
                "EIP-712 domain verifyingContract must be non-zero (0x0 allows cross-contract replay)"
                    .to_string(),
            ));
        }
    }
    if declared.contains("name") {
        let s = obj
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or("");
        if s.trim().is_empty() {
            return Err(ChainError::Other(
                "EIP-712 domain name must be non-empty".to_string(),
            ));
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------
// Domain extraction
// ---------------------------------------------------------------------

fn parse_u64(v: Option<&Value>, ctx: &str) -> Result<u64, ChainError> {
    let v = v.ok_or_else(|| ChainError::Other(format!("missing {ctx}")))?;
    if let Some(n) = v.as_u64() {
        return Ok(n);
    }
    if let Some(s) = v.as_str() {
        let s = s.trim();
        if let Some(hex) = s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")) {
            return u64::from_str_radix(hex, 16)
                .map_err(|e| ChainError::Other(format!("{ctx} hex parse: {e}")));
        }
        return s
            .parse::<u64>()
            .map_err(|e| ChainError::Other(format!("{ctx} dec parse: {e}")));
    }
    Err(ChainError::Other(format!("{ctx} must be number or string")))
}

fn parse_address(v: &Value, ctx: &str) -> Result<[u8; 20], ChainError> {
    let s = v
        .as_str()
        .ok_or_else(|| ChainError::Other(format!("{ctx} must be a hex string")))?;
    let hex = s
        .strip_prefix("0x")
        .or_else(|| s.strip_prefix("0X"))
        .unwrap_or(s);
    if hex.len() != 40 {
        return Err(ChainError::Other(format!(
            "{ctx} must be 20 bytes (40 hex chars), got {}",
            hex.len()
        )));
    }
    let raw = hex_decode(hex).map_err(|e| ChainError::Other(format!("{ctx}: {e}")))?;
    let mut out = [0u8; 20];
    out.copy_from_slice(&raw);

    // EIP-55 checksum validation: when the input has *mixed* case
    // (i.e. the dApp / WalletConnect client explicitly encoded the
    // checksum) we MUST verify it. A single-character typo in a
    // mixed-case address silently decodes to a valid 20-byte address
    // under pure hex decoding — the digest would then bind the
    // signature to the wrong recipient. All-lowercase and all-
    // uppercase inputs are accepted as-is (spec: "no checksum
    // information").
    let has_upper = hex.bytes().any(|b| b.is_ascii_uppercase());
    let has_lower = hex.bytes().any(|b| (b'a'..=b'f').contains(&b));
    if has_upper && has_lower && !eip55_matches(&out, hex) {
        return Err(ChainError::Other(format!(
            "{ctx}: EIP-55 checksum mismatch (address was given with \
             mixed case but the checksum does not match; check for typos)"
        )));
    }
    Ok(out)
}

/// EIP-55 checksum check. Returns true iff the case pattern of
/// `input_hex` (40 lowercase/uppercase hex chars, no `0x` prefix)
/// matches the canonical EIP-55 case of `addr`.
fn eip55_matches(addr: &[u8; 20], input_hex: &str) -> bool {
    // Canonical address is the *lowercase* hex of the 20 bytes.
    let lowered: String = addr.iter().map(|b| format!("{b:02x}")).collect();
    let hash = keccak256(lowered.as_bytes());
    // For each nibble position i in 0..40, the canonical case is
    // uppercase iff the i-th nibble of `hash` is >= 8.
    let hash_bytes = &hash[..];
    for (i, (in_ch, low_ch)) in input_hex.bytes().zip(lowered.bytes()).enumerate() {
        let nibble = if i & 1 == 0 {
            hash_bytes[i / 2] >> 4
        } else {
            hash_bytes[i / 2] & 0x0f
        };
        // Non-alpha nibbles (0-9) have no case — pass through.
        let canonical = if low_ch.is_ascii_alphabetic() && nibble >= 8 {
            low_ch.to_ascii_uppercase()
        } else {
            low_ch
        };
        if in_ch != canonical {
            return false;
        }
    }
    true
}

fn hex_decode(s: &str) -> Result<Vec<u8>, String> {
    if s.len() % 2 != 0 {
        return Err("odd-length hex string".to_string());
    }
    let mut out = Vec::with_capacity(s.len() / 2);
    let bytes = s.as_bytes();
    for i in (0..bytes.len()).step_by(2) {
        let hi = hex_nibble(bytes[i])?;
        let lo = hex_nibble(bytes[i + 1])?;
        out.push((hi << 4) | lo);
    }
    Ok(out)
}

fn hex_nibble(c: u8) -> Result<u8, String> {
    match c {
        b'0'..=b'9' => Ok(c - b'0'),
        b'a'..=b'f' => Ok(10 + c - b'a'),
        b'A'..=b'F' => Ok(10 + c - b'A'),
        _ => Err(format!("non-hex char {:?}", c as char)),
    }
}

// ---------------------------------------------------------------------
// Canonical type encoding (EIP-712 §5)
//   encodeType(primary) = primaryDef ‖ (deps(primary) sorted lex).map(def).join("")
//   typeHash(primary)   = keccak256(encodeType(primary))
// ---------------------------------------------------------------------

fn struct_type_of(ty: &str, types: &BTreeMap<String, Vec<(String, String)>>) -> Option<String> {
    // Strip array suffix `[]` or `[N]` if present, then check whether
    // the resulting base type names a user-defined struct.
    let base = match ty.rfind('[') {
        Some(i) if ty.ends_with(']') => &ty[..i],
        _ => ty,
    };
    if types.contains_key(base) {
        Some(base.to_string())
    } else {
        None
    }
}

fn find_deps(
    root: &str,
    types: &BTreeMap<String, Vec<(String, String)>>,
    acc: &mut BTreeSet<String>,
    stack: &mut BTreeSet<String>,
) -> Result<(), ChainError> {
    if !stack.insert(root.to_string()) {
        return Err(ChainError::Other(format!(
            "EIP-712 types: circular reference detected at `{root}`"
        )));
    }
    let fields = types
        .get(root)
        .ok_or_else(|| ChainError::Other(format!("EIP-712 types: unknown struct `{root}`")))?;
    for (_name, ty) in fields {
        if let Some(base) = struct_type_of(ty, types) {
            if acc.insert(base.clone()) {
                find_deps(&base, types, acc, stack)?;
            }
        }
    }
    stack.remove(root);
    Ok(())
}

fn encode_type(
    primary: &str,
    types: &BTreeMap<String, Vec<(String, String)>>,
) -> Result<String, ChainError> {
    let mut deps: BTreeSet<String> = BTreeSet::new();
    let mut stack: BTreeSet<String> = BTreeSet::new();
    find_deps(primary, types, &mut deps, &mut stack)?;
    // Remove primary from dep set — it goes first.
    deps.remove(primary);

    let mut out = String::new();
    out.push_str(&encode_single_type(primary, types)?);
    // BTreeSet iterates in sorted order — matches EIP-712 spec.
    for dep in &deps {
        out.push_str(&encode_single_type(dep, types)?);
    }
    Ok(out)
}

fn encode_single_type(
    name: &str,
    types: &BTreeMap<String, Vec<(String, String)>>,
) -> Result<String, ChainError> {
    let fields = types
        .get(name)
        .ok_or_else(|| ChainError::Other(format!("unknown type `{name}`")))?;
    let mut s = String::new();
    s.push_str(name);
    s.push('(');
    for (i, (fname, ftype)) in fields.iter().enumerate() {
        if i > 0 {
            s.push(',');
        }
        s.push_str(ftype);
        s.push(' ');
        s.push_str(fname);
    }
    s.push(')');
    Ok(s)
}

fn type_hash(
    name: &str,
    types: &BTreeMap<String, Vec<(String, String)>>,
) -> Result<[u8; 32], ChainError> {
    Ok(keccak256(encode_type(name, types)?.as_bytes()))
}

// ---------------------------------------------------------------------
// Data encoding (EIP-712 §5 — encodeData)
// ---------------------------------------------------------------------

fn hash_struct(
    primary: &str,
    data: &Value,
    types: &BTreeMap<String, Vec<(String, String)>>,
) -> Result<[u8; 32], ChainError> {
    let obj = data.as_object().ok_or_else(|| {
        ChainError::Other(format!("struct `{primary}` message must be an object"))
    })?;
    let fields = types
        .get(primary)
        .ok_or_else(|| ChainError::Other(format!("unknown struct `{primary}`")))?;

    let mut out = Vec::with_capacity(32 * (1 + fields.len()));
    out.extend_from_slice(&type_hash(primary, types)?);
    for (fname, ftype) in fields {
        let fv = obj
            .get(fname)
            .ok_or_else(|| ChainError::Other(format!("struct `{primary}` missing field `{fname}`")))?;
        out.extend_from_slice(&encode_field(ftype, fv, types)?);
    }
    Ok(keccak256(&out))
}

fn encode_field(
    ftype: &str,
    fv: &Value,
    types: &BTreeMap<String, Vec<(String, String)>>,
) -> Result<[u8; 32], ChainError> {
    // Array? (fixed `T[N]` or dynamic `T[]`) — encoded as
    // keccak256(concat(encode_field(inner) for each elem)).
    if let Some(end) = ftype.rfind('[') {
        if ftype.ends_with(']') {
            let inner = &ftype[..end];
            let arr = fv.as_array().ok_or_else(|| {
                ChainError::Other(format!("field typed `{ftype}` expects JSON array"))
            })?;
            let mut cat = Vec::with_capacity(arr.len() * 32);
            for item in arr {
                cat.extend_from_slice(&encode_field(inner, item, types)?);
            }
            return Ok(keccak256(&cat));
        }
    }

    // Nested struct?
    if types.contains_key(ftype) {
        return hash_struct(ftype, fv, types);
    }

    // Atomic types.
    match ftype {
        "string" => {
            let s = fv
                .as_str()
                .ok_or_else(|| ChainError::Other("expected string".to_string()))?;
            Ok(keccak256(s.as_bytes()))
        }
        "bytes" => {
            let s = fv
                .as_str()
                .ok_or_else(|| ChainError::Other("expected 0x-hex bytes".to_string()))?;
            let hex = s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")).unwrap_or(s);
            let raw = hex_decode(hex).map_err(ChainError::Other)?;
            Ok(keccak256(&raw))
        }
        "bool" => {
            let b = fv
                .as_bool()
                .ok_or_else(|| ChainError::Other("expected bool".to_string()))?;
            let mut out = [0u8; 32];
            if b {
                out[31] = 1;
            }
            Ok(out)
        }
        "address" => {
            let addr = parse_address(fv, "address field")?;
            let mut out = [0u8; 32];
            out[12..32].copy_from_slice(&addr);
            Ok(out)
        }
        t if t.starts_with("uint") => encode_uint(t, fv),
        t if t.starts_with("int") => encode_int(t, fv),
        t if t.starts_with("bytes") => encode_fixed_bytes(t, fv),
        other => Err(ChainError::Other(format!(
            "unsupported EIP-712 atomic type `{other}`"
        ))),
    }
}

fn parse_bit_width(ty: &str, prefix: &str) -> Result<u32, ChainError> {
    let n = &ty[prefix.len()..];
    if n.is_empty() {
        return Ok(256);
    }
    let w = n
        .parse::<u32>()
        .map_err(|_| ChainError::Other(format!("bad `{ty}` width")))?;
    if w == 0 || w > 256 || w % 8 != 0 {
        return Err(ChainError::Other(format!("invalid `{ty}` width")));
    }
    Ok(w)
}

fn encode_uint(ty: &str, v: &Value) -> Result<[u8; 32], ChainError> {
    let bits = parse_bit_width(ty, "uint")?;
    // Parse as decimal/hex string or JSON number.
    let raw: [u8; 32] = if let Some(n) = v.as_u64() {
        let mut out = [0u8; 32];
        out[24..32].copy_from_slice(&n.to_be_bytes());
        out
    } else if let Some(s) = v.as_str() {
        parse_uint_string(s)?
    } else {
        return Err(ChainError::Other(format!(
            "expected {ty} as number or string"
        )));
    };
    // Range check: any byte above `bits` must be zero.
    let zero_prefix = (256 - bits) as usize / 8;
    for b in &raw[..zero_prefix] {
        if *b != 0 {
            return Err(ChainError::Other(format!("value overflows `{ty}`")));
        }
    }
    Ok(raw)
}

fn parse_uint_string(s: &str) -> Result<[u8; 32], ChainError> {
    let s = s.trim();
    let (bytes, is_hex) = if let Some(hex) = s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")) {
        let mut h = hex.to_string();
        if h.len() % 2 == 1 {
            h.insert(0, '0');
        }
        (hex_decode(&h).map_err(ChainError::Other)?, true)
    } else {
        // Decimal — use double-and-add without heavy deps.
        let mut acc = [0u8; 32];
        for ch in s.chars() {
            let d = ch
                .to_digit(10)
                .ok_or_else(|| ChainError::Other(format!("non-decimal digit {ch:?}")))?;
            // acc = acc * 10 + d
            let mut carry: u32 = d;
            for i in (0..32).rev() {
                let x = acc[i] as u32 * 10 + carry;
                acc[i] = (x & 0xff) as u8;
                carry = x >> 8;
            }
            if carry != 0 {
                return Err(ChainError::Other("uint overflows 256 bits".to_string()));
            }
        }
        (acc.to_vec(), false)
    };
    if is_hex {
        if bytes.len() > 32 {
            return Err(ChainError::Other("uint hex > 32 bytes".to_string()));
        }
        let mut out = [0u8; 32];
        out[32 - bytes.len()..].copy_from_slice(&bytes);
        Ok(out)
    } else {
        let mut out = [0u8; 32];
        out.copy_from_slice(&bytes);
        Ok(out)
    }
}

fn encode_int(ty: &str, v: &Value) -> Result<[u8; 32], ChainError> {
    // For audit-reviewability we support signed ints only via i64 +
    // sign-extend, which covers every realistic typed-data message.
    // Arbitrary-precision negative values can always be passed as
    // two's-complement hex strings via the uint path.
    let bits = parse_bit_width(ty, "int")?;
    let n: i64 = if let Some(n) = v.as_i64() {
        n
    } else if let Some(s) = v.as_str() {
        s.trim()
            .parse::<i64>()
            .map_err(|e| ChainError::Other(format!("{ty} parse: {e}")))?
    } else {
        return Err(ChainError::Other(format!(
            "expected {ty} as number or string"
        )));
    };
    // Range check for requested width.
    if bits < 64 {
        let max: i64 = 1i64 << (bits - 1);
        if n >= max || n < -max {
            return Err(ChainError::Other(format!("value out of range for {ty}")));
        }
    }
    let be = n.to_be_bytes(); // 8 bytes, two's complement
    let fill: u8 = if n < 0 { 0xff } else { 0x00 };
    let mut out = [fill; 32];
    out[24..32].copy_from_slice(&be);
    Ok(out)
}

fn encode_fixed_bytes(ty: &str, v: &Value) -> Result<[u8; 32], ChainError> {
    // bytesN, 1 <= N <= 32. Right-padded with zeros.
    let n_str = &ty["bytes".len()..];
    let n: usize = n_str
        .parse()
        .map_err(|_| ChainError::Other(format!("bad `{ty}` width")))?;
    if n == 0 || n > 32 {
        return Err(ChainError::Other(format!("invalid `{ty}` width")));
    }
    let s = v
        .as_str()
        .ok_or_else(|| ChainError::Other(format!("expected {ty} as 0x-hex string")))?;
    let hex = s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")).unwrap_or(s);
    let raw = hex_decode(hex).map_err(ChainError::Other)?;
    if raw.len() != n {
        return Err(ChainError::Other(format!(
            "`{ty}` expects {n} bytes, got {}",
            raw.len()
        )));
    }
    let mut out = [0u8; 32];
    out[..n].copy_from_slice(&raw);
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    // Canonical EIP-712 example from the spec itself (Mail with
    // Person fields). The expected digest is the well-known vector
    // cited by every major EIP-712 implementation:
    //   0xbe609aee343fb3c4b28e1df9e632fca64fcfaede20f02e86244efddf30957bd2
    const CANONICAL_JSON: &str = r#"{
  "types": {
    "EIP712Domain": [
      {"name": "name", "type": "string"},
      {"name": "version", "type": "string"},
      {"name": "chainId", "type": "uint256"},
      {"name": "verifyingContract", "type": "address"}
    ],
    "Person": [
      {"name": "name", "type": "string"},
      {"name": "wallet", "type": "address"}
    ],
    "Mail": [
      {"name": "from", "type": "Person"},
      {"name": "to", "type": "Person"},
      {"name": "contents", "type": "string"}
    ]
  },
  "primaryType": "Mail",
  "domain": {
    "name": "Ether Mail",
    "version": "1",
    "chainId": 1,
    "verifyingContract": "0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC"
  },
  "message": {
    "from": {"name": "Cow", "wallet": "0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826"},
    "to": {"name": "Bob", "wallet": "0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB"},
    "contents": "Hello, Bob!"
  }
}"#;

    const CANONICAL_DIGEST_HEX: &str =
        "be609aee343fb3c4b28e1df9e632fca64fcfaede20f02e86244efddf30957bd2";

    fn hex(bytes: &[u8]) -> String {
        let mut s = String::with_capacity(bytes.len() * 2);
        for b in bytes {
            s.push_str(&format!("{b:02x}"));
        }
        s
    }

    #[test]
    fn canonical_spec_vector() {
        let d = eip712_digest_from_typed_data_json(CANONICAL_JSON).unwrap();
        assert_eq!(hex(&d), CANONICAL_DIGEST_HEX);
    }

    #[test]
    fn encode_type_matches_spec() {
        let mut types: BTreeMap<String, Vec<(String, String)>> = BTreeMap::new();
        types.insert(
            "Mail".into(),
            vec![
                ("from".into(), "Person".into()),
                ("to".into(), "Person".into()),
                ("contents".into(), "string".into()),
            ],
        );
        types.insert(
            "Person".into(),
            vec![
                ("name".into(), "string".into()),
                ("wallet".into(), "address".into()),
            ],
        );
        let s = encode_type("Mail", &types).unwrap();
        assert_eq!(
            s,
            "Mail(Person from,Person to,string contents)Person(string name,address wallet)"
        );
    }

    #[test]
    fn rejects_zero_chain_id() {
        let mut bad = serde_json::from_str::<Value>(CANONICAL_JSON).unwrap();
        bad["domain"]["chainId"] = serde_json::json!(0);
        let err = eip712_digest_from_typed_data_json(&bad.to_string()).unwrap_err();
        let ChainError::Other(m) = err else { panic!("expected Other, got {:?}", err) };
        assert!(m.contains("chain_id must be non-zero"), "{m}");
    }

    #[test]
    fn rejects_zero_verifying_contract() {
        let mut bad = serde_json::from_str::<Value>(CANONICAL_JSON).unwrap();
        bad["domain"]["verifyingContract"] =
            serde_json::json!("0x0000000000000000000000000000000000000000");
        let err = eip712_digest_from_typed_data_json(&bad.to_string()).unwrap_err();
        let ChainError::Other(m) = err else { panic!("expected Other, got {:?}", err) };
        assert!(m.contains("verifyingContract must be non-zero"), "{m}");
    }

    #[test]
    fn rejects_missing_primary_type() {
        let mut bad = serde_json::from_str::<Value>(CANONICAL_JSON).unwrap();
        let obj = bad.as_object_mut().unwrap();
        obj.remove("primaryType");
        let err = eip712_digest_from_typed_data_json(&bad.to_string()).unwrap_err();
        let ChainError::Other(m) = err else { panic!("expected Other, got {:?}", err) };
        assert!(m.contains("primaryType"), "{m}");
    }

    #[test]
    fn rejects_unknown_field_type() {
        let mut bad = serde_json::from_str::<Value>(CANONICAL_JSON).unwrap();
        bad["types"]["Mail"][0]["type"] = serde_json::json!("Ghost");
        let err = eip712_digest_from_typed_data_json(&bad.to_string()).unwrap_err();
        let ChainError::Other(m) = err else { panic!("expected Other, got {:?}", err) };
        assert!(m.contains("Ghost") || m.contains("unknown"), "{m}");
    }

    #[test]
    fn rejects_circular_types() {
        let bad = r#"{
            "types": {
                "EIP712Domain": [{"name":"name","type":"string"},{"name":"version","type":"string"},{"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"}],
                "A": [{"name":"b","type":"B"}],
                "B": [{"name":"a","type":"A"}]
            },
            "primaryType": "A",
            "domain": {"name":"x","version":"1","chainId":1,"verifyingContract":"0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC"},
            "message": {"b": {"a": null}}
        }"#;
        let err = eip712_digest_from_typed_data_json(bad).unwrap_err();
        let ChainError::Other(m) = err else { panic!("expected Other, got {:?}", err) };
        assert!(m.contains("circular"), "{m}");
    }

    #[test]
    fn determinism_on_equivalent_inputs() {
        let d1 = eip712_digest_from_typed_data_json(CANONICAL_JSON).unwrap();
        // Re-serialize via Value (round-trip) and confirm same digest.
        let val: Value = serde_json::from_str(CANONICAL_JSON).unwrap();
        let reserialized = val.to_string();
        let d2 = eip712_digest_from_typed_data_json(&reserialized).unwrap();
        assert_eq!(d1, d2);
    }

    #[test]
    fn dynamic_array_of_struct() {
        // Mail with an array of recipients — common dApp pattern.
        let json = r#"{
          "types": {
            "EIP712Domain": [{"name":"name","type":"string"},{"name":"version","type":"string"},{"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"}],
            "Person": [{"name":"name","type":"string"},{"name":"wallet","type":"address"}],
            "Group": [{"name":"from","type":"Person"},{"name":"to","type":"Person[]"},{"name":"contents","type":"string"}]
          },
          "primaryType": "Group",
          "domain": {"name":"Ether Mail","version":"1","chainId":1,"verifyingContract":"0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC"},
          "message": {
            "from": {"name":"Cow","wallet":"0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826"},
            "to": [
              {"name":"Bob","wallet":"0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB"},
              {"name":"Alice","wallet":"0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa"}
            ],
            "contents": "Hello!"
          }
        }"#;
        // Should compute successfully + deterministically.
        let a = eip712_digest_from_typed_data_json(json).unwrap();
        let b = eip712_digest_from_typed_data_json(json).unwrap();
        assert_eq!(a, b);
    }

    #[test]
    fn uint256_decimal_string_equals_number() {
        // uint256 can be specified as a JSON number or decimal string
        // — they must hash identically.
        let j1 = r#"{
          "types": {
            "EIP712Domain": [{"name":"name","type":"string"},{"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"}],
            "Tx": [{"name":"amount","type":"uint256"}]
          },
          "primaryType": "Tx",
          "domain": {"name":"d","chainId":1,"verifyingContract":"0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC"},
          "message": {"amount": 12345}
        }"#;
        let j2 = j1.replace("\"amount\": 12345", "\"amount\": \"12345\"");
        let d1 = eip712_digest_from_typed_data_json(j1).unwrap();
        let d2 = eip712_digest_from_typed_data_json(&j2).unwrap();
        assert_eq!(d1, d2);
    }

    // -----------------------------------------------------------------
    // Real-world dApp payload regressions. Unlike the canonical spec
    // vector (which cross-checks against the EIP-712 reference
    // implementation), these vectors lock in the digest this
    // implementation currently emits for production dApp shapes.
    // A change to type-ordering, encoding, or padding that causes
    // any of these to drift will fail CI, making the regression
    // impossible to ship silently.
    //
    // The payload shapes themselves are verbatim from published
    // production contracts — Uniswap's Permit2 (0x000000…ac78ba3)
    // and the EIP-2612 Permit signature family (USDC / DAI / etc).
    // -----------------------------------------------------------------

    #[test]
    fn eip_2612_permit_usdc_mainnet() {
        // EIP-2612 Permit, using USDC's published domain on Ethereum
        // mainnet (chainId=1, verifyingContract = USDC proxy) and a
        // concrete (owner, spender, value, nonce, deadline) tuple.
        let json = r#"{
          "types": {
            "EIP712Domain": [
              {"name": "name", "type": "string"},
              {"name": "version", "type": "string"},
              {"name": "chainId", "type": "uint256"},
              {"name": "verifyingContract", "type": "address"}
            ],
            "Permit": [
              {"name": "owner", "type": "address"},
              {"name": "spender", "type": "address"},
              {"name": "value", "type": "uint256"},
              {"name": "nonce", "type": "uint256"},
              {"name": "deadline", "type": "uint256"}
            ]
          },
          "primaryType": "Permit",
          "domain": {
            "name": "USD Coin",
            "version": "2",
            "chainId": 1,
            "verifyingContract": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
          },
          "message": {
            "owner": "0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826",
            "spender": "0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB",
            "value": "1000000",
            "nonce": "0",
            "deadline": "1900000000"
          }
        }"#;
        let d = eip712_digest_from_typed_data_json(json).unwrap();
        // Regression lock — recompute and update if the encoder
        // provably changes and a cross-implementation reference
        // confirms the new output. Do NOT update blindly.
        // Cross-verified against ethers.js v6 TypedDataEncoder.hash().
        assert_eq!(
            hex(&d),
            "7e8c9eab9047e7728f72000481ec6c4a758decaba3cae928122009f7701c0031"
        );
    }

    #[test]
    fn permit2_permit_single_uniswap() {
        // Uniswap Permit2 `PermitSingle` — nested struct
        // (`PermitDetails` inside `PermitSingle`) with the official
        // mainnet singleton verifyingContract
        // (0x000000000022D473030F116dDEE9F6B43aC78BA3). Exercises
        // type-dependency ordering (PermitDetails must appear
        // alphabetically-sorted after the primary struct encoding).
        let json = r#"{
          "types": {
            "EIP712Domain": [
              {"name": "name", "type": "string"},
              {"name": "chainId", "type": "uint256"},
              {"name": "verifyingContract", "type": "address"}
            ],
            "PermitDetails": [
              {"name": "token", "type": "address"},
              {"name": "amount", "type": "uint160"},
              {"name": "expiration", "type": "uint48"},
              {"name": "nonce", "type": "uint48"}
            ],
            "PermitSingle": [
              {"name": "details", "type": "PermitDetails"},
              {"name": "spender", "type": "address"},
              {"name": "sigDeadline", "type": "uint256"}
            ]
          },
          "primaryType": "PermitSingle",
          "domain": {
            "name": "Permit2",
            "chainId": 1,
            "verifyingContract": "0x000000000022D473030F116dDEE9F6B43aC78BA3"
          },
          "message": {
            "details": {
              "token": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
              "amount": "1461501637330902918203684832716283019655932542975",
              "expiration": "1900000000",
              "nonce": "0"
            },
            "spender": "0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB",
            "sigDeadline": "1900000000"
          }
        }"#;
        let d = eip712_digest_from_typed_data_json(json).unwrap();
        // Regression lock. Same caveat as above.
        // Cross-verified against ethers.js v6 TypedDataEncoder.hash().
        // This regression vector exercises the 3-field EIP712Domain
        // (name, chainId, verifyingContract — no `version`), which
        // proved an earlier hard-coded-domain bug in this module.
        assert_eq!(
            hex(&d),
            "498b33192dc3c07680c29a8c6943f7c82a3cde8e3581c4233c2f5a0cc1644518"
        );
    }

    /// Seaport-style `OrderComponents` — exercises dynamic arrays of
    /// struct (`OfferItem[]`, `ConsiderationItem[]`), the exact
    /// pattern real NFT marketplaces use. Cross-verified against
    /// ethers.js v6 `TypedDataEncoder.hash`.
    #[test]
    fn seaport_style_order_components() {
        let json = r#"{
            "types": {
                "EIP712Domain": [
                    {"name":"name","type":"string"},
                    {"name":"version","type":"string"},
                    {"name":"chainId","type":"uint256"},
                    {"name":"verifyingContract","type":"address"}
                ],
                "OfferItem": [
                    {"name":"itemType","type":"uint8"},
                    {"name":"token","type":"address"},
                    {"name":"identifierOrCriteria","type":"uint256"},
                    {"name":"startAmount","type":"uint256"},
                    {"name":"endAmount","type":"uint256"}
                ],
                "ConsiderationItem": [
                    {"name":"itemType","type":"uint8"},
                    {"name":"token","type":"address"},
                    {"name":"identifierOrCriteria","type":"uint256"},
                    {"name":"startAmount","type":"uint256"},
                    {"name":"endAmount","type":"uint256"},
                    {"name":"recipient","type":"address"}
                ],
                "OrderComponents": [
                    {"name":"offerer","type":"address"},
                    {"name":"zone","type":"address"},
                    {"name":"offer","type":"OfferItem[]"},
                    {"name":"consideration","type":"ConsiderationItem[]"},
                    {"name":"startTime","type":"uint256"},
                    {"name":"endTime","type":"uint256"},
                    {"name":"salt","type":"uint256"}
                ]
            },
            "primaryType": "OrderComponents",
            "domain": {
                "name": "Seaport",
                "version": "1.5",
                "chainId": 1,
                "verifyingContract": "0x00000000000000ADc04C56Bf30aC9d3c0aAF14dC"
            },
            "message": {
                "offerer": "0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826",
                "zone": "0x0000000000000000000000000000000000000000",
                "offer": [
                    {
                        "itemType": "2",
                        "token": "0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D",
                        "identifierOrCriteria": "1234",
                        "startAmount": "1",
                        "endAmount": "1"
                    }
                ],
                "consideration": [
                    {
                        "itemType": "0",
                        "token": "0x0000000000000000000000000000000000000000",
                        "identifierOrCriteria": "0",
                        "startAmount": "975000000000000000",
                        "endAmount": "975000000000000000",
                        "recipient": "0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826"
                    },
                    {
                        "itemType": "0",
                        "token": "0x0000000000000000000000000000000000000000",
                        "identifierOrCriteria": "0",
                        "startAmount": "25000000000000000",
                        "endAmount": "25000000000000000",
                        "recipient": "0x0000a26b00c1F0DF003000390027140000fAa719"
                    }
                ],
                "startTime": "1700000000",
                "endTime": "1800000000",
                "salt": "12345678901234567890"
            }
        }"#;

        let d = eip712_digest_from_typed_data_json(json).unwrap();
        // Cross-verified against ethers.js v6 TypedDataEncoder.hash().
        assert_eq!(
            hex(&d),
            "abebe4fd35078828d1bc2336fbce059a03ca54902ca998e3a60debfe9ec9f4da"
        );
    }

    #[test]
    fn encode_type_dependency_ordering_is_alphabetical() {
        // Spec: encodeType = primaryDef ++ deps-sorted-alphabetically.
        // With "PermitSingle" primary and ["PermitDetails"] as only
        // dep, the encoded string must be
        // "PermitSingle(...)PermitDetails(...)" — primary first,
        // deps alphabetical, which here is a single entry.
        let mut types: BTreeMap<String, Vec<(String, String)>> = BTreeMap::new();
        types.insert(
            "PermitSingle".into(),
            vec![
                ("details".into(), "PermitDetails".into()),
                ("spender".into(), "address".into()),
                ("sigDeadline".into(), "uint256".into()),
            ],
        );
        types.insert(
            "PermitDetails".into(),
            vec![
                ("token".into(), "address".into()),
                ("amount".into(), "uint160".into()),
                ("expiration".into(), "uint48".into()),
                ("nonce".into(), "uint48".into()),
            ],
        );
        let s = encode_type("PermitSingle", &types).unwrap();
        assert_eq!(
            s,
            "PermitSingle(PermitDetails details,address spender,uint256 sigDeadline)PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)"
        );
    }

    // ----- EIP-55 checksum validation on address fields ----------

    fn mk_permit_json_with_owner(owner_hex: &str) -> String {
        format!(
            r#"{{
                "types": {{
                    "EIP712Domain": [
                        {{"name":"name","type":"string"}},
                        {{"name":"version","type":"string"}},
                        {{"name":"chainId","type":"uint256"}},
                        {{"name":"verifyingContract","type":"address"}}
                    ],
                    "Permit": [
                        {{"name":"owner","type":"address"}},
                        {{"name":"value","type":"uint256"}}
                    ]
                }},
                "primaryType": "Permit",
                "domain": {{
                    "name": "X", "version": "1", "chainId": 1,
                    "verifyingContract": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
                }},
                "message": {{ "owner": "{owner_hex}", "value": "1" }}
            }}"#
        )
    }

    #[test]
    fn eip55_canonical_address_accepted() {
        // Canonical EIP-55 form of a well-known address.
        let canonical = "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed";
        eip712_digest_from_typed_data_json(&mk_permit_json_with_owner(canonical))
            .expect("canonical EIP-55 form must be accepted");
    }

    #[test]
    fn eip55_all_lowercase_accepted() {
        // All-lowercase: spec says "no checksum information", accept.
        let lowered = "0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed";
        eip712_digest_from_typed_data_json(&mk_permit_json_with_owner(lowered))
            .expect("all-lowercase address must be accepted");
    }

    #[test]
    fn eip55_all_uppercase_accepted() {
        let upper = "0x5AAEB6053F3E94C9B9A09F33669435E7EF1BEAED";
        eip712_digest_from_typed_data_json(&mk_permit_json_with_owner(upper))
            .expect("all-uppercase address must be accepted");
    }

    #[test]
    fn eip55_mixed_case_typo_rejected() {
        // Flip one nibble's case from the canonical form — a typical
        // copy-paste typo. Must be rejected so the user doesn't sign
        // a digest binding to an unintended (but valid) recipient.
        // Canonical:  0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed
        // Corrupted:  0x5aaEb6053F3E94C9b9A09f33669435E7Ef1BeAed  ('A' -> 'a')
        let bad = "0x5aaeB6053F3E94C9b9A09f33669435E7Ef1BeAed";
        let err = eip712_digest_from_typed_data_json(&mk_permit_json_with_owner(bad))
            .expect_err("mixed-case address with bad EIP-55 checksum must be rejected");
        let ChainError::Other(m) = err else {
            panic!("unexpected error variant");
        };
        assert!(
            m.contains("EIP-55 checksum mismatch"),
            "unexpected error message: {m}"
        );
    }

    // ----- bool / bytes / bytesN / signed-int code paths -----------

    /// DAI mainnet Permit — uses `allowed: bool` instead of
    /// `value: uint256`, exercising the bool encoding path (not
    /// touched by USDC Permit or Permit2). Cross-verified against
    /// ethers.js v6.
    #[test]
    fn dai_permit_bool_field() {
        let json = r#"{
            "types": {
                "EIP712Domain": [
                    {"name":"name","type":"string"},
                    {"name":"version","type":"string"},
                    {"name":"chainId","type":"uint256"},
                    {"name":"verifyingContract","type":"address"}
                ],
                "Permit": [
                    {"name":"holder","type":"address"},
                    {"name":"spender","type":"address"},
                    {"name":"nonce","type":"uint256"},
                    {"name":"expiry","type":"uint256"},
                    {"name":"allowed","type":"bool"}
                ]
            },
            "primaryType": "Permit",
            "domain": {
                "name": "Dai Stablecoin",
                "version": "1",
                "chainId": 1,
                "verifyingContract": "0x6B175474E89094C44Da98b954EedeAC495271d0F"
            },
            "message": {
                "holder": "0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826",
                "spender": "0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB",
                "nonce": "3",
                "expiry": "1900000000",
                "allowed": true
            }
        }"#;
        let d = eip712_digest_from_typed_data_json(json).unwrap();
        // Cross-verified against ethers.js v6 TypedDataEncoder.hash().
        assert_eq!(
            hex(&d),
            "b1ac895ab607fe23899757e76d09b132a1fa13b2ac526c597b6de77b0e3a80ad"
        );
    }

    /// Exercises all three previously-uncovered scalar paths in one
    /// payload: `bytes32` (fixed-width byte string), `bytes`
    /// (dynamic, must be keccak'd), and a signed `int32` with a
    /// negative value (two's-complement sign-extension). Cross-
    /// verified against ethers.js v6.
    #[test]
    fn bytes32_dynamic_bytes_and_signed_int32() {
        let json = r#"{
            "types": {
                "EIP712Domain": [
                    {"name":"name","type":"string"},
                    {"name":"chainId","type":"uint256"},
                    {"name":"verifyingContract","type":"address"}
                ],
                "Thing": [
                    {"name":"digest","type":"bytes32"},
                    {"name":"blob","type":"bytes"},
                    {"name":"n","type":"int32"}
                ]
            },
            "primaryType": "Thing",
            "domain": {
                "name": "X",
                "chainId": 1,
                "verifyingContract": "0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC"
            },
            "message": {
                "digest": "0x1111111111111111111111111111111111111111111111111111111111111111",
                "blob": "0xdeadbeef",
                "n": -12345
            }
        }"#;
        let d = eip712_digest_from_typed_data_json(json).unwrap();
        // Cross-verified against ethers.js v6 TypedDataEncoder.hash().
        assert_eq!(
            hex(&d),
            "2e17f205392287ca01b0b5e66a471079b76d3d7cbdf6c6c937f513d5ca194a4c"
        );
    }

    /// Tamper-detection property: a single byte flip in any
    /// user-visible field must produce a different digest. Not a
    /// correctness proof on its own, but a quick smoke-gate against
    /// field-skip bugs (e.g. if we accidentally dropped the `chainId`
    /// from the domain separator, many digests would stay equal).
    #[test]
    fn single_byte_flip_changes_digest() {
        let base = r#"{
            "types": {
                "EIP712Domain": [
                    {"name":"name","type":"string"},
                    {"name":"chainId","type":"uint256"},
                    {"name":"verifyingContract","type":"address"}
                ],
                "Tx": [
                    {"name":"to","type":"address"},
                    {"name":"value","type":"uint256"}
                ]
            },
            "primaryType": "Tx",
            "domain": {
                "name": "X",
                "chainId": 1,
                "verifyingContract": "0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC"
            },
            "message": {
                "to": "0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826",
                "value": "100"
            }
        }"#;
        let d0 = eip712_digest_from_typed_data_json(base).unwrap();

        // Flip chainId.
        let j_chain = base.replace("\"chainId\": 1", "\"chainId\": 2");
        let d_chain = eip712_digest_from_typed_data_json(&j_chain).unwrap();
        assert_ne!(d0, d_chain, "chainId change must alter digest");

        // Flip value.
        let j_value = base.replace("\"value\": \"100\"", "\"value\": \"101\"");
        let d_value = eip712_digest_from_typed_data_json(&j_value).unwrap();
        assert_ne!(d0, d_value, "message.value change must alter digest");

        // Flip recipient low-nibble (keep EIP-55 canonical by using
        // all-lowercase, so the checksum check doesn't fire).
        let j_lc = base.replace(
            "\"to\": \"0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826\"",
            "\"to\": \"0xcd2a3d9f938e13cd947ec05abc7fe734df8dd827\"",
        );
        let d_to = eip712_digest_from_typed_data_json(&j_lc).unwrap();
        assert_ne!(d0, d_to, "recipient change must alter digest");
    }
}

// ---------------------------------------------------------------------
// Property-based tests (proptest).
// ---------------------------------------------------------------------
//
// These are intentionally separated from the hand-crafted `tests`
// module so they're easy to skip in `cargo test --lib -- --skip prop`
// during fast iteration. Each property runs 256 random cases by
// default. The generated payloads target the "dApp-shape" distribution
// (Permit-like messages with string/address/uint/bytes/bool fields
// plus one nested struct and one dynamic array) rather than the full
// spec — the spec surface is exercised by the hand-crafted vectors
// above.
#[cfg(test)]
mod prop_tests {
    use super::*;
    use proptest::prelude::*;

    /// Non-zero chain ID, within a reasonable range (covers mainnet,
    /// most L2s, and test networks).
    fn arb_chain_id() -> impl Strategy<Value = u64> {
        proptest::num::u64::ANY.prop_filter("chain_id must be non-zero", |n| *n != 0)
    }

    /// Non-zero address in all-lowercase (so EIP-55 check passes).
    fn arb_address_lowercase() -> impl Strategy<Value = String> {
        proptest::collection::vec(any::<u8>(), 20).prop_filter_map(
            "must not be all-zero",
            |bytes| {
                if bytes.iter().all(|b| *b == 0) {
                    None
                } else {
                    let mut s = String::with_capacity(42);
                    s.push_str("0x");
                    for b in bytes {
                        s.push_str(&format!("{b:02x}"));
                    }
                    Some(s)
                }
            },
        )
    }

    /// Build a minimal but realistic Permit-shaped payload.
    fn arb_permit_payload(
    ) -> impl Strategy<Value = (String, u64, String, String, String, String, u64, u64)> {
        (
            // domain name (non-empty, ASCII-only to avoid JSON-escape edge cases)
            "[a-zA-Z][a-zA-Z0-9 ]{0,31}",
            arb_chain_id(),
            arb_address_lowercase(), // verifyingContract
            arb_address_lowercase(), // owner
            arb_address_lowercase(), // spender
            // value: decimal u256 expressed as a string (up to 20 decimal digits)
            "[1-9][0-9]{0,19}",
            0u64..=u64::MAX, // nonce
            0u64..=u64::MAX, // deadline
        )
            .prop_map(|t| t)
    }

    #[allow(clippy::too_many_arguments)]
    fn build_json(
        name: &str,
        chain_id: u64,
        vc: &str,
        owner: &str,
        spender: &str,
        value: &str,
        nonce: u64,
        deadline: u64,
    ) -> String {
        // Escape the only chars we allow in `name` that JSON cares
        // about: the `"` quote. Because our regex excludes `"`, no
        // escaping is needed — but keep the assertion defensive.
        debug_assert!(!name.contains('"') && !name.contains('\\'));
        format!(
            r#"{{
                "types": {{
                    "EIP712Domain": [
                        {{"name":"name","type":"string"}},
                        {{"name":"version","type":"string"}},
                        {{"name":"chainId","type":"uint256"}},
                        {{"name":"verifyingContract","type":"address"}}
                    ],
                    "Permit": [
                        {{"name":"owner","type":"address"}},
                        {{"name":"spender","type":"address"}},
                        {{"name":"value","type":"uint256"}},
                        {{"name":"nonce","type":"uint256"}},
                        {{"name":"deadline","type":"uint256"}}
                    ]
                }},
                "primaryType": "Permit",
                "domain": {{
                    "name": "{name}", "version": "1",
                    "chainId": {chain_id},
                    "verifyingContract": "{vc}"
                }},
                "message": {{
                    "owner": "{owner}",
                    "spender": "{spender}",
                    "value": "{value}",
                    "nonce": "{nonce}",
                    "deadline": "{deadline}"
                }}
            }}"#
        )
    }

    proptest! {
        #![proptest_config(ProptestConfig {
            cases: 256,
            .. ProptestConfig::default()
        })]

        /// **Never panic / OOM / UB** on any well-formed Permit-shape
        /// input drawn from the dApp distribution. Must always
        /// succeed and return 32 bytes.
        #[test]
        fn well_formed_inputs_never_panic(
            (name, chain_id, vc, owner, spender, value, nonce, deadline) in arb_permit_payload(),
        ) {
            let j = build_json(&name, chain_id, &vc, &owner, &spender, &value, nonce, deadline);
            let d = eip712_digest_from_typed_data_json(&j)
                .expect("well-formed input must succeed");
            prop_assert_eq!(d.len(), 32);
        }

        /// **Determinism**: the same input always produces the same
        /// digest. Guards against hidden non-determinism (e.g. if we
        /// ever iterate a HashMap for a type definition).
        #[test]
        fn digest_is_deterministic(
            (name, chain_id, vc, owner, spender, value, nonce, deadline) in arb_permit_payload(),
        ) {
            let j = build_json(&name, chain_id, &vc, &owner, &spender, &value, nonce, deadline);
            let a = eip712_digest_from_typed_data_json(&j).unwrap();
            let b = eip712_digest_from_typed_data_json(&j).unwrap();
            prop_assert_eq!(a, b);
        }

        /// **Domain-binding sensitivity**: changing `chainId` (which
        /// goes into the domain separator) must always change the
        /// digest. Catches any regression that drops the separator
        /// from the final hash.
        #[test]
        fn chain_id_bump_always_alters_digest(
            (name, chain_id, vc, owner, spender, value, nonce, deadline) in arb_permit_payload(),
        ) {
            let j1 = build_json(&name, chain_id, &vc, &owner, &spender, &value, nonce, deadline);
            let alt_chain = chain_id.wrapping_add(1).max(1); // still non-zero
            prop_assume!(alt_chain != chain_id);
            let j2 = build_json(&name, alt_chain, &vc, &owner, &spender, &value, nonce, deadline);
            let d1 = eip712_digest_from_typed_data_json(&j1).unwrap();
            let d2 = eip712_digest_from_typed_data_json(&j2).unwrap();
            prop_assert_ne!(d1, d2);
        }

        /// **Message-binding sensitivity**: changing `value` (a
        /// message-level field) must always change the digest. Catches
        /// regressions that accidentally skip struct fields.
        #[test]
        fn message_value_change_always_alters_digest(
            (name, chain_id, vc, owner, spender, _value, nonce, deadline) in arb_permit_payload(),
            v1 in "[1-9][0-9]{0,19}",
            v2 in "[1-9][0-9]{0,19}",
        ) {
            prop_assume!(v1 != v2);
            let j1 = build_json(&name, chain_id, &vc, &owner, &spender, &v1, nonce, deadline);
            let j2 = build_json(&name, chain_id, &vc, &owner, &spender, &v2, nonce, deadline);
            let d1 = eip712_digest_from_typed_data_json(&j1).unwrap();
            let d2 = eip712_digest_from_typed_data_json(&j2).unwrap();
            prop_assert_ne!(d1, d2);
        }

        /// **Malformed-JSON robustness**: random byte strings must
        /// never panic — they should return `Err`, not crash the
        /// process. This is the core fuzz-like property; a real
        /// cargo-fuzz harness can build on top of this later.
        #[test]
        fn arbitrary_bytes_never_panic(bytes in proptest::collection::vec(any::<u8>(), 0..4096)) {
            // Treat the bytes as a UTF-8-lossy string and feed it in.
            let s = String::from_utf8_lossy(&bytes);
            let _ = eip712_digest_from_typed_data_json(&s); // Err is fine; panic is not.
        }
    }
}
