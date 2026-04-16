// Horcrux FFI Stubs for iOS Simulator
// These stubs allow the iOS app to compile and run on the simulator
// without the real Rust library (GMP/cggmp21 can't cross-compile for simulator).
// Constructors succeed, RustBuffer management works, and all other FFI calls
// return CALL_UNEXPECTED_ERROR (code=2) so UniFFI throws instead of crashing.

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdlib.h>

typedef struct { uint64_t capacity; uint64_t len; uint8_t *data; } RustBuffer;
typedef struct { int32_t len; const uint8_t *data; } ForeignBytes;
typedef struct { int8_t code; RustBuffer errorBuf; } RustCallStatus;
typedef void (*UniffiRustFutureContinuationCallback)(uint64_t, int8_t);
typedef void (*UniffiForeignFutureFree)(uint64_t);

// Status codes matching UniFFI
#define CALL_SUCCESS 0
#define CALL_ERROR 1
#define CALL_UNEXPECTED_ERROR 2

// Dummy pointer for object handles
static char _dummy_object = 0;

// Helper: set panic status (code=2, empty errorBuf) — causes UniFFI to throw
static void set_panic(RustCallStatus *s) {
    if (s) { s->code = CALL_UNEXPECTED_ERROR; s->errorBuf = (RustBuffer){0, 0, NULL}; }
}

// Helper: create a RustBuffer with specific bytes (for non-throwing returns)
static RustBuffer make_buf(const uint8_t *bytes, uint64_t len) {
    if (len == 0) {
        uint8_t *p = (uint8_t *)malloc(1);
        if (p) p[0] = 0;
        return (RustBuffer){1, 0, p};
    }
    uint8_t *p = (uint8_t *)malloc(len);
    if (p) memcpy(p, bytes, len);
    return (RustBuffer){len, len, p};
}

// ============================================================
// RustBuffer memory management — MUST work correctly
// ============================================================

RustBuffer ffi_horcrux_core_rustbuffer_alloc(uint64_t size, RustCallStatus *out_status) {
    uint8_t *data = (uint8_t *)malloc(size > 0 ? size : 1);
    if (data) memset(data, 0, size > 0 ? size : 1);
    return (RustBuffer){size > 0 ? size : 1, 0, data};
}

RustBuffer ffi_horcrux_core_rustbuffer_from_bytes(ForeignBytes bytes, RustCallStatus *out_status) {
    uint64_t len = bytes.len > 0 ? (uint64_t)bytes.len : 0;
    uint8_t *data = (uint8_t *)malloc(len > 0 ? len : 1);
    if (data && bytes.data && len > 0) memcpy(data, bytes.data, len);
    return (RustBuffer){len > 0 ? len : 1, len, data};
}

void ffi_horcrux_core_rustbuffer_free(RustBuffer buf, RustCallStatus *out_status) {
    if (buf.data) free(buf.data);
}

RustBuffer ffi_horcrux_core_rustbuffer_reserve(RustBuffer buf, uint64_t additional, RustCallStatus *out_status) {
    uint64_t new_cap = buf.capacity + additional;
    uint8_t *data = (uint8_t *)realloc(buf.data, new_cap > 0 ? new_cap : 1);
    return (RustBuffer){new_cap > 0 ? new_cap : 1, buf.len, data ? data : buf.data};
}

// ============================================================
// Object constructors — succeed with dummy pointer
// (these are used with try! in Swift so MUST return code=0)
// ============================================================

void* uniffi_horcrux_core_fn_constructor_horcruxsessionmanager_new(RustCallStatus *out_status) {
    return &_dummy_object;
}

void* uniffi_horcrux_core_fn_constructor_horcruxshardmanager_new(RustCallStatus *out_status) {
    return &_dummy_object;
}

void* uniffi_horcrux_core_fn_constructor_horcruxnoisechannel_new_initiator(RustBuffer keypair, RustCallStatus *out_status) {
    set_panic(out_status);
    return &_dummy_object;
}

void* uniffi_horcrux_core_fn_constructor_horcruxnoisechannel_new_responder(RustBuffer keypair, RustCallStatus *out_status) {
    set_panic(out_status);
    return &_dummy_object;
}

// ============================================================
// Object clone/free — succeed silently (used with try!)
// ============================================================

void* uniffi_horcrux_core_fn_clone_horcruxnoisechannel(void *ptr, RustCallStatus *out_status) {
    return &_dummy_object;
}

void uniffi_horcrux_core_fn_free_horcruxnoisechannel(void *ptr, RustCallStatus *out_status) {}

