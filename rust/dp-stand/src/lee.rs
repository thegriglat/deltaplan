//! Подкоманда `lee` (контракт LTS v1, `docs/contracts/lee-turb.md`): разрез болтанки поля за гребнем.
//!
//! Модель `Formula` готовится как у остальных подкоманд; поле берётся из `field_export` (весь
//! поданный набор уровней, `parse_solved` + `FieldSet::prepare` с ограничителями по умолчанию, они
//! равны конфигу), слагаемые — из `terms_snapshot`. Величины болтанки считает сам `dp_air::terms::turb`
//! (слот `Turb`, `FieldTurb::state`, `sigma::sigma`); поведение модели стенд не меняет.
//!
//! Что берётся откуда:
//! - `u_par, u_perp, w` — `AirModel::sample_many` в режиме MEAN (полная модель: поле + аналитика + термики…);
//! - `lee_f, du, u_h, shear` — `FieldState` (shear = канал `T_SHEAR` поля в точке);
//! - `sigma_u/v/w` — `TurbOut` слота `Turb` (то, что слот отдаёт до слияния с термиком и грозой);
//! - `l_u, l_w` — как их получает спектр: `max(L·taylor_stretch, l_sep)`;
//! - `src` — `mix`, если `sep_σ_w` (после вычета рывков) выбран вместо σ поля; иначе `mech`/`conv` —
//!   что больше в σ_w поля (σ_w механики считается вторым вызовом `sigma` без w*, конвективная — остаток
//!   по σ³-сложению).
use dp_air::field::field_set::FieldSet;
use dp_air::field::runtime::ground_height;
use dp_air::field::solved::parse_solved;
use dp_air::field::wind_field::{Limits, T_AOUT, T_SHEAR, T_UOUT, T_WSTAR};
use dp_air::terms::turb::FieldTurb;
use dp_air::terms::turb::sigma::{sigma, taylor_stretch};
use dp_air::terms::{Ctx, Mid, Terms};
use dp_air::{AirModel, Formula, Place, SampleMode};
use rayon::prelude::*;
use std::fmt::Write as _;

pub const COLUMNS: &str =
    "s,x,y,z,agl,u_par,u_perp,w,lee_f,du,u_h,shear,sigma_u,sigma_v,sigma_w,l_u,l_w,src";

/// Разрез: линия `from → to` (x, z игры) с шагом `step` × высоты MSL `y0..y1` с шагом `dy`.
#[derive(Clone, Copy, Debug)]
pub struct LeeSpec {
    pub from: [f32; 2],
    pub to: [f32; 2],
    pub ys: [f32; 2],
    pub step: f32,
    pub dy: f32,
}

impl LeeSpec {
    pub fn validate(&self) -> Result<(), String> {
        if !(self.step > 0.0 && self.dy > 0.0) {
            return Err("--step and --dy must be > 0".into());
        }
        if self.ys[1] < self.ys[0] {
            return Err("--ys: y1 < y0".into());
        }
        let all = self.from.iter().chain(&self.to).chain(&self.ys);
        if !all.clone().all(|v| v.is_finite()) {
            return Err("non-finite coordinate".into());
        }
        let (n, m) = self.size();
        if n.saturating_mul(m) > 20_000_000 {
            return Err(format!("too many points: {n}x{m}"));
        }
        Ok(())
    }

    pub fn length(&self) -> f32 {
        let (dx, dz) = (self.to[0] - self.from[0], self.to[1] - self.from[1]);
        (dx * dx + dz * dz).sqrt()
    }

    /// Единичное направление линии (x, z).
    pub fn dir(&self) -> [f32; 2] {
        let l = self.length();
        if l > 0.0 {
            [
                (self.to[0] - self.from[0]) / l,
                (self.to[1] - self.from[1]) / l,
            ]
        } else {
            [1.0, 0.0]
        }
    }

