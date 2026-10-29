//! RW-P11: принимает ли крейт запечённые поля островов `data/locations/*/air` (8 файлов).
//!
//! Что проверяется: (1) файл читается `BakedEntry::new` (W2 `add_baked_field`) и `parse_baked`;
//! (2) `baked_lookup` с `model_hash` из самого файла и условиями из `key.weather` — принят (значит,
//! остальной ключ, `data_hash` и формат в порядке); (3) то же с `model_hash` текущей модели игры
//! (`CUR_MODEL_HASH`, снят Godot `AirBakedField.model_hash()` на ветке) — отказ «другой версии».
//! `CUR_*` — константы, снятые `godot --headless` (см. docs/research/rust-wind-stage3/baked-islands.md).
use dp_air::field::baked::{BakedQuery, Cond, baked_lookup, parse_baked};
use dp_air::field::runtime::BakedEntry;
use serde_json::Value;
use std::path::Path;

const CUR_MODEL_HASH: &str = "7da6a196ca606f39";
const CUR_DATA_TRAINING: &str = "a49fb9ea1b803627";
const CUR_DATA_VOLCANO: &str = "4a94276e1be0fdf8";

fn files() -> Vec<(String, String, std::path::PathBuf)> {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../data/locations");
    let mut out = Vec::new();
    for loc in ["training_island", "volcano_island"] {
        let mut v: Vec<_> = std::fs::read_dir(root.join(loc).join("air"))
            .unwrap()
            .map(|e| e.unwrap().path())
            .filter(|p| p.extension().is_some_and(|x| x == "json"))
            .collect();
        v.sort();
        for p in v {
            let site = p.file_stem().unwrap().to_string_lossy().to_string();
            out.push((loc.to_string(), site, p));
        }
    }
    out
}

fn query<'a>(
    key: &'a Value,
    loc: &'a str,
    site: &'a str,
    window: &'a [f64],
    data_hash: &'a str,
    model_hash: &'a str,
) -> BakedQuery<'a> {
    let w = &key["weather"];
    let num = |k: &str| w[k].as_f64().unwrap();
    let st = key["start"].as_array().unwrap();
    BakedQuery {
        location: loc,
        center_lat: key["center"][0].as_f64().unwrap(),
        center_lon: key["center"][1].as_f64().unwrap(),
        site,
        start: [st[0].as_f64().unwrap(), st[1].as_f64().unwrap()],
        weather: w,
        month: num("month") as i64,
        day: num("day") as i64,
        window_dx: window,
        data_hash,
        model_hash,
        cond: Cond {
            hour: num("start_hour"),
            u10: num("wind_speed_ms"),
            wdir: num("wind_from_deg"),
            t_max: num("temperature_c"),
            sky: w["sky"].as_str().unwrap(),
            wind_ref: w["wind_ref"].as_str().unwrap_or("start"),
        },
    }
}

#[test]
fn island_baked_files_probe() {
    let fs = files();
    assert_eq!(fs.len(), 8, "ждали 8 файлов (4 + 4)");
    for (loc, site, json_path) in fs {
        let header = std::fs::read_to_string(&json_path).unwrap();
        let data = std::fs::read(json_path.with_extension("bin")).unwrap();
        // (1) приём и разбор
        BakedEntry::new(&header, &data).unwrap_or_else(|e| panic!("{site}: {}", e.msg));
        let b = parse_baked(&header, &data).unwrap_or_else(|e| panic!("{site}: {}", e.msg));
        assert_eq!(b.levels.len(), 3, "{site}: уровней");
        let cur_data = if loc == "training_island" {
            CUR_DATA_TRAINING
        } else {
            CUR_DATA_VOLCANO
        };
        let key_data = b.key["data_hash"].as_str().unwrap();
        assert_eq!(key_data, cur_data, "{site}: data_hash файла и места");
        let win: Vec<f64> = b.key["window_dx"]
            .as_array()
            .unwrap()
            .iter()
            .map(|x| x.as_f64().unwrap())
            .collect();
        // (2) с model_hash из файла - принят
        let q = query(&b.key, &loc, &site, &win, key_data, &b.model_hash);
        let ok = baked_lookup(std::slice::from_ref(&b), &q);
        assert!(ok.is_ok(), "{site}: с хешем файла отказ: {:?}", ok.err());
        // (3) с model_hash текущей модели - отказ по хешу
        let q = query(&b.key, &loc, &site, &win, key_data, CUR_MODEL_HASH);
        let r = baked_lookup(std::slice::from_ref(&b), &q).expect_err("должен быть отказ");
        println!("PROBE {loc}/{site}: принят при хеше файла; при текущем хеше отказ: {}", r.reason);
        assert!(r.reason.contains("другой версии"), "{site}: причина {}", r.reason);
    }
}
