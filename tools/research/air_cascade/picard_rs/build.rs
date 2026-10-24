// Build script: records the rustc version for the result files (std only, no native code).
use std::process::Command;

fn main() {
    let rustc = std::env::var("RUSTC").unwrap_or_else(|_| "rustc".into());
    let ver = Command::new(rustc)
        .arg("--version")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|| "unknown".into());
    println!("cargo:rustc-env=PICARD_RUSTC_VERSION={ver}");
    println!("cargo:rerun-if-changed=build.rs");
}