    /// (число точек вдоль линии, число высот).
    pub fn size(&self) -> (usize, usize) {
        let n = (self.length() / self.step + 1.0e-4).floor() as usize + 1;
        let m = ((self.ys[1] - self.ys[0]) / self.dy + 1.0e-4).floor() as usize + 1;
        (n, m)
    }

    /// Точки сетки: `(s, [x, y, z])`, порядок — по `s`, затем по высоте.
    pub fn points(&self) -> Vec<(f32, [f32; 3])> {
        let (n, m) = self.size();
        let d = self.dir();
        let mut v = Vec::with_capacity(n * m);
        for i in 0..n {
            let s = i as f32 * self.step;
            let (x, z) = (self.from[0] + d[0] * s, self.from[1] + d[1] * s);
            for j in 0..m {
                v.push((s, [x, self.ys[0] + j as f32 * self.dy, z]));
            }
        }
        v
    }
}

/// Строка разреза; величины поля пусты вне поля (`src = none`).
#[derive(Clone, Copy, Debug, Default)]
pub struct Row {
    pub s: f32,
    pub p: [f32; 3],
    pub agl: f32,
    pub u_par: f32,
    pub u_perp: f32,
    pub w: f32,
    pub field: Option<FieldCols>,
}

#[derive(Clone, Copy, Debug)]
pub struct FieldCols {
    pub lee_f: f64,
    pub du: f64,
    pub u_h: f64,
    pub shear: f64,
    pub sigma: [f64; 3],
    pub l_u: f64,
    pub l_w: f64,
    pub src: &'static str,
    /// Диагностика вне контракта LTS (`--extra`): превышение гребня `relief` аналитики, её признак
    /// отрыва `lee_a`, опасность, доля поля, uf, `h` аналитики, `dh` обратного потока, `u_out`, `a_out`.
    pub extra: [f64; 9],
}

impl Row {
    pub fn write_csv(&self, out: &mut String) {
        let _ = write!(
            out,
            "{},{},{},{},{:.2},{:.3},{:.3},{:.3}",
            self.s, self.p[0], self.p[1], self.p[2], self.agl, self.u_par, self.u_perp, self.w
        );
        match &self.field {
            Some(f) => {
                let _ = writeln!(
                    out,
                    ",{:.4},{:.3},{:.3},{:.4},{:.3},{:.3},{:.3},{:.2},{:.2},{}",
                    f.lee_f,
                    f.du,
                    f.u_h,
                    f.shear,
                    f.sigma[0],
                    f.sigma[1],
                    f.sigma[2],
                    f.l_u,
                    f.l_w,
                    f.src
                );
            }
            None => {
                let _ = writeln!(out, ",,,,,,,,,,none");
            }
        }
    }
}

/// Всё, что нужно для разреза, из готовой модели.
pub struct LeeCtx {
    pub fs: FieldSet,
    pub terms: std::sync::Arc<Terms>,
    pub turb: FieldTurb,
    pub t: f64,
}

impl LeeCtx {
    /// `f` — модель в состоянии Ready на момент `t`; `cfg_seed` — конфиги и сид случая (тот же
    /// `FieldTurb`, что в слоте: шум и таблицы по сиду, в MEAN он не участвует).
    pub fn new(f: &Formula, configs: &dp_air::Configs, seed: u64, t: f64) -> Result<Self, String> {
        let ex = f.field_export();
        if ex.version == 0 {
            return Err("model has no field (field_export.version = 0)".into());
        }
        let sf = parse_solved(&ex.header_json, &ex.data).map_err(|e| e.to_string())?;
        let lim = Limits::default();
        let lv = FieldSet::prepare(sf.levels, lim, 5.0);
        let mut fs = FieldSet::new(lim, 5.0);
        fs.set_levels(lv, 0.0);
        if fs.levels().len() != f.level_count() {
            return Err(format!(
                "field export has {} levels, model has {}",
                fs.levels().len(),
                f.level_count()
            ));
        }
        Ok(LeeCtx {
            fs,
            terms: f.terms_snapshot(),
            turb: FieldTurb::new(configs, seed),
            t,
        })
    }

