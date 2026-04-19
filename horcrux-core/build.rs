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
    let is_apple_aarch64 =
        target_arch == "aarch64" && target_vendor == "apple"
            && (target_os == "ios" || target_os == "macos" || target_os == "tvos" || target_os == "watchos");

    if is_apple_aarch64 {
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
}
