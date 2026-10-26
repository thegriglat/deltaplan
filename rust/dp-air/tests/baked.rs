//! RW-6p: запечённые поля TI-К3 v3 и кеш полей против дампа GDScript
//! (`tools/research/rust_wind/dump_baked.sh`, данные — `tests/data/baked/`).
//!
//! Файлы читаются из `data/locations/*/air` репозитория. Допуски: опрос (скорость, θ′, `w_conv`)
//! ≤ 1e-4 по компоненте; срезы сырых массивов — побитно (`f16 → f32` точен); причины отказа
//! `baked_lookup` — текст в текст.
use dp_air::field::baked::{
    BakedField, BakedQuery, Cond, baked_lookup, key_diff, make_key, parse_baked,
};
use dp_air::field::field_cache::{FieldCache, Miss, name_of};
use serde_json::{Map, Value, json};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

struct Dump {
    json: Value,
    blob: Vec<f32>,
    arrays: HashMap<String, (usize, usize)>,
}

impl Dump {
    fn arr(&self, name: &str) -> &[f32] {
        let (o, l) = *self
            .arrays
            .get(name)
            .unwrap_or_else(|| panic!("в дампе нет массива '{name}'"));
        &self.blob[o..o + l]
    }
}

fn dump() -> &'static Dump {
    static D: OnceLock<Dump> = OnceLock::new();
    D.get_or_init(|| {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/data/baked");
        let text = std::fs::read_to_string(dir.join("baked.json")).unwrap_or_else(|e| {
            panic!(
                "нет дампа ({e}): снимите его tools/research/rust_wind/dump_baked.sh (под замком cpu)"
            )
        });
        let json: Value = serde_json::from_str(&text).unwrap();
        let raw = std::fs::read(dir.join("baked.bin")).unwrap();
        let blob = raw
            .chunks_exact(4)
            .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
            .collect();
        let arrays = json["arrays"]
            .as_object()
            .unwrap()
            .iter()
            .map(|(k, v)| {
                (
                    k.clone(),
                    (v[0].as_u64().unwrap() as usize, v[1].as_u64().unwrap() as usize),
                )
            })
            .collect();
        Dump { json, blob, arrays }
    })
}

/// Разобранные файлы дампа в его порядке (индекс = `file` сценария).
fn fields() -> &'static Vec<BakedField> {
    static F: OnceLock<Vec<BakedField>> = OnceLock::new();
    F.get_or_init(|| {
        dump().json["files"]
            .as_array()
            .unwrap()
            .iter()
            .map(|f| {
                let (lid, site) = (f["lid"].as_str().unwrap(), f["site"].as_str().unwrap());
                let base = repo_root().join("data/locations").join(lid).join("air");
                let head = std::fs::read_to_string(base.join(format!("{site}.json"))).unwrap();
                let bin = std::fs::read(base.join(format!("{site}.bin"))).unwrap();
                parse_baked(&head, &bin).unwrap_or_else(|e| panic!("{lid}/{site}: {e}"))
            })
            .collect()
    })
}

