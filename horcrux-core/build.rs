use std::env;
use std::path::PathBuf;

fn main() {
    // Using UniFFI proc-macro approach — no UDL scaffolding generation needed.
    // The UDL file is kept as documentation of the FFI interface.

    // Narrow-asm override for GMP mpn_addmul_1 / mpn_submul_1 on Apple arm64.
    //
    // gmp-mpfr-sys builds GMP with --disable-assembly on iOS (Mach-O ABI
    // mismatches in GMP's own darwin.m4 once broke the build), which makes
    // Paillier safe-prime generation ~5× slower than it needs to be.  We
    // compile a hand-ported copy of GMP's aarch64 aorsmul_1.asm and force-
    // load it so our symbols shadow the generic C fallback at link time.
    let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    let target_arch = env::var("CARGO_CFG_TARGET_ARCH").unwrap_or_default();
    let target_vendor = env::var("CARGO_CFG_TARGET_VENDOR").unwrap_or_default();
    // gmp-mpfr-sys only applies --disable-assembly when cross-compiling to
    // apple-ios — macOS / tvOS / watchOS keep GMP's own fast asm.  Only
    // force-load our override where it's actually needed.
    let is_ios_aarch64 = target_arch == "aarch64"
        && target_vendor == "apple"
        && (target_os == "ios" || target_os == "tvos" || target_os == "watchos");

    if is_ios_aarch64 {
        let asm = PathBuf::from("src/mpc/asm/addmul_1_arm64.S");
        println!("cargo:rerun-if-changed={}", asm.display());

        cc::Build::new()
            .file(&asm)
            .flag("-x")
            .flag("assembler-with-cpp")
            .compile("horcrux_gmp_override");

        // cc already emitted rustc-link-lib=static=horcrux_gmp_override and the
        // OUT_DIR search path.  Force-load the archive so our symbols shadow
        // the generic mpn_addmul_1 / mpn_submul_1 when libgmp.a is later
        // scanned by the linker.
        let out_dir = env::var("OUT_DIR").unwrap();
        println!(
            "cargo:rustc-link-arg=-Wl,-force_load,{}/libhorcrux_gmp_override.a",
            out_dir
        );
    }

    // Host-test build: on macOS aarch64, compile the same asm with
    // HORCRUX_ASM_TEST_SYMS so the symbols are renamed and don't collide with
    // libgmp.a's real ___gmpn_* on the link line.  Tests/addmul_correctness.rs
    // fuzz-compares these against a pure-Rust reference.  This is the only
    // correctness check we have short of running GMP's tests/devel suite;
    // since the asm bodies are identical, passing on macOS gives confidence
    // that the iOS build is also correct.
    let is_macos_aarch64 =
        target_arch == "aarch64" && target_vendor == "apple" && target_os == "macos";
    if is_macos_aarch64 {
        let asm = PathBuf::from("src/mpc/asm/addmul_1_arm64.S");
        println!("cargo:rerun-if-changed={}", asm.display());
        cc::Build::new()
            .file(&asm)
            .flag("-x")
            .flag("assembler-with-cpp")
            .define("HORCRUX_ASM_TEST_SYMS", None)
            .compile("horcrux_asm_test");

        // cargo:rustc-link-lib=static= on its own gets dead-stripped for
        // integration tests since nothing in the crate graph names these
        // symbols at compile time.  Force the archive in so ld keeps it.
        let out_dir = env::var("OUT_DIR").unwrap();
        println!(
            "cargo:rustc-link-arg=-Wl,-force_load,{}/libhorcrux_asm_test.a",
            out_dir
        );
    }
}