void* uniffi_horcrux_core_fn_clone_horcruxsessionmanager(void *ptr, RustCallStatus *out_status) {
    return &_dummy_object;
}

void uniffi_horcrux_core_fn_free_horcruxsessionmanager(void *ptr, RustCallStatus *out_status) {}

void* uniffi_horcrux_core_fn_clone_horcruxshardmanager(void *ptr, RustCallStatus *out_status) {
    return &_dummy_object;
}

void uniffi_horcrux_core_fn_free_horcruxshardmanager(void *ptr, RustCallStatus *out_status) {}

// ============================================================
// Non-throwing methods that return RustBuffer — return valid empty data
// (these use try! so MUST succeed with code=0 and valid buffer)
// ============================================================

// listShards() -> [FfiShardInfo] — empty array: int32(0)
RustBuffer uniffi_horcrux_core_fn_method_horcruxshardmanager_list_shards(void *ptr, RustCallStatus *out_status) {
    static const uint8_t empty_array[] = {0, 0, 0, 0}; // length = 0
    return make_buf(empty_array, 4);
}

// shardsForKey() -> [FfiShardInfo] — empty array
RustBuffer uniffi_horcrux_core_fn_method_horcruxshardmanager_shards_for_key(void *ptr, RustBuffer public_key, RustCallStatus *out_status) {
    static const uint8_t empty_array[] = {0, 0, 0, 0};
    return make_buf(empty_array, 4);
}

// getKeygenResult() -> FfiKeygenResult? — nil optional: byte(0)
RustBuffer uniffi_horcrux_core_fn_method_horcruxsessionmanager_get_keygen_result(void *ptr, RustBuffer session_id, RustCallStatus *out_status) {
    static const uint8_t optional_nil[] = {0};
    return make_buf(optional_nil, 1);
}

// getSigningResult() -> FfiSigningResult? — nil optional: byte(0)
RustBuffer uniffi_horcrux_core_fn_method_horcruxsessionmanager_get_signing_result(void *ptr, RustBuffer session_id, RustCallStatus *out_status) {
    static const uint8_t optional_nil[] = {0};
    return make_buf(optional_nil, 1);
}

// remoteStaticKey() -> Data? — nil optional
RustBuffer uniffi_horcrux_core_fn_method_horcruxnoisechannel_remote_static_key(void *ptr, RustCallStatus *out_status) {
    static const uint8_t optional_nil[] = {0};
    return make_buf(optional_nil, 1);
}

// isHandshakeFinished() -> Bool — false (returns int8_t, no RustBuffer)
int8_t uniffi_horcrux_core_fn_method_horcruxnoisechannel_is_handshake_finished(void *ptr, RustCallStatus *out_status) {
    return 0;
}

// removeSession() -> void (non-throwing)
void uniffi_horcrux_core_fn_method_horcruxsessionmanager_remove_session(void *ptr, RustBuffer session_id, RustCallStatus *out_status) {}

// addShard() -> void (non-throwing)
void uniffi_horcrux_core_fn_method_horcruxshardmanager_add_shard(void *ptr, RustBuffer info, RustCallStatus *out_status) {}

// horcruxGenerateSessionToken() -> FfiSessionToken (non-throwing, try!)
// FfiSessionToken { roomSecret: Data, accessToken: Data, roomId: String }
// Wire format: int32(0) + int32(0) + int32(4) + "stub"
RustBuffer uniffi_horcrux_core_fn_func_horcrux_generate_session_token(RustCallStatus *out_status) {
    static const uint8_t token_data[] = {
        0,0,0,1, 0x00,           // roomSecret: Data(1 byte = 0x00)
        0,0,0,1, 0x00,           // accessToken: Data(1 byte = 0x00)
        0,0,0,4, 's','t','u','b' // roomId: "stub"
    };
    return make_buf(token_data, sizeof(token_data));
}

// horcruxKeccak256(data) -> Data (non-throwing, try!)
// Return 32 zero bytes as hash
RustBuffer uniffi_horcrux_core_fn_func_horcrux_keccak256(RustBuffer data, RustCallStatus *out_status) {
    static const uint8_t hash_data[] = {
        0,0,0,32, // length = 32
        0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,
        0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0
    };
    return make_buf(hash_data, 36);
}

// ============================================================
// Throwing methods/functions — return panic (code=2)
// (these use try/throws so the error is catchable)
// ============================================================

RustBuffer uniffi_horcrux_core_fn_method_horcruxsessionmanager_create_keygen(void *ptr, RustBuffer session_id, RustBuffer config, RustCallStatus *out_status) {
    set_panic(out_status);
    return (RustBuffer){0, 0, NULL};
}

