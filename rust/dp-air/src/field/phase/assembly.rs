//! Сборка фаз 3: тёплый старт `warm` (раскладка `picard_rs::state::State` с ореолом), поля
//! заморозки `mech_field`/`mech_field_mech` и запасного пути `nonconv_field`, статистика.
//! Эталон — `AirPhaseCpu.{fill, cell, faces, run_prepared}`, `AirPhase.{result, stats}` и
//! `{_start_picard, nonconv_mask}`.
//!
//! Порядок шагов (как `AirPhaseCpu.run_prepared`): подготовка → сток G ([`super::drainage`]) →
//! классификатор обоих вариантов → поля механизмов A/B/D ([`MechFields`]) → скорость слоя
//! перемешивания и баланс θ′ (F, [`super::convection`]) → центры клеток → грани MAC.
//!
//! Циклы — плоские массивы SoA, по строкам `(k, j)` rayon (`par_chunks_mut`), каждая клетка
//! считается одним потоком — результат не зависит от числа потоков (побитно); новых выделений в
//! горячем цикле нет.
//!
//! ## Что отдаётся решателю (W11 v3)
//! - `freeze` — [`Freeze`] варианта с нагревом: маска `ny·nx` + поле [`FrozenField`] = `mech_field`;
//! - `freeze_mech` — то же для решения без нагрева (`mech_field_mech`);
//! - `nonconv` — [`NonConv`] запасного пути: колонны, где вес H + D > `nonconv.mech_w` и колонна не
//!   заморожена, поле — `warm` со слоем `mech_field` (они совпадают); `None`, если таких колонн нет
//!   (эталон тогда не передаёт маску);
//! - `warm` — [`State`] для `SolveOpts.init` решения с нагревом, `warm_mech` — без нагрева.
//!
//! Канал `thd` (θ′_d) полей заморозки: у решения с нагревом `thd = Some(θ′ механизма)` — θ′ механизма
//! F диабатический целиком (W11 v11); у решения без нагрева и у `nonconv` — `None` (θ′_d = 0 /
//! `late_mean`, W11 v5).
use super::classifier::{Classified, PhaseMaps, classify_pair};
use super::config::PhaseCfg;
use super::convection::{Updraft, convection_profile, theta, uml};
use super::drainage::{Drainage, GDiag, apply, drainage};
use super::mech::{MechFields, mech_at};
use super::prepare::{K, PH_F, PH_G, PH_H, PhaseCase, Prepared, prepare};
use picard_rs::api::{Freeze, FrozenField, NonConv};
use picard_rs::state::State;
use rayon::prelude::*;

/// Статистика фаз (`AirPhase.stats`; часть полей `last_info` эталона).
#[derive(Clone, Debug)]
pub struct PhaseStats {
    /// Доли фаз по площади (порядок `PHASES`), по весам в f32.
    pub phase_frac: [f64; K],
    pub fr: f64,
    pub n_bv: f64,
    pub u_over_n: f64,
    pub w_h_case: f64,
    pub w_d_strong: f64,
    pub w_d_case: f64,
    pub full_mech: bool,
    pub u_sat: f64,
    pub u10: f64,
    pub omega: f64,
    pub b_fr: f64,
    pub b_u: f64,
    /// Доля замороженных колонн: с нагревом и без.
    pub frozen_frac: f64,
    pub frozen_frac_mech: f64,
    /// Разделяющая линия тока `H_c`, м.
    pub hc_dividing: f64,
    pub d_layers: usize,
    pub shadow_frac: f64,
    /// Разброс штиля `spread_frac·U_sat·⟨w_H⟩`, м/с.
    pub h_spread: f64,
    /// Наибольшее w* столбцов, м/с.
    pub wstar_max: f64,
    /// w*, взвешенное весом F, м/с.
    pub wstar_f: f64,
    pub zi_agl: f64,
    /// Подобие слоя перемешивания на десяти долях `z/z_i`.
    pub convection: [(f64, Updraft); 10],
    /// Числа стока G (`None` — G не включён).
    pub g: Option<GDiag>,
}

/// Итог сборки фаз, всё для одного вызова решателя.
#[derive(Clone, Debug)]
pub struct PhaseResult {
    /// Заморозка решения с нагревом: маска и поле `mech_field`.
    pub freeze: Freeze,
    /// Заморозка решения без нагрева: маска и поле `mech_field_mech`.
    pub freeze_mech: Freeze,
    /// Запасной путь по сходимости; `None` — колонн механизма H/D нет.
    pub nonconv: Option<NonConv>,
    /// Тёплый старт решения с нагревом (`SolveOpts.init`).
    pub warm: State,
    /// Тёплый старт решения без нагрева.
    pub warm_mech: State,
    pub stats: PhaseStats,
    /// Веса фаз и маски обоих вариантов (Σ = 1, f64, не округлённые до f32).
    pub maps: PhaseMaps,
    /// Карта ω (`ny·nx`, f32).
    pub omega: Vec<f32>,
    /// В сборке были нечисловые значения (заменены нулями).
    pub nan_found: bool,
}

