// Схема protobuf компилируется протоксом (чистый Rust): системный protoc не нужен.
fn main() {
    let proto = "../proto/osm_tiles.proto";
    println!("cargo:rerun-if-changed={proto}");
    let fds = protox::compile([proto], ["../proto"]).expect("proto");
    prost_build::compile_fds(fds).expect("prost");
}
