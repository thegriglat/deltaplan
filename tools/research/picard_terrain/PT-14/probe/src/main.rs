//! PT-14: зонд крейта — синтетический гребень (как tests/atmosphere), поле, каналы болтанки,
//! признак отрыва и разложение. Запуск: pt14-probe <repo> <ridge|flat> <ветер км/ч> <out.json> [plane]
use dp_air::field::field_set::FieldSet;
use dp_air::field::runtime::{RtCfg, ground_height};
use dp_air::field::solved::parse_solved;
use dp_air::field::wind_field::{T_AOUT, T_DESC, T_HMIX, T_N2, T_SHEAR, T_UOUT, T_USTAR};
use dp_air::terms::turb::{sep, sigma::TurbCfg};
use dp_air::{AirModel, Conditions, Configs, Focus, Formula, Place, PlaceHeader, State};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

fn collect(dir: &Path, prefix: &str, out: &mut Vec<(String, String)>) {
    for e in std::fs::read_dir(dir).unwrap() {
        let p = e.unwrap().path();
        let name = format!("{prefix}{}", p.file_name().unwrap().to_string_lossy());
        if p.is_dir() {
            collect(&p, &format!("{name}/"), out);
        } else if p.extension().is_some_and(|x| x == "json") {
            out.push((name.trim_end_matches(".json").to_string(), std::fs::read_to_string(&p).unwrap()));
        }
    }
}

fn configs(repo: &Path, dl: Option<f64>) -> Configs {
    let mut files = Vec::new();
    collect(&repo.join("configs"), "", &mut files);
    for (n, t) in &mut files {
        if n == "atmosphere" {
            let mut v: Value = serde_json::from_str(t).unwrap();
            v["air"]["deterministic"] = json!(true);
            if let Some(d) = dl {
                v["air"]["domain_l_m"] = json!(d);
            }
            *t = serde_json::to_string(&v).unwrap();
        }
    }
    files.sort();
    Configs::new(files)
}

fn ridge(x: f64) -> f32 {
    (300.0 * (-(x / 400.0) * (x / 400.0)).exp()) as f32
}