    /// Уровни поля: dx, размер сетки и границы по x, z (мир) — для stderr и анализа.
    pub fn level_info(&self) -> Vec<String> {
        self.fs
            .levels()
            .iter()
            .map(|l| {
                let g = l.grid();
                format!(
                    "dx={} nx={} nz={} x=[{}, {}] z=[{}, {}]",
                    g.dx,
                    g.nx,
                    g.ny,
                    g.x0,
                    g.x0 + g.nx as f64 * g.dx,
                    -(g.y0 + g.ny as f64 * g.dx),
                    -g.y0
                )
            })
            .collect()
    }

    /// Строка в точке `p` (без среднего ветра — его ставит `run`).
    pub fn field_at(&self, place: &Place, p: [f32; 3]) -> (f32, Option<FieldCols>) {
        let g = ground_height(place, p[0], p[2]);
        let agl = f64::from((p[1] - g).max(0.0));
        let vel = self.fs.sample(p, g);
        let (fw, a) = (vel.v, vel.share);
        if a <= 0.0 {
            return (agl as f32, None);
        }
        let terms: &Terms = &self.terms;
        let c = Ctx {
            pos: p,
            ground: g,
            agl,
            t: self.t,
            mode: SampleMode::Mean,
            a,
            fw,
            u: terms.wind.speed_at_pos(agl, f64::from(p[1])),
            terms,
            fs: &self.fs,
            place,
        };
        let s = &terms.slots;
        let am = s.analytic.mean(&c);
        let tm = s.turb.mean(&c, am.as_ref());
        let st = self.turb.state(&c, am.as_ref());
        let wd = terms.wind.dir();
        let h = am.map_or(0.0, |m| m.h) + tm.map_or(0.0, |m| m.dh);
        let v = [fw[0] + wd[0] * h, fw[1], fw[2] + wd[1] * h];
        let mid = Mid {
            v,
            analytic: am,
            turb: tm,
            thermal: None,
            extra: None,
        };
        let Some(out) = s.turb.sigma(&c, &mid) else {
            return (agl as f32, None);
        };
        let cfg = self.turb.cfg();
        let z0 = self.fs.levels().first().map_or(0.1, |l| l.z0());
        // масштабы: как их получает спектр (mod.rs `turb_out`)
        let sg = sigma(cfg, z0, agl, &st.tb, [0.0, 0.0], st.uf, st.w_sep);
        let ml = (v[0] * v[0] + v[2] * v[2]).sqrt();
        let stretch = taylor_stretch(terms.wind.speed_at(cfg.advection_height), ml, agl);
        let l_sep = cfg.sep_scale * st.relief.max(0.0) * st.lee_f;
        let l_u = (sg.l_u * stretch).max(l_sep);
        let l_w = (sg.l_w * stretch).max(l_sep);
        // ветвь σ_w
        let mut tb_m = st.tb;
        tb_m[T_WSTAR] = 0.0;
        let sw_m = sigma(cfg, z0, agl, &tb_m, [0.0, 0.0], st.uf, st.w_sep).s_w;
        let src = if out.sep[1] > 0.0 && out.s_w <= out.sep[1] {
            "mix"
        } else if out.s_w.powi(3) - sw_m.powi(3) > sw_m.powi(3) {
            "conv"
        } else {
            "mech"
        };
        (
            agl as f32,
            Some(FieldCols {
                lee_f: st.lee_f,
                du: st.du,
                u_h: st.u_h,
                shear: f64::from(st.tb[T_SHEAR]),
                sigma: [out.s_u, out.s_v, out.s_w],
                l_u,
                l_w,
                src,
                extra: [
                    st.relief,
                    am.map_or(0.0, |m| m.lee),
                    st.danger,
                    a,
                    st.uf,
                    am.map_or(0.0, |m| m.h),
                    tm.map_or(0.0, |m| m.dh),
                    f64::from(st.tb[T_UOUT]),
                    f64::from(st.tb[T_AOUT]),
                ],
            }),
        )
    }
}