RustBuffer uniffi_horcrux_core_fn_method_horcruxsessionmanager_create_signing(void *ptr, RustBuffer session_id, RustBuffer config, RustBuffer message_hash, RustBuffer shard_data, RustBuffer participants, RustCallStatus *out_status) {
    set_panic(out_status);
    return (RustBuffer){0, 0, NULL};
}

RustBuffer uniffi_horcrux_core_fn_method_horcruxsessionmanager_handle_message(void *ptr, RustBuffer msg, RustCallStatus *out_status) {
    set_panic(out_status);
    return (RustBuffer){0, 0, NULL};
}

RustBuffer uniffi_horcrux_core_fn_method_horcruxnoisechannel_open(void *ptr, RustBuffer envelope, RustCallStatus *out_status) {
    set_panic(out_status);
    return (RustBuffer){0, 0, NULL};
}

RustBuffer uniffi_horcrux_core_fn_method_horcruxnoisechannel_read_handshake(void *ptr, RustBuffer message, RustCallStatus *out_status) {
    set_panic(out_status);
    return (RustBuffer){0, 0, NULL};
}

RustBuffer uniffi_horcrux_core_fn_method_horcruxnoisechannel_seal(void *ptr, RustBuffer plaintext, RustCallStatus *out_status) {
    set_panic(out_status);
    return (RustBuffer){0, 0, NULL};
}

RustBuffer uniffi_horcrux_core_fn_method_horcruxnoisechannel_write_handshake(void *ptr, RustBuffer payload, RustCallStatus *out_status) {
    set_panic(out_status);
    return (RustBuffer){0, 0, NULL};
}

// Standalone throwing functions

RustBuffer uniffi_horcrux_core_fn_func_horcrux_generate_noise_keypair(RustCallStatus *out_status) {
    set_panic(out_status);
    return (RustBuffer){0, 0, NULL};
}

RustBuffer uniffi_horcrux_core_fn_func_horcrux_btc_address(RustBuffer compressed_pubkey, RustBuffer hrp, RustCallStatus *out_status) {
    set_panic(out_status);
    return (RustBuffer){0, 0, NULL};
}

RustBuffer uniffi_horcrux_core_fn_func_horcrux_build_btc_transaction(RustBuffer params, uint32_t input_index, RustCallStatus *out_status) {
    set_panic(out_status);
    return (RustBuffer){0, 0, NULL};
}

RustBuffer uniffi_horcrux_core_fn_func_horcrux_build_evm_transaction(RustBuffer params, RustCallStatus *out_status) {
    set_panic(out_status);
    return (RustBuffer){0, 0, NULL};
}

RustBuffer uniffi_horcrux_core_fn_func_horcrux_build_solana_transaction(RustBuffer params, RustCallStatus *out_status) {
    set_panic(out_status);
    return (RustBuffer){0, 0, NULL};
}

RustBuffer uniffi_horcrux_core_fn_func_horcrux_decrypt_shard(RustBuffer encrypted, RustBuffer device_key, RustBuffer pin, RustCallStatus *out_status) {
    set_panic(out_status);
    return (RustBuffer){0, 0, NULL};
}

RustBuffer uniffi_horcrux_core_fn_func_horcrux_encrypt_shard(RustBuffer plaintext, RustBuffer device_key, RustBuffer pin, RustCallStatus *out_status) {
    set_panic(out_status);
    return (RustBuffer){0, 0, NULL};
}

RustBuffer uniffi_horcrux_core_fn_func_horcrux_evm_address(RustBuffer uncompressed_pubkey, RustCallStatus *out_status) {
    set_panic(out_status);
    return (RustBuffer){0, 0, NULL};
}

RustBuffer uniffi_horcrux_core_fn_func_horcrux_solana_address(RustBuffer pubkey, RustCallStatus *out_status) {
    set_panic(out_status);
    return (RustBuffer){0, 0, NULL};
}

// ============================================================
// Async future stubs (not used but required by linker)
// ============================================================