#[test]
fn parse_all_islands_match_gd_queries() {
    let d = dump();
    let n = d.json["n_points"].as_u64().unwrap() as usize;
    let stride = d.json["raw_stride"].as_u64().unwrap() as usize;
    let mut worst = 0.0f64;
    let mut checked = 0usize;
    for (fi, meta) in d.json["files"].as_array().unwrap().iter().enumerate() {
        let bf = &fields()[fi];
        let lvs = meta["levels"].as_array().unwrap();
        assert_eq!(bf.levels.len(), lvs.len(), "число уровней");
        for (li, lm) in lvs.iter().enumerate() {
            let tag = lm["tag"].as_str().unwrap();
            let f = &bf.levels[li];
            let g = f.grid();
            assert_eq!(
                (g.nx, g.ny, g.nz),
                (
                    lm["nx"].as_u64().unwrap() as usize,
                    lm["ny"].as_u64().unwrap() as usize,
                    lm["nz"].as_u64().unwrap() as usize
                )
            );
            assert_eq!(bf.names[li], lm["name"].as_str().unwrap());
            // срезы сырых массивов — побитно
            let cells = g.nx * g.ny * g.nz;
            for (suffix, raw) in [
                ("raw_u", f.raw_u()),
                ("raw_v", f.raw_v()),
                ("raw_wmech", f.raw_w_mech()),
                ("raw_wconv", f.raw_w_conv()),
                ("raw_theta", f.raw_theta()),
            ] {
                let want = d.arr(&format!("{tag}_{suffix}"));
                let got: Vec<f32> = (0..cells).step_by(stride).map(|c| raw[c]).collect();
                assert_eq!(got.len(), want.len(), "{tag} {suffix}: длина");
                for (i, (a, b)) in got.iter().zip(want).enumerate() {
                    assert_eq!(a.to_bits(), b.to_bits(), "{tag} {suffix}[{i}]: {a} != {b}");
                }
            }
            let hc = d.arr(&format!("{tag}_raw_hc"));
            assert_eq!(f.raw_hc(), hc, "{tag} hc");
            // опрос
            let pos = d.arr(&format!("{tag}_pos"));
            let vel = d.arr(&format!("{tag}_vel"));
            let th = d.arr(&format!("{tag}_theta"));
            let wc = d.arr(&format!("{tag}_wconv"));
            let ins = d.arr(&format!("{tag}_inside"));
            assert_eq!(pos.len(), n * 3);
            for q in 0..n {
                let p = [pos[q * 3], pos[q * 3 + 1], pos[q * 3 + 2]];
                assert_eq!(f.contains(p), ins[q] != 0.0, "{tag} contains #{q} {p:?}");
                let v = f.sample(p, f32::NAN);
                for c in 0..3 {
                    let e = (v[c] as f64 - vel[q * 3 + c] as f64).abs();
                    worst = worst.max(e);
                    assert!(
                        e <= 1e-4,
                        "{tag} #{q} v[{c}]: {} != {}",
                        v[c],
                        vel[q * 3 + c]
                    );
                }
                let (t, w) = (f.sample_theta(p, f32::NAN), f.sample_w_conv(p, f32::NAN));
                assert!(
                    (t - th[q] as f64).abs() <= 1e-4,
                    "{tag} #{q} θ: {t} != {}",
                    th[q]
                );
                assert!(
                    (w - wc[q] as f64).abs() <= 1e-4,
                    "{tag} #{q} wconv: {w} != {}",
                    wc[q]
                );
                checked += 1;
            }
        }
    }
    assert!(checked >= 8 * 3 * n, "проверено только {checked} точек");
    eprintln!("baked: {checked} точек, худшее расхождение скорости {worst:.2e} м/с");
}

#[test]
fn header_fields_and_inflow_k() {
    for (fi, meta) in dump().json["files"].as_array().unwrap().iter().enumerate() {
        let bf = &fields()[fi];
        assert_eq!(bf.location, meta["lid"].as_str().unwrap());
        assert_eq!(bf.site, meta["site"].as_str().unwrap());
        assert_eq!(bf.model_hash, dump().json["model_hash"].as_str().unwrap());
        assert_eq!(bf.levels.len(), 3);
        // уровни от мелкого к грубому
        let dx: Vec<f64> = bf.levels.iter().map(|l| l.grid().dx).collect();
        assert!(dx.windows(2).all(|w| w[0] < w[1]), "{dx:?}");
        assert!(bf.inflow_k > 0.0);
    }
}

#[test]
fn parse_rejects_bad_input() {
    let (head, bin) = {
        let base = repo_root().join("data/locations/training_island/air");
        (
            std::fs::read_to_string(base.join("lee_bowl.json")).unwrap(),
            std::fs::read(base.join("lee_bowl.bin")).unwrap(),
        )
    };
    assert!(parse_baked("не json", &bin).is_err());
    assert!(parse_baked(&head, &bin[..bin.len() / 2]).is_err());
    assert!(parse_baked(&head, &[]).is_err());
    let mut v: Value = serde_json::from_str(&head).unwrap();
    v["version"] = json!(2);
    assert!(parse_baked(&v.to_string(), &bin).is_err());
    let mut v: Value = serde_json::from_str(&head).unwrap();
    v["levels"][0]["arrays"]["u"][0] = json!(1.0e12);
    assert!(parse_baked(&v.to_string(), &bin).is_err());
    let mut v: Value = serde_json::from_str(&head).unwrap();
    v["levels"][0]["arrays"]
        .as_object_mut()
        .unwrap()
        .remove("hc");
    assert!(parse_baked(&v.to_string(), &bin).is_err());
    let mut v: Value = serde_json::from_str(&head).unwrap();
    v["raw_bytes"] = json!(12345);
    assert!(parse_baked(&v.to_string(), &bin).is_err());
}

