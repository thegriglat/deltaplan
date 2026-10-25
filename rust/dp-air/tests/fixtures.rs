//! Читалка фикстур W8: тест сам пишет маленькую фикстуру во временный каталог.
use dp_air::fixtures::*;
use std::fs;
use std::path::PathBuf;

const W: usize = 4;
const H: usize = 3;

fn tmp(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("dp-air-fx-{}-{name}", std::process::id()));
    let _ = fs::remove_dir_all(&d);
    fs::create_dir_all(d.join("places")).unwrap();
    fs::create_dir_all(d.join("cases")).unwrap();
    d
}

fn place_header(h_offset: f64, h_scale: f64) -> String {
    format!(
        r#"{{"version":1,"loc":{{"id":"t","center_lat":50.0,"center_lon":86.0,"utc_offset_h":7.0,
"month":7,"day":1}},"grid":{{"origin_x":-50,"origin_z":-50,"spacing":25,"width":{W},"height":{H}}},
"surface_classes":{{"grass":1}},"start_sites":[],"h_offset":{h_offset},"h_scale":{h_scale}}}"#
    )
}

fn heights() -> Vec<f32> {
    (0..W * H)
        .map(|i| 400.0 + 37.3 * i as f32 + 0.123)
        .collect()
}

fn place_bin(h_offset: f64, h_scale: f64, hs: &[f32]) -> Vec<u8> {
    let n = W * H;
    let mut b = Vec::new();
    for &h in hs {
        let q = ((h as f64 - h_offset) / h_scale).round() as i16;
        b.extend_from_slice(&q.to_le_bytes());
    }
    b.extend((0..n).map(|i| (i % 2) as u8));
    b.extend((0..n).map(|i| (i % 5) as u8));
    b.extend((0..n).map(|i| (i * 20) as u8));
    b
}

fn case_json(version: u32, terms: &str) -> String {
    format!(
        r#"{{"version":{version},"place":"p","conditions":{{"forecast":{{"temperature_c":20,
"wind_speed_kmh":10,"wind_from_deg":270,"sky":"clear"}},"start_hour":12,"speed":1,"quantum_h":0.5}},
"seed":7,"static_thermals":[[1,2,3,4]],"configs_sha1":{{"sim.json":"abc"}},"times_s":[0,900],
"focuses":[[0,0,100,1]],"points":[[0,100,0],[10,200,20],[5,50,5]],
"point_tags":["ground","lee","far"],"terms":{terms},"generator":"test"}}"#
    )
}

fn data_bin(n_t: usize, n_p: usize, n_k: usize) -> Vec<u8> {
    (0..n_t * n_p * n_k * 4)
        .flat_map(|i| (i as f32 * 0.25).to_le_bytes())
        .collect()
}

#[test]
fn place_roundtrip_height_scale() {
    let d = tmp("place");
    let (off, sc) = (400.0, 0.1);
    let hs = heights();
    fs::write(d.join("places/p.json"), place_header(off, sc)).unwrap();
    fs::write(d.join("places/p.bin"), place_bin(off, sc, &hs)).unwrap();
    let p = read_place(&d.join("places/p.json")).unwrap();
    assert_eq!(p.heights().len(), W * H);
    for (a, b) in p.heights().iter().zip(&hs) {
        assert!((a - b).abs() <= 0.1, "{a} vs {b}");
    }
    assert_eq!(p.water()[1], 1);
    assert_eq!(p.cls()[4], 4);
    assert!((p.moist()[3] - 60.0 / 255.0).abs() < 1e-6);
    assert_eq!(p.header().grid.width, W as u32);
}

#[test]
fn place_errors() {
    let hs = heights();
    let h = place_header(0.0, 0.1);
    let mut bin = place_bin(0.0, 0.1, &hs);
    bin.pop();
    let e = parse_place(&h, &bin).unwrap_err();
    assert!(e.msg.contains("bytes"), "{e}");
    let e = parse_place(&h.replace("\"version\":1", "\"version\":2"), &[]).unwrap_err();
    assert!(e.msg.contains("version"), "{e}");
    let e = parse_place(&h.replace("\"h_scale\":0.1", "\"h_scale\":0"), &[]).unwrap_err();
    assert!(e.msg.contains("h_scale"), "{e}");
    let no_off = h.replace(",\"h_offset\":0", "");
    assert!(parse_place(&no_off, &[]).is_err());
    // файла нет — Err, не паника
    assert!(read_place(&PathBuf::from("/nonexistent/x.json")).is_err());
}