fn place(kind: &str) -> Place {
    let half: f64 = 3000.0;
    let sp: f64 = 25.0;
    let n = (2.0 * half / sp).round() as usize + 1;
    let header = format!(
        r#"{{"version":1,"loc":{{"id":"rig","center_lat":51.5,"center_lon":86.5,"utc_offset_h":6.0,"month":7,"day":15}},"grid":{{"origin_x":{},"origin_z":{},"spacing":{},"width":{n},"height":{n}}},"surface_classes":{{"grass":1}},"start_sites":[]}}"#,
        -half, -half, sp
    );
    let h = PlaceHeader::from_json(&header).unwrap();
    let mut hs = vec![0f32; n * n];
    for j in 0..n {
        for i in 0..n {
            let x = -half + i as f64 * sp;
            hs[j * n + i] = match kind {
                "ridge" => ridge(x),
                _ => 500.0,
            };
        }
    }
    let c = h.cells();
    Place::new(h, hs, vec![0; c], vec![1; c], vec![1.0; c]).unwrap()
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let repo = PathBuf::from(&a[1]);
    let kind = a[2].as_str();
    let kmh: f64 = a[3].parse().unwrap();
    let out = &a[4];
    let dl = a.get(5).and_then(|s| s.parse::<f64>().ok());
    let gd: Option<Value> = std::env::var("PT14_GDINPUT").ok().map(|f| serde_json::from_str(&std::fs::read_to_string(f).unwrap()).unwrap());
    let cfgs = if let Some(g) = &gd {
        // конфиги и условия — ровно те, что отправляет фасад GDScript (зонд probe_ridge.gd)
        let arr = g["configs"].as_array().unwrap();
        let mut files: Vec<(String, String)> = arr.chunks(2).map(|c| (c[0].as_str().unwrap().to_string(), c[1].as_str().unwrap().replace("\"deterministic\": false", "\"deterministic\": true"))).collect();
        files.sort();
        Configs::new(files)
    } else {
        configs(&repo, dl)
    };
    let mut preset: Value = serde_json::from_str(&std::fs::read_to_string(repo.join("configs/weather/medium.json")).unwrap()).unwrap();
    preset["wind_speed_kmh"] = json!(kmh);
    preset["wind_from_deg"] = json!(270.0);
    preset["background_sink_ms"] = json!(0.0);
    preset["convective_turbulence_ms"] = json!(0.0);
    preset["temperature_c"] = json!(20.0);
    let cond = if let Some(g) = &gd {
        let mut c = g["cond"].clone();
        c["rebuild"] = json!(false);
        Conditions::from_json(&c.to_string()).unwrap()
    } else {
        Conditions::from_json(&json!({"preset": preset, "start_hour": 12.0, "speed": 1.0}).to_string()).unwrap()
    };
    let pl = place(kind);
    let mut m = Formula::new().with_deterministic(true);
    m.configure(&cfgs, 7).unwrap();
    m.set_conditions(&cond).unwrap();
    m.set_static_thermals(&[], 1).unwrap();
    m.set_focuses(&[Focus { pos: [0.0, if kind == "ridge" { 300.0 } else { 600.0 }, 0.0], weight: 1.0 }]).unwrap();
    m.load_place(pl.clone()).unwrap();
    let t0 = Instant::now();
    loop {
        m.poll();
        if m.status().state == State::Ready && m.level_count() > 0 {
            break;
        }
        assert_ne!(m.status().state, State::Failed, "{}", m.status().reason);
        assert!(t0.elapsed() < Duration::from_secs(1800));
        std::thread::sleep(Duration::from_millis(5));
    }
    m.advance_to(0.01).unwrap();
    let e = m.field_export();
    let b = parse_solved(&e.header_json, &e.data).unwrap();
    let rt = RtCfg::from_configs(&cfgs).unwrap();
    let mut fs = FieldSet::new(rt.limits, rt.edge_blend_cells);
    fs.set_field(b.levels, 0.0);
    let cfg = TurbCfg::from_configs(&cfgs);
    let z0 = fs.levels().first().map_or(0.1, |l| l.z0());
    let lv: Vec<Value> = fs.levels().iter().map(|l| {
        let g = l.grid();
        json!({"nx": g.nx, "ny": g.ny, "nz": g.nz, "dx": g.dx, "dz": g.dz, "z_bot": g.z_bot, "x0": g.x0, "y0": g.y0, "z0": l.z0()})
    }).collect();
    let xs: Vec<f64> = if kind == "ridge" {
        vec![-900.0, -600.0, -300.0, -150.0, 0.0, 100.0, 150.0, 200.0, 250.0, 300.0, 350.0, 500.0, 800.0]
    } else {
        vec![0.0, 400.0, -700.0]
    };
    let agls = [5.0f64, 10.0, 20.0, 30.0, 40.0, 60.0, 80.0, 120.0, 150.0, 200.0, 300.0, 600.0];
    let mut pts = Vec::new();
    for &x in &xs {
        let g = if kind == "ridge" { ridge(x) } else { 500.0 };
        for &agl in &agls {
            let p = [x as f32, g + agl as f32, 0.0f32];
            let gh = ground_height(&pl, p[0], p[2]);
            let s = fs.sample(p, gh);
            let uf = if s.share > 0.0 { (s.v[0] * s.v[0] + s.v[2] * s.v[2]).sqrt() / s.share } else { 0.0 };
            let tb = fs.sample_turb(p, gh);
            let lee_f = sep::lee(&cfg, z0, uf, agl, &tb);
            // скорость поля на уровне гребня (U_H) на той же вертикали
            let fh = fs.sample([x as f32, 300.0, 0.0], gh);
            let u_h = if fh.share > 0.0 { (fh.v[0] * fh.v[0] + fh.v[2] * fh.v[2]).sqrt() / fh.share } else { 0.0 };
            let sg = dp_air::terms::turb::sigma::sigma(&cfg, z0, agl, &tb, [0.0, 0.0], uf);
            let du = (u_h - uf).max(0.0) * lee_f;
            let sep_s = sep::sep_sigma(&cfg, du);
            let d = m.decompose(p);
            let mut tv = serde_json::Map::new();
            let mut ts = serde_json::Map::new();
            for (i, n) in d.names.iter().enumerate() {
                tv.insert(n.clone(), json!(d.vel[i]));
                ts.insert(n.clone(), json!(d.sigma[i]));
            }
            pts.push(json!({
                "x": x, "agl": agl, "ground": gh,
                "share": s.share, "field_v": s.v, "uf": uf, "wf": s.v[1] as f64 / s.share.max(1e-9),
                "u_h": u_h, "du_raw": (u_h - uf).max(0.0),
                "tb": {"shear": tb[T_SHEAR], "n2": tb[T_N2], "ustar": tb[T_USTAR], "u_out": tb[T_UOUT], "a_out": tb[T_AOUT], "desc": tb[T_DESC], "hmix": tb[T_HMIX]},
                "lee_f": lee_f, "du": du, "sg_u": sg.s_u, "sg_w": sg.s_w, "sep_u": sep_s[0], "sep_w": sep_s[1], "sw_total": sg.s_w.max(sep_s[1]), "dx_cell": fs.sample_dx(p),
                "vel": tv, "sigma": ts, "total": d.total,
            }));
        }
    }
    // линии на фиксированной высоте MSL (путь планера через гребень): поле и σ
    let mut lines = Vec::new();
    if kind == "ridge" {
        for &y in &[330.0f32, 350.0, 400.0, 500.0] {
            let mut row = Vec::new();
            let mut x = -400.0f32;
            while x <= 800.0 {
                let p = [x, y, 0.0f32];
                let gh = ground_height(&pl, p[0], p[2]);
                let s = fs.sample(p, gh);
                let d = m.decompose(p);
                let ki = d.names.iter().position(|n| n == "field").unwrap();
                let kt = d.names.iter().position(|n| n == "turb").unwrap();
                row.push(json!({"x": x, "ground": gh, "field_v": s.v, "share": s.share, "field_term": d.vel[ki], "turb_sigma": d.sigma[kt], "total": d.total}));
                x += 50.0;
            }
            lines.push(json!({"y_msl": y, "row": row}));
        }
    }
    // столбцы уровня 400 м: hc, k1, u*, U_out, desc и профиль u, w по первым клеткам
    let mut cols = Vec::new();
    if let Some(l) = fs.levels().first() {
        let g = l.grid();
        let (nx, ny, nz) = (g.nx, g.ny, g.nz);
        let nxy = nx * ny;
        let j = ny / 2;
        for i in 0..nx {
            let c = j * nx + i;
            let xc = g.x0 + (i as f64 + 0.5) * g.dx;
            let pos = [xc as f32, l.raw_hc()[c] + 40.0, 0.0f32];
            let tb = l.turb_at(pos, l.raw_hc()[c]);
            let prof_u: Vec<f64> = (0..10.min(nz)).map(|k| l.raw_u()[k * nxy + c] as f64).collect();
            let prof_w: Vec<f64> = (0..10.min(nz)).map(|k| l.raw_w_mech()[k * nxy + c] as f64).collect();
            cols.push(json!({"i": i, "xc": xc, "hc": l.raw_hc()[c], "k1": l.raw_k1()[c], "ustar": tb[T_USTAR], "u_out": tb[T_UOUT], "a_out": tb[T_AOUT], "desc": tb[T_DESC], "u": prof_u, "w": prof_w}));
        }
    }
    let doc = json!({"columns": cols, "lines": lines, "kind": kind, "wind_kmh": kmh, "z0": z0, "levels": lv, "turb_cfg": {"ex0": cfg.ex0, "ex1": cfg.ex1, "desc": cfg.desc, "sep_su": cfg.sep_su, "sep_sw": cfg.sep_sw}, "points": pts});
    std::fs::write(out, serde_json::to_string_pretty(&doc).unwrap()).unwrap();
    println!("written {out} points={}", doc["points"].as_array().unwrap().len());
}