// ---------------------------------------------------------------- baked_lookup

fn query<'a>(
    sc: &'a Value,
    data_hash: &'a str,
    model_hash: &'a str,
    wd: &'a [f64],
) -> BakedQuery<'a> {
    let c = &sc["cond"];
    BakedQuery {
        location: sc["lid"].as_str().unwrap(),
        center_lat: sc["center_lat"].as_f64().unwrap(),
        center_lon: sc["center_lon"].as_f64().unwrap(),
        site: sc["site_query"].as_str().unwrap(),
        start: [
            sc["start"][0].as_f64().unwrap(),
            sc["start"][1].as_f64().unwrap(),
        ],
        weather: &sc["weather"],
        month: sc["month"].as_i64().unwrap(),
        day: sc["day"].as_i64().unwrap(),
        window_dx: wd,
        data_hash,
        model_hash,
        cond: Cond {
            hour: c["hour"].as_f64().unwrap(),
            u10: c["u10"].as_f64().unwrap(),
            wdir: c["wdir"].as_f64().unwrap(),
            t_max: c["t_max"].as_f64().unwrap_or(f64::NAN),
            sky: c["sky"].as_str().unwrap(),
            wind_ref: c["wind_ref"].as_str().unwrap(),
        },
    }
}

#[test]
fn lookup_matches_gd_reasons() {
    let d = dump();
    let all = fields();
    let mut n_ok = 0;
    let mut n_reject = 0;
    for sc in d.json["scenarios"].as_array().unwrap() {
        let name = sc["name"].as_str().unwrap();
        let wd: Vec<f64> = sc["window_dx"]
            .as_array()
            .unwrap()
            .iter()
            .map(|x| x.as_f64().unwrap())
            .collect();
        let mh = sc["model_hash_now"].as_str().unwrap();
        let mut set: Vec<BakedField> = Vec::new();
        let mutated = sc["model_mutated"].as_str().unwrap();
        let slice: &[BakedField] = if mutated.is_empty() {
            all
        } else {
            let mut f = all[sc["file"].as_u64().unwrap() as usize].clone();
            f.model_hash = mutated.to_string();
            set.push(f);
            &set
        };
        let q = query(sc, sc["data_hash"].as_str().unwrap(), mh, &wd);
        let want = sc["reason"].as_str().unwrap();
        match baked_lookup(slice, &q) {
            Ok(f) => {
                assert_eq!(want, "", "{name}: Rust взял поле, GD отказал ({want})");
                assert_eq!(f.site, sc["site"].as_str().unwrap(), "{name}");
                n_ok += 1;
            }
            Err(r) => {
                assert_eq!(r.reason, want, "{name}: причина");
                assert_eq!(r.warn, sc["warn"].as_bool().unwrap(), "{name}: warn");
                assert_eq!(r.path, sc["path"].as_str().unwrap(), "{name}: путь");
                n_reject += 1;
            }
        }
    }
    assert!(n_ok >= 8 * 4, "ok-сценариев {n_ok}");
    assert!(n_reject >= 8 * 10, "отказов {n_reject}");
}

#[test]
fn lookup_wrong_data_hash_and_unknown_model() {
    let d = dump();
    let sc = &d.json["scenarios"][0];
    let wd: Vec<f64> = sc["window_dx"]
        .as_array()
        .unwrap()
        .iter()
        .map(|x| x.as_f64().unwrap())
        .collect();
    let mh = sc["model_hash_now"].as_str().unwrap();
    let q = query(sc, "0000000000000000", mh, &wd);
    let r = baked_lookup(fields(), &q).unwrap_err();
    assert!(r.warn);
    assert!(r.reason.starts_with("key.data_hash:"), "{}", r.reason);
    // хеш модели неизвестен — поле не берётся
    let q = query(sc, sc["data_hash"].as_str().unwrap(), "", &wd);
    let r = baked_lookup(fields(), &q).unwrap_err();
    assert!(
        r.warn && r.reason.contains("модель воздуха другой версии"),
        "{}",
        r.reason
    );
    // ключ, собранный по запросу, равен ключу файла
    let q = query(sc, sc["data_hash"].as_str().unwrap(), mh, &wd);
    let bf = &fields()[0];
    assert_eq!(key_diff(&bf.key, &make_key(&q)), "");
}