/// Разрез целиком: точки под рельефом пропускаются.
pub fn run(f: &Formula, lc: &LeeCtx, place: &Place, spec: &LeeSpec) -> Vec<Row> {
    let pts: Vec<(f32, [f32; 3])> = spec
        .points()
        .into_iter()
        .filter(|(_, p)| p[1] >= ground_height(place, p[0], p[2]))
        .collect();
    let xyz: Vec<[f32; 3]> = pts.iter().map(|(_, p)| *p).collect();
    let mut mean = vec![[0.0f32; 4]; xyz.len()];
    f.sample_many(&xyz, SampleMode::Mean, &mut mean);
    let d = spec.dir();
    pts.par_iter()
        .zip(mean.par_iter())
        .map(|((s, p), v)| {
            let (agl, field) = lc.field_at(place, *p);
            Row {
                s: *s,
                p: *p,
                agl,
                u_par: v[0] * d[0] + v[2] * d[1],
                u_perp: v[0] * d[1] - v[2] * d[0],
                w: v[1],
                field,
            }
        })
        .collect()
}

pub const EXTRA_COLUMNS: &str = "s,y,agl,relief,lee_a,danger,share,uf,h_an,dh,u_out,a_out";

/// Диагностика в csv (вне контракта): те же точки, что у разреза, только внутри поля.
pub fn render_extra(rows: &[Row]) -> String {
    let mut out = String::new();
    out.push_str(EXTRA_COLUMNS);
    out.push('\n');
    for r in rows {
        if let Some(f) = &r.field {
            let e = &f.extra;
            let _ = writeln!(
                out,
                "{},{},{:.2},{:.2},{:.4},{:.4},{:.4},{:.3},{:.3},{:.3},{:.3},{:.1}",
                r.s, r.p[1], r.agl, e[0], e[1], e[2], e[3], e[4], e[5], e[6], e[7], e[8]
            );
        }
    }
    out
}

pub fn render(header: &str, rows: &[Row]) -> String {
    let mut out = String::with_capacity(rows.len() * 120 + 200);
    out.push_str(header);
    out.push('\n');
    out.push_str(COLUMNS);
    out.push('\n');
    for r in rows {
        r.write_csv(&mut out);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn grid_and_rows() {
        let sp = LeeSpec {
            from: [0.0, 0.0],
            to: [0.0, 30.0],
            ys: [100.0, 120.0],
            step: 10.0,
            dy: 10.0,
        };
        sp.validate().unwrap();
        assert_eq!(sp.size(), (4, 3));
        let p = sp.points();
        assert_eq!(p.len(), 12);
        assert_eq!(p[3], (10.0, [0.0, 100.0, 10.0]));
    }

    #[test]
    fn none_row_has_empty_field_cells() {
        let r = Row {
            s: 1.0,
            p: [2.0, 3.0, 4.0],
            agl: 5.0,
            ..Row::default()
        };
        let mut s = String::new();
        r.write_csv(&mut s);
        assert_eq!(s.matches(',').count(), COLUMNS.matches(',').count());
        assert!(s.trim_end().ends_with(",none"));
    }

    #[test]
    fn bad_spec() {
        let mut sp = LeeSpec {
            from: [0.0, 0.0],
            to: [10.0, 0.0],
            ys: [5.0, 1.0],
            step: 1.0,
            dy: 1.0,
        };
        assert!(sp.validate().is_err());
        sp.ys = [1.0, 5.0];
        sp.step = 0.0;
        assert!(sp.validate().is_err());
    }
}