void ffi_horcrux_core_rust_future_poll_u8(uint64_t h, UniffiRustFutureContinuationCallback cb, uint64_t d) {}
void ffi_horcrux_core_rust_future_cancel_u8(uint64_t h) {}
void ffi_horcrux_core_rust_future_free_u8(uint64_t h) {}
uint8_t ffi_horcrux_core_rust_future_complete_u8(uint64_t h, RustCallStatus *s) { return 0; }
void ffi_horcrux_core_rust_future_poll_i8(uint64_t h, UniffiRustFutureContinuationCallback cb, uint64_t d) {}
void ffi_horcrux_core_rust_future_cancel_i8(uint64_t h) {}
void ffi_horcrux_core_rust_future_free_i8(uint64_t h) {}
int8_t ffi_horcrux_core_rust_future_complete_i8(uint64_t h, RustCallStatus *s) { return 0; }
void ffi_horcrux_core_rust_future_poll_u16(uint64_t h, UniffiRustFutureContinuationCallback cb, uint64_t d) {}
void ffi_horcrux_core_rust_future_cancel_u16(uint64_t h) {}
void ffi_horcrux_core_rust_future_free_u16(uint64_t h) {}
uint16_t ffi_horcrux_core_rust_future_complete_u16(uint64_t h, RustCallStatus *s) { return 0; }
void ffi_horcrux_core_rust_future_poll_i16(uint64_t h, UniffiRustFutureContinuationCallback cb, uint64_t d) {}
void ffi_horcrux_core_rust_future_cancel_i16(uint64_t h) {}
void ffi_horcrux_core_rust_future_free_i16(uint64_t h) {}
int16_t ffi_horcrux_core_rust_future_complete_i16(uint64_t h, RustCallStatus *s) { return 0; }
void ffi_horcrux_core_rust_future_poll_u32(uint64_t h, UniffiRustFutureContinuationCallback cb, uint64_t d) {}
void ffi_horcrux_core_rust_future_cancel_u32(uint64_t h) {}
void ffi_horcrux_core_rust_future_free_u32(uint64_t h) {}
uint32_t ffi_horcrux_core_rust_future_complete_u32(uint64_t h, RustCallStatus *s) { return 0; }
void ffi_horcrux_core_rust_future_poll_i32(uint64_t h, UniffiRustFutureContinuationCallback cb, uint64_t d) {}
void ffi_horcrux_core_rust_future_cancel_i32(uint64_t h) {}
void ffi_horcrux_core_rust_future_free_i32(uint64_t h) {}
int32_t ffi_horcrux_core_rust_future_complete_i32(uint64_t h, RustCallStatus *s) { return 0; }
void ffi_horcrux_core_rust_future_poll_u64(uint64_t h, UniffiRustFutureContinuationCallback cb, uint64_t d) {}
void ffi_horcrux_core_rust_future_cancel_u64(uint64_t h) {}
void ffi_horcrux_core_rust_future_free_u64(uint64_t h) {}
uint64_t ffi_horcrux_core_rust_future_complete_u64(uint64_t h, RustCallStatus *s) { return 0; }
void ffi_horcrux_core_rust_future_poll_i64(uint64_t h, UniffiRustFutureContinuationCallback cb, uint64_t d) {}
void ffi_horcrux_core_rust_future_cancel_i64(uint64_t h) {}
void ffi_horcrux_core_rust_future_free_i64(uint64_t h) {}
int64_t ffi_horcrux_core_rust_future_complete_i64(uint64_t h, RustCallStatus *s) { return 0; }
void ffi_horcrux_core_rust_future_poll_f32(uint64_t h, UniffiRustFutureContinuationCallback cb, uint64_t d) {}
void ffi_horcrux_core_rust_future_cancel_f32(uint64_t h) {}
void ffi_horcrux_core_rust_future_free_f32(uint64_t h) {}
float ffi_horcrux_core_rust_future_complete_f32(uint64_t h, RustCallStatus *s) { return 0.0f; }
void ffi_horcrux_core_rust_future_poll_f64(uint64_t h, UniffiRustFutureContinuationCallback cb, uint64_t d) {}
void ffi_horcrux_core_rust_future_cancel_f64(uint64_t h) {}
void ffi_horcrux_core_rust_future_free_f64(uint64_t h) {}
double ffi_horcrux_core_rust_future_complete_f64(uint64_t h, RustCallStatus *s) { return 0.0; }
void ffi_horcrux_core_rust_future_poll_pointer(uint64_t h, UniffiRustFutureContinuationCallback cb, uint64_t d) {}
void ffi_horcrux_core_rust_future_cancel_pointer(uint64_t h) {}
void ffi_horcrux_core_rust_future_free_pointer(uint64_t h) {}
void* ffi_horcrux_core_rust_future_complete_pointer(uint64_t h, RustCallStatus *s) { return &_dummy_object; }
void ffi_horcrux_core_rust_future_poll_rust_buffer(uint64_t h, UniffiRustFutureContinuationCallback cb, uint64_t d) {}
void ffi_horcrux_core_rust_future_cancel_rust_buffer(uint64_t h) {}
void ffi_horcrux_core_rust_future_free_rust_buffer(uint64_t h) {}
RustBuffer ffi_horcrux_core_rust_future_complete_rust_buffer(uint64_t h, RustCallStatus *s) {
    set_panic(s); return (RustBuffer){0, 0, NULL};
}
void ffi_horcrux_core_rust_future_poll_void(uint64_t h, UniffiRustFutureContinuationCallback cb, uint64_t d) {}
void ffi_horcrux_core_rust_future_cancel_void(uint64_t h) {}
void ffi_horcrux_core_rust_future_free_void(uint64_t h) {}
void ffi_horcrux_core_rust_future_complete_void(uint64_t h, RustCallStatus *s) {}

