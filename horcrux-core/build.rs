fn main() {
    // UniFFI will be configured here for binding generation
    println!("cargo:rerun-if-changed=uniffi/horcrux.udl");
}
