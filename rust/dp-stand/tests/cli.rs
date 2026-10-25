//! CLI на синтетике: Calm против нулевой фикстуры — PASS, против 1 м/с — FAIL с верным числом точек.
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

const N_P: usize = 5;
const N_T: usize = 2;

fn root(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("dp-stand-{}-{name}", std::process::id()));
    let _ = fs::remove_dir_all(&d);
    for s in ["places", "cases", "configs"] {
        fs::create_dir_all(d.join(s)).unwrap();
    }
    d
}

/// Пишет место, случай и данные; `vx` — значение vx во всех срезах, `cores` — json ядер.
fn write_fixture(d: &Path, vx: f32, terms: bool, desc: &str) {
    let (w, h) = (3usize, 3usize);
    fs::write(
        d.join("places/p.json"),
        format!(
            r#"{{"version":1,"loc":{{"id":"t","center_lat":50.0,"center_lon":86.0,"utc_offset_h":7.0,
"month":7,"day":1}},"grid":{{"origin_x":-50,"origin_z":-50,"spacing":50,"width":{w},"height":{h}}},
"surface_classes":{{}},"start_sites":[],"h_offset":0,"h_scale":0.1}}"#
        ),
    )
    .unwrap();
    fs::write(d.join("places/p.bin"), vec![0u8; 5 * w * h]).unwrap();
    let pts: Vec<String> = (0..N_P)
        .map(|i| format!("[{},100,{}]", i * 10, i * 5))
        .collect();
    let tags = ["\"ground\""; N_P].join(",");
    let terms_json = if terms {
        r#"["field","analytic"]"#
    } else {
        "null"
    };
    fs::write(
        d.join("cases/c.json"),
        format!(
            r#"{{"version":1,"place":"p","conditions":{{"preset":"calm","start_hour":12,"speed":1}},
"seed":1,"static_thermals":[],"configs_sha1":{{"sim.json":"0000"}},"times_s":[0,900],
"focuses":[],"points":[{}],"point_tags":[{tags}],"terms":{terms_json},"generator":"test"}}"#,
            pts.join(",")
        ),
    )
    .unwrap();
    let n_k = if terms { 4 } else { 2 };
    let bin: Vec<u8> = (0..N_T * N_P * n_k)
        .flat_map(|_| [vx, 0.0, 0.0, 0.0])
        .flat_map(f32::to_le_bytes)
        .collect();
    fs::write(d.join("cases/c.bin"), bin).unwrap();
    fs::write(d.join("cases/c.desc.json"), desc).unwrap();
    fs::write(d.join("configs/sim.json"), "{}").unwrap();
}

const EMPTY_DESC: &str = r#"[{"cores":[],"clouds":[],"crests":[],"cloudbase_msl":0},
{"cores":[],"clouds":[],"crests":[],"cloudbase_msl":0}]"#;

fn stand(d: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_dp-stand"))
        .args(args)
        .args(["--case", d.join("cases/c.json").to_str().unwrap()])
        .args(["--configs", d.join("configs").to_str().unwrap()])
        .output()
        .unwrap()
}

fn out(o: &Output) -> String {
    String::from_utf8_lossy(&o.stdout).into_owned()
}

#[test]
fn compare_zero_fixture_passes() {
    let d = root("pass");
    write_fixture(&d, 0.0, false, EMPTY_DESC);
    let o = stand(&d, &["compare"]);
    assert!(o.status.success(), "{}", out(&o));
    assert!(out(&o).contains("PASS"));
    // sha1 конфига не совпал — предупреждение, не ошибка
    assert!(String::from_utf8_lossy(&o.stderr).contains("sha1"));
}

#[test]
fn compare_one_ms_fixture_fails_with_count() {
    let d = root("fail");
    write_fixture(&d, 1.0, false, EMPTY_DESC);
    let o = stand(&d, &["compare"]);
    assert_eq!(o.status.code(), Some(1), "{}", out(&o));
    let s = out(&o);
    assert!(s.contains("FAIL"), "{s}");
    assert!(
        s.contains(&format!("points out of tolerance: {}", N_P * N_T)),
        "{s}"
    );
    // с --noise-replaced FULL не сравнивается, MEAN всё равно падает
    let o = stand(&d, &["compare", "--noise-replaced"]);
    assert_eq!(o.status.code(), Some(1));
    assert!(out(&o).contains("FULL skipped"));
    // допуск 0,05 + 2 % от 1 м/с = 0,07: Calm (0) — вне допуска, значит max d/tol = 1/0,07
    assert!(out(&o).contains("14.286"), "{}", out(&o));
}