/// Сборка фаз для случая: подготовка, сток, классификатор, механизмы, F, клетки, грани, статистика.
/// `c.g` не используется — сток считается здесь по `c.heat`.
pub fn assemble(c: &PhaseCase, cfg: &PhaseCfg) -> Result<PhaseResult, String> {
    let mut p = prepare(&PhaseCase { g: None, ..*c }, cfg)?;
    let g = drainage(&p, c.heat);
    if let Some(g) = &g {
        apply(&mut p, g);
    }
    Ok(assemble_prepared(&p, g.as_ref()))
}

/// То же по готовой подготовке; `g` — сток, внесённый в `p` через [`apply`] (`None` — G нет).
pub fn assemble_prepared(p: &Prepared, g: Option<&Drainage>) -> PhaseResult {
    assert_eq!(
        p.prm.gact,
        g.is_some(),
        "сток G внесён в подготовку через apply"
    );
    let maps = classify_pair(p);
    let mf = MechFields::new(p);
    let th = if p.heated {
        theta(p, &uml(p, &maps.heat, &mf))
    } else {
        vec![0.0; p.n2]
    };
    let (heat, bad_h) = fill_state(p, &mf, &maps.heat, &th, g, true);
    let (mech, bad_m) = fill_state(p, &mf, &maps.mech, &th, None, false);
    let n2 = p.n2;
    // веса, как их получает эталон: f32
    let wf: Vec<f32> = maps.heat.weights.iter().map(|&x| x as f32).collect();
    let stats = stats(p, &wf, &maps, g);
    let nonconv = nonconv(p, &wf, &maps.heat.freeze, &heat);
    PhaseResult {
        freeze: Freeze {
            mask: maps.heat.freeze.clone(),
            field: Some(frozen(&heat, true)),
        },
        freeze_mech: Freeze {
            mask: maps.mech.freeze.clone(),
            field: Some(frozen(&mech, false)),
        },
        nonconv,
        warm: heat,
        warm_mech: mech,
        stats,
        maps,
        omega: vec![p.omega as f32; n2],
        nan_found: bad_h || bad_m,
    }
}

/// Колонны запасного пути (`nonconv_mask`): вес H + D выше порога и колонна не заморожена.
fn nonconv(p: &Prepared, wf: &[f32], freeze: &[u8], field: &State) -> Option<NonConv> {
    let n2 = p.n2;
    let thr = p.cfg.nonconv_mech_w;
    let mask: Vec<u8> = (0..n2)
        .map(|q| {
            let hd = f64::from(wf[PH_H * n2 + q]) + f64::from(wf[super::prepare::PH_D * n2 + q]);
            u8::from(hd > thr && freeze[q] == 0)
        })
        .collect();
    mask.contains(&1).then(|| NonConv {
        mask,
        field: Some(frozen(field, false)),
    })
}

/// Поле для заморозки из состояния: `thd = Some(θ′)` для решения с нагревом (`heated`), иначе `None`.
fn frozen(s: &State, heated: bool) -> FrozenField {
    FrozenField {
        u: s.u.clone(),
        v: s.v.clone(),
        w: s.w.clone(),
        th: s.th.clone(),
        thd: heated.then(|| s.th.clone()),
    }
}

/// Сетка с ореолом `(NX, NY, NZ)`.
fn dims(p: &Prepared) -> [usize; 3] {
    let (nxh, nyh) = (p.nx + 2, p.ny + 2);
    [nxh, nyh, p.big_n / (nxh * nyh)]
}

/// Граница воздуха в столбцах с ореолом (`hc_type` с зажимом на край), `NY·NX`: клетка — воздух
/// (тип 1), если её центр не ниже неё. Настоящая земля `hc` — только для высоты над землёй.
fn halo_hc(p: &Prepared, d: [usize; 3]) -> Vec<f64> {
    let mut h = vec![0.0; d[0] * d[1]];
    h.par_chunks_mut(d[0]).enumerate().for_each(|(jh, row)| {
        let j = jh.saturating_sub(1).min(p.ny - 1);
        for (ih, o) in row.iter_mut().enumerate() {
            *o = p.cols.hc_type[j * p.nx + ih.saturating_sub(1).min(p.nx - 1)];
        }
    });
    h
}

/// Всё, что нужно клетке одного варианта: подготовка, поля механизмов, веса, θ′ слоя перемешивания,
/// сток (`Some` — в варианте действует G), признак нагрева.
#[derive(Clone, Copy)]
struct Fill<'a> {
    p: &'a Prepared,
    mf: &'a MechFields,
    w: &'a Classified,
    th: &'a [f64],
    g: Option<&'a Drainage>,
    heated: bool,
}

