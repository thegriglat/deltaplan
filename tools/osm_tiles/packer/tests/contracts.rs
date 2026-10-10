//! Контрактные тесты O1–O7 (запускаются `cargo test --release` в этом каталоге).

use osmtiles::{codec, cover, grid, manifest, pb, sample, stats};
use prost::Message;
use serde_json::Value;
use std::path::{Path, PathBuf};

fn repo() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..")
}
fn golden_dir() -> PathBuf {
    repo().join("tests/contracts/osm_tiles")
}
fn read_json(p: &Path) -> Value {
    serde_json::from_slice(&std::fs::read(p).unwrap()).unwrap()
}
fn tmpdir(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("osmtiles-test-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

#[test]
fn grid_matches_golden() {
    let g = read_json(&golden_dir().join("grid_golden.json"));
    let bands = g["bands"].as_array().unwrap();
    assert_eq!(bands.len(), 1000);
    for b in bands {
        let j = b["j"].as_i64().unwrap() as i32;
        let band = grid::Band::new(j);
        assert_eq!(band.n as i64, b["n"].as_i64().unwrap(), "n(j={j})");
        assert!((band.dlon - b["dlon"].as_f64().unwrap()).abs() < 1e-12);
        assert!((band.kx - b["kx"].as_f64().unwrap()).abs() < 1e-6);
    }
    let pts = g["points"].as_array().unwrap();
    assert!(pts.len() >= 300);
    for p in pts {
        let (lat, lon) = (p["lat"].as_f64().unwrap(), p["lon"].as_f64().unwrap());
        let (j, i, x, y) = grid::project(lat, lon);
        assert_eq!((j as i64, i as i64), (p["j"].as_i64().unwrap(), p["i"].as_i64().unwrap()), "{lat} {lon}");
        assert!((x - p["x"].as_f64().unwrap()).abs() < 1e-6 && (y - p["y"].as_f64().unwrap()).abs() < 1e-6, "{lat} {lon}");
    }
    let nbs = g["neighbors"].as_array().unwrap();
    assert!(nbs.len() >= 20);
    for n in nbs {
        let got: Vec<Value> = grid::neighbors(n["lat"].as_f64().unwrap(), n["lon"].as_f64().unwrap())
            .into_iter()
            .map(|(j, i)| serde_json::json!([j, i]))
            .collect();
        assert_eq!(Value::Array(got), n["tiles"], "{n}");
    }
}

#[test]
fn encode_decode_roundtrip() {
    for frag in [false, true] {
        let t = sample::sample_tile(frag);
        let bytes = codec::encode_tile(&t, None).unwrap();
        assert_eq!(&bytes[0..4], b"DPOT");
        assert_eq!(u16::from_le_bytes([bytes[6], bytes[7]]), frag as u16);
        let back = codec::decode_tile(&bytes).unwrap();
        assert_eq!(back, t);
        // детерминизм
        assert_eq!(bytes, codec::encode_tile(&t, None).unwrap());
    }
}

#[test]
fn streams_sorted_and_empty_dropped() {
    let mut t = sample::sample_tile(false);
    t.streams.reverse();
    t.streams.push(codec::StreamData { kind: pb::Kind::Canal, objects: codec::Objects::Generic(vec![]), ids: vec![] });
    t.streams.retain(|s| s.kind != pb::Kind::Canal || !s.objects.is_empty());
    let back = codec::decode_tile(&codec::encode_tile(&t, Some(3)).unwrap()).unwrap();
    let kinds: Vec<i32> = back.streams.iter().map(|s| s.kind as i32).collect();
    assert!(kinds.windows(2).all(|w| w[0] < w[1]));
    assert_eq!(kinds.len(), 14);
}

#[test]
fn fragment_requires_ids() {
    let mut t = sample::sample_tile(true);
    t.streams[0].ids.pop();
    assert!(codec::encode_tile(&t, None).is_err());
    let mut t = sample::sample_tile(false);
    t.streams[0].ids = vec![1, 2, 3];
    assert!(codec::encode_tile(&t, None).is_err());
}

#[test]
fn committed_samples_match() {
    for (name, frag) in [("sample_v1", false), ("sample_frag_v1", true)] {
        let file = std::fs::read(golden_dir().join(format!("{name}.dpt"))).unwrap();
        // образец, записанный в репозиторий, разбирается в те же структуры, что строит sample_tile
        assert_eq!(codec::decode_tile(&file).unwrap(), sample::sample_tile(frag), "{name}");
        // и даёт ровно ожидаемый JSON
        assert_eq!(codec::dump_json(&file).unwrap(), read_json(&golden_dir().join(format!("{name}.json"))), "{name}");
    }
}

#[test]
fn sample_has_all_streams() {
    let t = sample::sample_tile(false);
    assert_eq!(t.streams.len(), 14);
    assert!(t.streams.iter().all(|s| (2..=3).contains(&s.objects.len())));
}

#[test]
fn manifest_roundtrip() {
    let root = tmpdir("manifest");
    let dir = root.join("v1/252");
    std::fs::create_dir_all(&dir).unwrap();
    let f = codec::encode_tile(&sample::sample_tile(false), None).unwrap();
    std::fs::write(dir.join("755.dpt"), &f).unwrap();
    std::fs::write(dir.join("754.dpt"), &f).unwrap();
    let m = manifest::build_manifest(
        &root,
        manifest::parse_sources(&serde_json::json!([
            {"region": "slovenia", "url": "https://x/s.pbf", "md5": "ab", "osm_timestamp": 5, "pbf_bytes": 9},
            {"region": "austria", "url": "u", "md5": "cd", "osm_timestamp": 6, "pbf_bytes": 10}]))
        .unwrap(),
        1234,
    )
    .unwrap();
    let enc = m.encode_to_vec();
    let back = pb::TileManifest::decode(enc.as_slice()).unwrap();
    assert_eq!(back, m);
    assert_eq!(back.tiles.iter().map(|t| (t.j, t.i)).collect::<Vec<_>>(), [(252, 754), (252, 755)]);
    assert_eq!(back.sources[0].region, "austria");
    assert_eq!(back.total_bytes, 2 * f.len() as u64);
    assert_eq!(back.tiles[0].sha256, manifest::sha256_of(&f));
    assert_eq!(back.tiles[0].sha256.len(), 32);
}

#[test]
fn stats_on_sample() {
    let root = tmpdir("stats");
    let dir = root.join("v1/252");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("755.dpt"), codec::encode_tile(&sample::sample_tile(false), None).unwrap()).unwrap();
    let v = stats::stats_json(&root, true, None, None).unwrap();
    assert_eq!(v["n_tiles"], 1);
    let t = &v["tiles"]["252,755"]["streams"];
    assert_eq!(t["roads"]["count"], 3);
    assert!(t["roads"]["len_km"].as_f64().unwrap() > 20.0);
    assert!(t["roads"]["zstd"].as_u64().unwrap() > 0);
    assert!(t["peak"].get("len_km").is_none());
    assert_eq!(t["names"]["count"], 3);
    assert_eq!(v["totals"]["roads"]["count"], 3);
    // детерминизм
    assert_eq!(v, stats::stats_json(&root, true, None, Some(1)).unwrap());
}

#[test]
fn cover_slovenia_contains_reference_inside() {
    let poly = Path::new("/home/greg/deltaplan_data/osm_pack/slovenia.poly");
    let r = repo().join("tools/research/osm_pack/results/tiles20_slovenia.json");
    if !poly.exists() || !r.exists() {
        eprintln!("SKIP: нет slovenia.poly или эталона");
        return;
    }
    let tiles = cover::cover(&cover::parse_poly(&std::fs::read_to_string(poly).unwrap()).unwrap());
    let rj = read_json(&r);
    let mut n = 0;
    for (k, v) in rj["tiles"].as_object().unwrap() {
        if v["inside"].as_bool() == Some(true) {
            let (j, i) = k.split_once(',').unwrap();
            assert!(tiles.contains(&(j.parse().unwrap(), i.parse().unwrap())), "нет {k}");
            n += 1;
        }
    }
    assert_eq!(n, 28);
}