#[test]
fn case_roundtrip() {
    let d = tmp("case");
    let cj = case_json(1, r#"["field","analytic"]"#);
    fs::write(d.join("cases/c.json"), &cj).unwrap();
    let case = read_case(&d.join("cases/c.json")).unwrap();
    assert_eq!(case.n_k(), 4);
    assert_eq!(case.times_s, vec![0.0, 900.0]);
    assert_eq!(case.points.len(), 3);
    assert_eq!(case.focuses[0].weight, 1.0);
    assert_eq!(case.static_thermals, vec![[1.0, 2.0, 3.0, 4.0]]);
    assert_eq!(case.seed, 7);
    assert_eq!(
        case.place_path(&d.join("cases/c.json")),
        d.join("places/p.json")
    );

    fs::write(d.join("cases/c.bin"), data_bin(2, 3, 4)).unwrap();
    let data = read_case_data(&case, &d.join("cases/c.json")).unwrap();
    // [t=1][p=2][k=3] -> индекс ((1*3+2)*4+3)*4
    let v: Vec<_> = data.slab(1, 3).collect();
    let o = ((3 + 2) * 4 + 3) * 4;
    assert_eq!(v[2], [o, o + 1, o + 2, o + 3].map(|i| i as f32 * 0.25));
    assert_eq!(mode_of(1), Some(dp_air::SampleMode::Mean));
}

#[test]
fn case_errors() {
    let e = parse_case(&case_json(2, "null")).unwrap_err();
    assert!(e.msg.contains("version"), "{e}");
    let case = parse_case(&case_json(1, "null")).unwrap();
    assert_eq!(case.n_k(), 2);
    let e = parse_case_data(&case, &data_bin(2, 3, 2)[1..]).unwrap_err();
    assert!(e.msg.contains("bytes"), "{e}");
    let e = parse_case_data(&case, &data_bin(2, 3, 3)).unwrap_err();
    assert!(e.msg.contains("needs"), "{e}");
    let broken = case_json(1, "null").replace("\"ground\",", "");
    assert!(parse_case(&broken).is_err());
    assert!(parse_case("{").is_err());
}

#[test]
fn desc_roundtrip_and_errors() {
    let core: Vec<String> = (0..15)
        .map(|i| {
            if i == 11 {
                "null".into()
            } else {
                i.to_string()
            }
        })
        .collect();
    let core = format!("[{}]", core.join(","));
    let text = format!(
        r#"[{{"cores":[{core}],"clouds":[[1,2,3,4,5,6,7,8,9,4]],"crests":[],"cloudbase_msl":1800}},
{{"cores":[],"clouds":[],"crests":[[1,2,3,4]],"cloudbase_msl":1850.5}}]"#
    );
    let f = parse_desc(&text, 2).unwrap();
    assert_eq!(f[0].cores[0].top, 5.0);
    assert!(f[0].cores[0].life_s.is_nan());
    assert_eq!(f[0].clouds[0].decay, 9.0);
    assert_eq!(f[1].crests[0].crest, 4.0);
    assert_eq!(f[1].cloudbase_msl, 1850.5);
    assert!(parse_desc(&text, 3).is_err());
    let bad = text.replace("[1,2,3,4,5,6,7,8,9,4]", "[1,2,3]");
    assert!(parse_desc(&bad, 2).is_err());
    // плоский массив с шагом W6
    let flat = r#"{"frames":[{"cores":[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14],"cloudbase_msl":1}]}"#;
    assert_eq!(parse_desc(flat, 1).unwrap()[0].cores[0].storm, 14.0);
    let e = parse_desc(r#"[{"cores":[1,2,3]}]"#, 1).unwrap_err();
    assert!(e.msg.contains("multiple"), "{e}");
}