/// Одна клетка: смесь механизмов + анабатика (F) + θ′ (F, волны) + сток G (AP-17 `assemble`,
/// AP-18 `blend_g`) → `(u, v, w, θ′)`.
#[inline]
fn cell(f: &Fill, c: usize, zmsl: f64) -> [f64; 4] {
    let Fill {
        p,
        mf,
        w,
        th,
        g,
        heated,
    } = *f;
    let n2 = p.n2;
    let a = &p.prm;
    let col = &p.cols;
    // клетка воздуха может лежать ниже блочного среднего `hc` (срезанная клетка): над землёй ≥ 0
    let zagl = (zmsl - col.hc[c]).max(0.0);
    let m = mech_at(p, mf, c, zmsl);
    let mn = super::calm::mix(w, n2, c, &m);
    let (mut u, mut v) = (mn[0], mn[1]);
    let mut t = 0.0;
    if heated {
        // доля F среди «не G» (итоговые веса включают G)
        let wf = w.weights[PH_F * n2 + c] / (1.0 - w.weights[PH_G * n2 + c]).max(1e-12);
        // анабатика (AP-17 anabatic): u_a = (B_s·L·sin α)^(1/3) вверх по склону, слой δ у земли
        let s = col.s[c];
        let sina = s / (1.0 + s * s).sqrt();
        let bs = a.grav / a.theta0 * col.hk[c].max(0.0);
        let ua = (bs * a.slope_len * sina).powf(1.0 / 3.0);
        let dl = a.ana_dmin.max(a.ana_dfrac * col.hbl[c]);
        let pr = (-zagl / dl).exp();
        let ds = s.max(1e-9);
        u += wf * ua * col.gx[c] / ds * pr;
        v += wf * ua * col.gy[c] / ds * pr;
        if zagl < col.hbl[c] {
            t = th[c];
        }
        if zmsl >= a.hcd {
            let gw = if zmsl > col.zi[c] { a.gamw } else { 0.0 };
            t -= gw * m[3];
        }
    }
    if let Some(g) = g {
        let wg = w.weights[PH_G * n2 + c];
        let layer = g.glay[c] > 0.5;
        let (l, d) = (g.gl[c], g.gd[c]);
        let top = if layer { d } else { a.g_topl * l };
        let tm = ((zagl - top) / (a.g_memb * top.max(1.0))).clamp(0.0, 1.0);
        let member = 1.0 - tm * tm * (3.0 - 2.0 * tm);
        let (sp, thg) = if layer {
            (
                g.guc[c],
                -a.gdthc * (1.0 - zagl / d.max(1.0)).clamp(0.0, 1.0),
            )
        } else {
            let xn = zagl / l;
            (
                g.gus[c] * (-xn).exp() * xn.sin(),
                -g.gdth[c] * (-xn).exp() * xn.cos() * g.gon[c],
            )
        };
        let al = wg * member;
        u = (1.0 - al) * u + al * sp * g.gdx[c] * member;
        v = (1.0 - al) * v + al * sp * g.gdy[c] * member;
        t += wg * thg * member;
    }
    [u, v, mn[2], t]
}

