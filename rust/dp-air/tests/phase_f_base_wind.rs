//! RW-U3: базовый ветер колонны F в смеси механизмов (`calm::mix`). Когда r = (1−F)(1−G) → 0
//! (сильный нагрев, слабый ветер: −z_i/L > 1e8), Σ механических весов колонны < eps, и смесь по
//! прежней формуле давала 0/1e-12 = 0. Теперь фон колонны — смесь по весам до r (`Classified::base`).
//! Проверки: (1) ветер F-колонн ≠ 0 и равен смеси по весам до r; (2) непрерывность через eps;
//! (3) колонны с Σ ≥ eps — побитно прежняя формула.
use dp_air::field::phase::calm::{MECH_EPS, mix};
use dp_air::field::phase::classifier::{Classified, Variant, classify};
use dp_air::field::phase::config::PhaseCfg;
use dp_air::field::phase::mech::{MechFields, mech_at};
use dp_air::field::phase::prepare::{
    PH_A, PH_B, PH_C, PH_D, PH_F, PH_H, PhaseCase, Prepared, prepare,
};
use std::path::PathBuf;

fn cfg() -> PhaseCfg {
    let p = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../configs/atmosphere.json");
    PhaseCfg::from_json(&std::fs::read_to_string(p).unwrap()).unwrap()
}

const NX: usize = 16;

/// Синтетика: холм 16×16, U10 0,2 м/с, u* 0,004, нагрев суши растёт вдоль x от −100 до 800 Вт/м².
fn synth() -> Prepared {
    let n2 = NX * NX;
    let (nz, dz, z_bot) = (46usize, 105.0, 525.0);
    let mut hc = vec![0.0; n2];
    let mut heat = vec![0.0; n2];
    for j in 0..NX {
        for i in 0..NX {
            let (x, y) = (i as f64 - 7.5, j as f64 - 7.5);
            hc[j * NX + i] = 650.0 + 800.0 * (-(x * x + y * y) / 18.0).exp();
            heat[j * NX + i] = -100.0 + 900.0 * i as f64 / (NX - 1) as f64;
        }
    }
    let gam = vec![0.005; nz + 2];
    let h_bl = vec![1500.0; n2];
    let wst = vec![2.0; n2];
    let zic: Vec<f64> = hc.iter().map(|h| h + 1500.0).collect();
    let case = PhaseCase {
        nx: NX,
        ny: NX,
        nz,
        dx: 2400.0,
        dz,
        z_bot,
        ex: std::f64::consts::FRAC_1_SQRT_2,
        ey: std::f64::consts::FRAC_1_SQRT_2,
        u_a: 0.31,
        z_sat: 10.45,
        alpha: 0.88,
        z0: 0.2,
        ustar: 0.004,
        tau_cool: 7200.0,
        u10: 0.2,
        z_i: 2400.0,
        hc: &hc,
        hc_type: &hc,
        gam: &gam,
        heat: &heat,
        heat_used: &heat,
        h_bl: &h_bl,
        wst: &wst,
        z_i_col: &zic,
        g: None,
    };
    prepare(&case, &cfg()).unwrap()
}

/// Прежняя формула (до RW-U3).
fn old_mix(w: &Classified, n2: usize, c: usize, m: &[f64; 10]) -> [f64; 3] {
    let wa = w.weights[PH_A * n2 + c] + w.weights[PH_C * n2 + c];
    let wd = w.weights[PH_D * n2 + c] + w.weights[PH_H * n2 + c];
    let wb = w.weights[PH_B * n2 + c];
    let sm = (wa + wb + wd).max(1e-12);
    let f = |a: f64, b: f64, d: f64| f64::from(((wa * a + wb * b + wd * d) / sm) as f32);
    [
        f(m[0], m[4], m[7]),
        f(m[1], m[5], m[8]),
        f(m[2], m[6], m[9]),
    ]
}

fn mech_sum(w: &Classified, n2: usize, c: usize) -> f64 {
    [PH_A, PH_B, PH_C, PH_D, PH_H]
        .iter()
        .map(|&k| w.weights[k * n2 + c])
        .sum()
}