#[test]
fn compare_checks_cores_and_terms() {
    let d = root("cores");
    let core = "[1,0,0,0,0,100,2,50,0,0,0,null,1,0,0]";
    let desc = format!(
        r#"[{{"cores":[{core}],"clouds":[],"crests":[],"cloudbase_msl":0}},
{{"cores":[],"clouds":[],"crests":[],"cloudbase_msl":0}}]"#
    );
    write_fixture(&d, 0.0, true, &desc);
    let o = stand(&d, &["compare", "--terms"]);
    let s = out(&o);
    assert_eq!(o.status.code(), Some(1), "{s}");
    assert!(s.contains("cores.count"), "{s}");
    // Calm не отдаёт слагаемых: они отмечены как отсутствующие
    assert!(s.contains("missing in decomposition"), "{s}");
    // без --terms слагаемые не сверяются
    let o = stand(&d, &["compare"]);
    assert!(out(&o).contains("cores.count"));
    assert!(!out(&o).contains("term."));
}

#[test]
fn sample_slice_stats_decompose() {
    let d = root("ops");
    write_fixture(&d, 0.0, false, EMPTY_DESC);
    let o = stand(&d, &["sample", "--mode", "full"]);
    assert!(o.status.success());
    assert_eq!(out(&o).lines().count(), 1 + N_P * N_T);
    let o = stand(&d, &["sample", "--points", "1,2,3;4,5,6", "--time", "0"]);
    assert_eq!(out(&o).lines().count(), 3);

    let prefix = d.join("s").to_str().unwrap().to_string();
    let o = stand(
        &d,
        &[
            "slice", "--step", "10", "--x", "0,100", "--z", "0,50", "--y", "300", "--out", &prefix,
        ],
    );
    assert!(o.status.success(), "{}", String::from_utf8_lossy(&o.stderr));
    let h: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(d.join("s.json")).unwrap()).unwrap();
    assert_eq!((h["nx"].as_u64(), h["ny"].as_u64()), (Some(11), Some(6)));
    assert_eq!(fs::metadata(d.join("s.bin")).unwrap().len(), 11 * 6 * 16);

    let o = stand(
        &d,
        &["stats", "--slice", d.join("s.json").to_str().unwrap()],
    );
    assert!(o.status.success());
    let s: serde_json::Value = serde_json::from_str(&out(&o)).unwrap();
    assert_eq!(s["n"], 66);
    assert_eq!(s["max_abs_vy"], 0.0);

    let o = stand(
        &d,
        &[
            "stats", "--min", "0,0,0", "--max", "10,10,10", "--step", "5",
        ],
    );
    let s: serde_json::Value = serde_json::from_str(&out(&o)).unwrap();
    assert_eq!(s["n"], 27);

    let o = stand(
        &d,
        &[
            "slice", "--kind", "vertical", "--from", "0,0", "--to", "30,40", "--ys", "0,100",
            "--step", "25", "--out", &prefix,
        ],
    );
    assert!(o.status.success());
    let h: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(d.join("s.json")).unwrap()).unwrap();
    assert_eq!((h["nx"].as_u64(), h["ny"].as_u64()), (Some(3), Some(5)));

    let o = stand(&d, &["decompose", "--point", "0,100,0"]);
    assert!(o.status.success());
    assert!(serde_json::from_str::<serde_json::Value>(&out(&o)).is_ok());
}

#[test]
fn errors_are_messages_not_panics() {
    let d = root("err");
    write_fixture(&d, 0.0, false, EMPTY_DESC);
    fs::write(d.join("cases/c.bin"), [0u8; 7]).unwrap();
    let o = stand(&d, &["compare"]);
    assert_eq!(o.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&o.stderr).contains("bytes"));
    let o = stand(&d, &["sample", "--model", "nope"]);
    assert_eq!(o.status.code(), Some(2));
    let o = stand(&d, &["sample", "--mode", "x"]);
    assert_eq!(o.status.code(), Some(2));
}