/// Состояние варианта: центры клеток (`fill`), затем грани MAC (`faces`). Вариант без нагрева и
/// без стока: `heated = false`, `g = None`. Возвращает состояние и признак нечисловых значений.
fn fill_state(
    p: &Prepared,
    mf: &MechFields,
    w: &Classified,
    th: &[f64],
    g: Option<&Drainage>,
    heat_variant: bool,
) -> (State, bool) {
    let d = dims(p);
    let (nxh, nyh, nzh) = (d[0], d[1], d[2]);
    let n = nxh * nyh * nzh;
    let nyx = nxh * nyh;
    let heated = heat_variant && p.heated;
    let fl = Fill {
        p,
        mf,
        w,
        th,
        g,
        heated,
    };
    let hh = halo_hc(p, d);
    let (zbot, dz) = (p.prm.z_bot, p.prm.dz);
    let zc = |k: usize| zbot + (k as f64 - 0.5) * dz;
    // центры клеток
    let mut cu = vec![0.0; n];
    let mut cv = vec![0.0; n];
    let mut cw = vec![0.0; n];
    let mut ct = vec![0.0; n];
    let bad = cu
        .par_chunks_mut(nxh)
        .zip(cv.par_chunks_mut(nxh))
        .zip(cw.par_chunks_mut(nxh))
        .zip(ct.par_chunks_mut(nxh))
        .enumerate()
        .map(|(row, (((ru, rv), rw), rt))| {
            let (k, jh) = (row / nyh, row % nyh);
            let mut bad = false;
            if k == 0 {
                return bad;
            }
            let j = jh.saturating_sub(1).min(p.ny - 1);
            let z = zc(k);
            for ih in 0..nxh {
                let c = j * p.nx + ih.saturating_sub(1).min(p.nx - 1);
                if z < p.cols.hc_type[c] {
                    continue;
                }
                let r = cell(&fl, c, z);
                let out = [&mut ru[ih], &mut rv[ih], &mut rw[ih], &mut rt[ih]];
                for (o, x) in out.into_iter().zip(r) {
                    if x.is_finite() {
                        *o = x;
                    } else {
                        bad = true;
                    }
                }
            }
            bad
        })
        .reduce(|| false, |a, b| a || b);
    // грани MAC: u — западная, v — южная, w — нижняя, θ′ — центр; у земли 0
    let air = |k: usize, col: usize| k >= 1 && zc(k) >= hh[col];
    let mut s = State {
        case: "phase".into(),
        input: String::new(),
        it: 0,
        dims: d,
        halo: 1,
        n: [p.nx, p.ny, nzh - 2],
        u: vec![0.0; n],
        v: vec![0.0; n],
        w: vec![0.0; n],
        th: vec![0.0; n],
        thd: vec![0.0; n],
        p: vec![0.0; n],
        nu: None,
        nuh: None,
        residuals: None,
    };
    s.u.par_chunks_mut(nxh)
        .zip(s.v.par_chunks_mut(nxh))
        .zip(s.w.par_chunks_mut(nxh))
        .zip(s.th.par_chunks_mut(nxh))
        .enumerate()
        .for_each(|(row, (((ru, rv), rw), rt))| {
            let (k, jh) = (row / nyh, row % nyh);
            for ih in 0..nxh {
                let col = jh * nxh + ih;
                if !air(k, col) {
                    continue;
                }
                let idx = row * nxh + ih;
                let mut fu = cu[idx];
                if ih > 0 {
                    fu = if air(k, col - 1) {
                        0.5 * (cu[idx - 1] + cu[idx])
                    } else {
                        0.0
                    };
                }
                let mut fv = cv[idx];
                if jh > 0 {
                    fv = if air(k, col - nxh) {
                        0.5 * (cv[idx - nxh] + cv[idx])
                    } else {
                        0.0
                    };
                }
                let mut fw = 0.0;
                if k > 0 && air(k - 1, col) {
                    fw = 0.5 * (cw[idx - nyx] + cw[idx]);
                }
                ru[ih] = fu as f32;
                rv[ih] = fv as f32;
                rw[ih] = fw as f32;
                rt[ih] = ct[idx] as f32;
            }
        });
    (s, bad)
}

/// Статистика (`AirPhase.stats`): `wf` — веса варианта с нагревом в f32 (`K·n²`).
fn stats(p: &Prepared, wf: &[f32], maps: &PhaseMaps, g: Option<&Drainage>) -> PhaseStats {
    let n2 = p.n2;
    let mut frac = [0.0; K];
    for (k, f) in frac.iter_mut().enumerate() {
        let mut s = 0.0;
        for c in 0..n2 {
            s += f64::from(wf[k * n2 + c]);
        }
        *f = s / n2 as f64;
    }
    let fz = |m: &[u8]| {
        let mut s = 0.0;
        for &b in m {
            s += f64::from(b) / n2 as f64;
        }
        s
    };
    let (mut wmax, mut wf_sum, mut wf_w) = (0.0f64, 0.0, 0.0);
    for c in 0..n2 {
        let ws = p.cols.wst[c];
        wmax = wmax.max(ws);
        let f = f64::from(wf[PH_F * n2 + c]);
        wf_sum += ws * f;
        wf_w += f;
    }
    PhaseStats {
        phase_frac: frac,
        fr: p.fr,
        n_bv: p.n_bv,
        u_over_n: p.u_over_n,
        w_h_case: p.w_h,
        w_d_strong: p.w_ds,
        w_d_case: p.w_d,
        full_mech: p.full,
        u_sat: p.usat,
        u10: p.u10,
        omega: p.omega,
        b_fr: p.b_fr,
        b_u: p.b_u,
        frozen_frac: fz(&maps.heat.freeze),
        frozen_frac_mech: fz(&maps.mech.freeze),
        hc_dividing: p.hcd,
        d_layers: p.zl.len(),
        shadow_frac: p.shadow_frac,
        h_spread: p.cfg.h_spread_frac * p.usat * frac[PH_H],
        wstar_max: wmax,
        wstar_f: if wf_w > 0.0 { wf_sum / wf_w } else { 0.0 },
        zi_agl: p.zi_agl,
        convection: convection_profile(&p.cfg),
        g: g.map(|d| d.diag),
    }
}