#[test]
fn f_columns_keep_base_wind() {
    let p = synth();
    let n2 = p.n2;
    let w = classify(&p, Variant::Heat);
    let mf = MechFields::new(&p);
    let zmsl: f64 = 700.0 + 2000.0;
    let (mut n_small, mut n_big, mut n_zil, mut n_zero) = (0, 0, 0, 0);
    for c in 0..n2 {
        let m = mech_at(&p, &mf, c, zmsl.max(p.cols.hc[c] + 30.0));
        let got = mix(&w, n2, c, &m);
        let sum = mech_sum(&w, n2, c);
        if p.cols.hbl[c] * p.prm.kappa * p.prm.grav * p.cols.hk[c].max(0.0)
            / (p.prm.theta0 * p.prm.ustar.powi(3))
            > 1e8
        {
            n_zil += 1;
        }
        if sum < MECH_EPS {
            n_small += 1;
            let (ba, bb, bd) = (w.base[c], w.base[n2 + c], w.base[2 * n2 + c]);
            let bs = ba + bb + bd;
            assert!(bs > 1e-6, "колонна {c}: базовые веса пусты");
            for k in 0..2 {
                let want = (ba * m[k] + bb * m[4 + k] + bd * m[7 + k]) / bs;
                assert!(
                    (got[k] - want).abs() < 1e-6,
                    "колонна {c} k={k}: {} против {want}",
                    got[k]
                );
            }
            // прежняя формула при Σ < 1e-12 занижала ветер в Σ/1e-12 раз (до 0 при Σ → 0)
            if sum < 1e-12 {
                let old = old_mix(&w, n2, c, &m);
                let (mo, mg) = (old[0].hypot(old[1]), got[0].hypot(got[1]));
                assert!(mg > 0.01 && mo < 0.5 * mg, "колонна {c}: {mo} против {mg}");
                n_zero += 1;
            }
            assert!(w.weights[PH_F * n2 + c] > 0.99);
        } else {
            n_big += 1;
            let old = old_mix(&w, n2, c, &m);
            for k in 0..3 {
                assert_eq!(got[k].to_bits(), old[k].to_bits(), "колонна {c} k={k}");
            }
        }
    }
    assert!(n_zil > 0, "нет колонн с −z_i/L > 1e8");
    assert!(n_zero > 0, "нет колонн, где прежняя смесь обнулялась");
    assert!(n_small > 0, "нет колонн с Σ < eps");
    assert!(n_big > 0, "нет колонн с Σ ≥ eps");
}

/// Непрерывность: веса колонны масштабируются k·w, Σ идёт через eps; |ΔU| между соседними
/// шагами по k мал (< 1 % |U|).
#[test]
fn continuous_across_eps() {
    let n2 = 1;
    let m = [1.0, 0.2, 0.0, 0.0, -0.5, 1.0, 0.0, 0.3, -0.8, 0.0];
    let mut prev: Option<[f64; 3]> = None;
    let mut k = 1e-3;
    let mut hit_small = false;
    while k > 1e-14 {
        let mut weights = vec![0.0; 7];
        weights[PH_A] = 0.5 * k;
        weights[PH_B] = 0.3 * k;
        weights[PH_D] = 0.2 * k;
        let w = Classified {
            weights,
            base: vec![0.6, 0.1, 0.3],
            freeze: vec![0],
        };
        let u = mix(&w, n2, 0, &m);
        let mag = (u[0] * u[0] + u[1] * u[1]).sqrt();
        if let Some(q) = prev {
            let d = ((u[0] - q[0]).powi(2) + (u[1] - q[1]).powi(2)).sqrt();
            assert!(d < 0.01 * mag.max(0.1), "скачок {d} при k={k}");
        }
        hit_small |= k * 1.0 < MECH_EPS;
        prev = Some(u);
        k *= 0.99;
    }
    assert!(hit_small);
    // предел: Σ = 0 — чистый базовый ветер
    let w = Classified {
        weights: vec![0.0; 7],
        base: vec![0.6, 0.1, 0.3],
        freeze: vec![0],
    };
    let u = mix(&w, n2, 0, &m);
    let want = 0.6 * 1.0 + 0.1 * -0.5 + 0.3 * 0.3;
    assert!((u[0] - want).abs() < 1e-6);
    // базовые веса тоже пусты — поле A
    let w = Classified {
        weights: vec![0.0; 7],
        base: vec![0.0; 3],
        freeze: vec![0],
    };
    let u = mix(&w, n2, 0, &m);
    assert!((u[0] - 1.0).abs() < 1e-6 && (u[1] - 0.2).abs() < 1e-6);
}