// ============================================================
// Checksum functions — must return exact values matching Swift bindings
// ============================================================

uint16_t uniffi_horcrux_core_checksum_func_horcrux_btc_address(void) { return 35696; }
uint16_t uniffi_horcrux_core_checksum_func_horcrux_build_btc_transaction(void) { return 64810; }
uint16_t uniffi_horcrux_core_checksum_func_horcrux_build_evm_transaction(void) { return 17961; }
uint16_t uniffi_horcrux_core_checksum_func_horcrux_build_solana_transaction(void) { return 40488; }
uint16_t uniffi_horcrux_core_checksum_func_horcrux_decrypt_shard(void) { return 27530; }
uint16_t uniffi_horcrux_core_checksum_func_horcrux_encrypt_shard(void) { return 20571; }
uint16_t uniffi_horcrux_core_checksum_func_horcrux_evm_address(void) { return 6260; }
uint16_t uniffi_horcrux_core_checksum_func_horcrux_generate_noise_keypair(void) { return 41959; }
uint16_t uniffi_horcrux_core_checksum_func_horcrux_generate_session_token(void) { return 58563; }
uint16_t uniffi_horcrux_core_checksum_func_horcrux_keccak256(void) { return 29475; }
uint16_t uniffi_horcrux_core_checksum_func_horcrux_solana_address(void) { return 22087; }
uint16_t uniffi_horcrux_core_checksum_method_horcruxnoisechannel_is_handshake_finished(void) { return 4594; }
uint16_t uniffi_horcrux_core_checksum_method_horcruxnoisechannel_open(void) { return 14291; }
uint16_t uniffi_horcrux_core_checksum_method_horcruxnoisechannel_read_handshake(void) { return 7520; }
uint16_t uniffi_horcrux_core_checksum_method_horcruxnoisechannel_remote_static_key(void) { return 23256; }
uint16_t uniffi_horcrux_core_checksum_method_horcruxnoisechannel_seal(void) { return 23269; }
uint16_t uniffi_horcrux_core_checksum_method_horcruxnoisechannel_write_handshake(void) { return 17542; }
uint16_t uniffi_horcrux_core_checksum_method_horcruxsessionmanager_create_keygen(void) { return 15041; }
uint16_t uniffi_horcrux_core_checksum_method_horcruxsessionmanager_create_signing(void) { return 55500; }
uint16_t uniffi_horcrux_core_checksum_method_horcruxsessionmanager_get_keygen_result(void) { return 62251; }
uint16_t uniffi_horcrux_core_checksum_method_horcruxsessionmanager_get_signing_result(void) { return 36798; }
uint16_t uniffi_horcrux_core_checksum_method_horcruxsessionmanager_handle_message(void) { return 49090; }
uint16_t uniffi_horcrux_core_checksum_method_horcruxsessionmanager_remove_session(void) { return 27155; }
uint16_t uniffi_horcrux_core_checksum_method_horcruxshardmanager_add_shard(void) { return 95; }
uint16_t uniffi_horcrux_core_checksum_method_horcruxshardmanager_list_shards(void) { return 37486; }
uint16_t uniffi_horcrux_core_checksum_method_horcruxshardmanager_shards_for_key(void) { return 14241; }
uint16_t uniffi_horcrux_core_checksum_constructor_horcruxnoisechannel_new_initiator(void) { return 40779; }
uint16_t uniffi_horcrux_core_checksum_constructor_horcruxnoisechannel_new_responder(void) { return 4320; }
uint16_t uniffi_horcrux_core_checksum_constructor_horcruxsessionmanager_new(void) { return 54717; }
uint16_t uniffi_horcrux_core_checksum_constructor_horcruxshardmanager_new(void) { return 2197; }

// Contract version
uint32_t ffi_horcrux_core_uniffi_contract_version(void) { return 26; }