// ---------------------------------------------------------------- кеш

fn tmp_dir(name: &str) -> PathBuf {
    let p =
        Path::new(env!("CARGO_TARGET_TMPDIR")).join(format!("rw6p-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&p);
    p
}

fn cache_key(tag: &str) -> Value {
    json!({"format": 2, "place": "t", "tag": tag, "cond": {"u10": 8.5, "wdir": 270.0}})
}

/// Поля совпадают побитно по сырым массивам и опросу.
fn same_field(a: &BakedField, b: &BakedField) {
    assert_eq!(a.levels.len(), b.levels.len());
    assert_eq!(a.names, b.names);
    assert_eq!(a.location, b.location);
    assert_eq!(a.site, b.site);
    assert_eq!(a.inflow_k, b.inflow_k);
    for (x, y) in a.levels.iter().zip(&b.levels) {
        assert_eq!(x.grid(), y.grid());
        for (p, q) in [
            (x.raw_u(), y.raw_u()),
            (x.raw_v(), y.raw_v()),
            (x.raw_w_mech(), y.raw_w_mech()),
            (x.raw_w_conv(), y.raw_w_conv()),
            (x.raw_theta(), y.raw_theta()),
            (x.raw_hc(), y.raw_hc()),
            (x.heat_flux(), y.heat_flux()),
            (x.gam(), y.gam()),
            (x.z_i_col(), y.z_i_col()),
            (x.raw_ustar(), y.raw_ustar()),
            (x.raw_wstar(), y.raw_wstar()),
            (x.raw_hmix(), y.raw_hmix()),
        ] {
            assert_eq!(p.len(), q.len());
            assert!(p.iter().zip(q).all(|(s, t)| s.to_bits() == t.to_bits()));
        }
        assert_eq!(x.z_i().to_bits(), y.z_i().to_bits());
        assert_eq!(x.z0().to_bits(), y.z0().to_bits());
        let g = x.grid();
        for q in 0..50 {
            let t = q as f32 / 50.0;
            let p = [
                (g.x0 + t as f64 * g.nx as f64 * g.dx) as f32,
                (g.z_bot + (1.0 - t as f64) * 600.0) as f32,
                -(g.y0 + (1.0 - t as f64) * g.ny as f64 * g.dx) as f32,
            ];
            assert_eq!(x.sample(p, f32::NAN), y.sample(p, f32::NAN));
            assert_eq!(x.turb_at(p, f32::NAN), y.turb_at(p, f32::NAN));
        }
    }
}

const MH: &str = "50e249bed5ee6b3c";

#[test]
fn cache_put_get_bitwise() {
    let dir = tmp_dir("rt");
    let c = FieldCache::new(&dir);
    let key = cache_key("a");
    assert_eq!(c.get(&key, MH).unwrap_err(), Miss::Absent);
    let src = &fields()[1];
    let mut extra = Map::new();
    extra.insert("status".into(), json!("ok"));
    c.put(&key, MH, src, &extra).unwrap();
    assert!(c.path_of(&key).exists());
    let got = c.get(&key, MH).unwrap();
    same_field(src, &got);
    // другой ключ — промах; запись другой модели — отказ и файл удалён
    assert_eq!(c.get(&cache_key("b"), MH).unwrap_err(), Miss::Absent);
    match c.get(&key, "другая") {
        Err(Miss::Rejected(r)) => assert!(r.contains("модель воздуха другой версии"), "{r}"),
        other => panic!("{:?}", other.map(|_| ())),
    }
    assert!(!c.path_of(&key).exists());
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn cache_corrupt_file_is_miss_not_panic() {
    let dir = tmp_dir("bad");
    let c = FieldCache::new(&dir);
    let key = cache_key("x");
    let src = &fields()[0];
    c.put(&key, MH, src, &Map::new()).unwrap();
    let path = c.path_of(&key);
    let good = std::fs::read(&path).unwrap();
    let cases: Vec<(&str, Vec<u8>)> = vec![
        ("пустой", Vec::new()),
        ("мусор", b"not a cache record at all".to_vec()),
        ("обрезан", good[..good.len() / 2].to_vec()),
        ("только заголовок", good[..40].to_vec()),
        ("тело испорчено", {
            let mut b = good.clone();
            let n = b.len();
            for x in &mut b[n - 4000..n - 3000] {
                *x ^= 0xA5;
            }
            b
        }),
        ("длина заголовка", {
            let mut b = good.clone();
            b[8..16].copy_from_slice(&u64::MAX.to_le_bytes());
            b
        }),
    ];
    for (name, bytes) in cases {
        std::fs::write(&path, &bytes).unwrap();
        match c.get(&key, MH) {
            Err(Miss::Rejected(_)) => {}
            other => panic!("{name}: ждали промах, получили {:?}", other.map(|_| ())),
        }
        assert!(!path.exists(), "{name}: испорченный файл не удалён");
    }
    // после порчи запись снова кладётся и читается
    c.put(&key, MH, src, &Map::new()).unwrap();
    same_field(src, &c.get(&key, MH).unwrap());
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn cache_concurrent_put_same_key() {
    let dir = tmp_dir("mt");
    let c = FieldCache::new(&dir);
    let key = cache_key("race");
    let src = &fields()[2];
    std::thread::scope(|s| {
        for _ in 0..4 {
            s.spawn(|| {
                for _ in 0..3 {
                    c.put(&key, MH, src, &Map::new()).unwrap();
                    // читатель во время записей видит целую запись либо её отсутствие
                    match c.get(&key, MH) {
                        Ok(f) => assert_eq!(f.levels.len(), 3),
                        Err(Miss::Absent) => {}
                        Err(Miss::Rejected(r)) => panic!("порча при конкурентной записи: {r}"),
                    }
                }
            });
        }
    });
    same_field(src, &c.get(&key, MH).unwrap());
    // ни временных файлов, ни лишних записей
    let names: Vec<String> = std::fs::read_dir(&dir)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    assert_eq!(names, vec![format!("{}.dpac", name_of(&key))], "{names:?}");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn cache_evicts_oldest_over_limit() {
    let dir = tmp_dir("lru");
    let mut c = FieldCache::new(&dir);
    let src = &fields()[3];
    let (ka, kb, kc) = (cache_key("a"), cache_key("b"), cache_key("c"));
    c.put(&ka, MH, src, &Map::new()).unwrap();
    let one = c.total_bytes();
    assert!(one > 100_000, "{one}");
    std::thread::sleep(std::time::Duration::from_millis(30));
    c.put(&kb, MH, src, &Map::new()).unwrap();
    std::thread::sleep(std::time::Duration::from_millis(30));
    // a прочитана позже b — самой давней стала b
    assert!(c.get(&ka, MH).is_ok());
    std::thread::sleep(std::time::Duration::from_millis(30));
    c.max_bytes = one * 2 + one / 2;
    c.put(&kc, MH, src, &Map::new()).unwrap();
    assert!(c.total_bytes() <= c.max_bytes);
    assert!(c.path_of(&ka).exists(), "a вытеснена");
    assert!(c.path_of(&kc).exists(), "новая запись вытеснена");
    assert!(!c.path_of(&kb).exists(), "b осталась");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn cache_disabled_and_unwritable_dir() {
    let off = FieldCache::new("");
    assert!(!off.enabled());
    assert_eq!(off.get(&cache_key("z"), MH).unwrap_err(), Miss::Absent);
    off.put(&cache_key("z"), MH, &fields()[0], &Map::new())
        .unwrap();
    // каталог — файл: запись не удаётся, ошибка, не паника
    let dir = tmp_dir("file");
    std::fs::create_dir_all(dir.parent().unwrap()).unwrap();
    std::fs::write(&dir, b"x").unwrap();
    let c = FieldCache::new(&dir);
    assert!(
        c.put(&cache_key("z"), MH, &fields()[0], &Map::new())
            .is_err()
    );
    let _ = std::fs::remove_file(&dir);
}
