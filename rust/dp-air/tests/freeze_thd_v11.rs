//! W11 v11: поле заморозки решения с нагревом несёт `thd = Some(θ′ механизма)` (θ′_d := θ′ -
//! θ′ механизма F диабатический целиком); решение без нагрева и запасной путь - `thd = None`
//! (θ′_d = 0 / `late_mean`, W11 v5). Входы - дамп RW-6k/6m, как в `phase_assembly.rs`.
#![allow(dead_code)]
use dp_air::field::phase::assembly::assemble;
use dp_air::field::phase::config::PhaseCfg;
use dp_air::field::phase::prepare::PhaseCase;
use serde_json::Value;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::OnceLock;

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn cfg() -> PhaseCfg {
    let t = std::fs::read_to_string(root().join("../../configs/atmosphere.json")).unwrap();
    PhaseCfg::from_json(&t).unwrap()
}

struct Dump {
    meta: Value,
    bin: Vec<u8>,
}

impl Dump {
    fn load(dir: &str, name: &str) -> Dump {
        let d = root().join(dir);
        let meta =
            serde_json::from_str(&std::fs::read_to_string(d.join(format!("{name}.json"))).unwrap())
                .unwrap();
        Dump {
            meta,
            bin: std::fs::read(d.join(format!("{name}.bin"))).unwrap(),
        }
    }
    fn range(&self, k: &str, w: usize) -> &[u8] {
        let a = self.meta["arrays"]
            .get(k)
            .unwrap_or_else(|| panic!("нет массива {k}"));
        let (o, n) = (
            a["offset"].as_u64().unwrap() as usize,
            a["count"].as_u64().unwrap() as usize,
        );
        &self.bin[o..o + w * n]
    }
    fn f64s(&self, k: &str) -> Vec<f64> {
        self.range(k, 8)
            .chunks_exact(8)
            .map(|c| f64::from_le_bytes(c.try_into().unwrap()))
            .collect()
    }
    fn f32s(&self, k: &str) -> Vec<f32> {
        self.range(k, 4)
            .chunks_exact(4)
            .map(|c| f32::from_le_bytes(c.try_into().unwrap()))
            .collect()
    }
    fn u8s(&self, k: &str) -> Vec<u8> {
        self.range(k, 1).to_vec()
    }
    fn has(&self, k: &str) -> bool {
        self.meta["arrays"].get(k).is_some()
    }
}

/// Случай: вход фаз (дамп RW-6k) без стока (G считается здесь) и ожидания RW-6k.
struct Case {
    tag: String,
    scal: HashMap<String, f64>,
    hc: Vec<f64>,
    gam: Vec<f64>,
    heat: Vec<f64>,
    heat_used: Vec<f64>,
    h_bl: Vec<f64>,
    wst: Vec<f64>,
    zic: Vec<f64>,
    gw: Vec<f64>,
    frz_h: Vec<u8>,
    frz_m: Vec<u8>,
    /// G включён в GDScript.
    g_on: bool,
}

impl Case {
    fn s(&self, k: &str) -> f64 {
        self.scal[k]
    }
    fn input(&self) -> PhaseCase<'_> {
        PhaseCase {
            nx: self.s("nx") as usize,
            ny: self.s("ny") as usize,
            nz: self.s("nz") as usize,
            dx: self.s("dx"),
            dz: self.s("dz"),
            z_bot: self.s("z_bot"),
            ex: self.s("ex"),
            ey: self.s("ey"),
            u_a: self.s("usat"),
            z_sat: self.s("zsat"),
            alpha: self.s("alpha"),
            z0: self.s("z0"),
            ustar: self.s("ustar"),
            tau_cool: self.s("tau"),
            u10: self.s("u10"),
            z_i: self.s("z_i"),
            hc: &self.hc,
            hc_type: &self.hc,
            gam: &self.gam,
            heat: &self.heat,
            heat_used: &self.heat_used,
            h_bl: &self.h_bl,
            wst: &self.wst,
            z_i_col: &self.zic,
            g: None,
        }
    }
}

fn cases() -> &'static Vec<Case> {
    static A: OnceLock<Vec<Case>> = OnceLock::new();
    A.get_or_init(|| {
        let ph = Dump::load("tests/data/phase", "phase");
        let asm = Dump::load("tests/data/phase_assembly", "phase_assembly");
        let fields: Vec<String> = ph.meta["scal_fields"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_str().unwrap().to_string())
            .collect();
        asm.meta["cases"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| {
                let tag = c["tag"].as_str().unwrap().to_string();
                let sv = ph.f64s(&format!("{tag}/scal"));
                Case {
                    scal: fields.iter().cloned().zip(sv).collect(),
                    hc: ph.f64s(&format!("{tag}/hc")),
                    gam: ph.f64s(&format!("{tag}/gam")),
                    heat: ph.f64s(&format!("{tag}/heat")),
                    heat_used: ph.f64s(&format!("{tag}/heat_used")),
                    h_bl: ph.f64s(&format!("{tag}/h_bl")),
                    wst: ph.f64s(&format!("{tag}/wst")),
                    zic: ph.f64s(&format!("{tag}/zic")),
                    gw: ph.f64s(&format!("{tag}/gw")),
                    frz_h: ph.u8s(&format!("{tag}/frz_h")),
                    frz_m: ph.u8s(&format!("{tag}/frz_m")),
                    g_on: c["g"].as_bool().unwrap(),
                    tag,
                }
            })
            .collect()
    })
}

#[test]
fn heated_freeze_field_carries_theta_as_thd() {
    let (mut n_nc, mut n_th) = (0, 0);
    for c in cases() {
        let r = assemble(&c.input(), &cfg()).unwrap();
        let f = r.freeze.field.as_ref().unwrap();
        let thd = f
            .thd
            .as_ref()
            .unwrap_or_else(|| panic!("{}: thd None", c.tag));
        assert!(thd == &f.th, "{}: thd != th механизма", c.tag);
        n_th += usize::from(f.th.iter().any(|&x| x != 0.0));
        let m = r.freeze_mech.field.as_ref().unwrap();
        assert!(m.thd.is_none(), "{}: без нагрева thd = None", c.tag);
        if let Some(nc) = &r.nonconv {
            assert!(
                nc.field.as_ref().unwrap().thd.is_none(),
                "{}: nonconv",
                c.tag
            );
            n_nc += 1;
        }
    }
    assert!(n_th >= 1, "θ′ механизма везде нулевой");
    assert!(n_nc >= 1, "нет случая с запасным путём");
}
