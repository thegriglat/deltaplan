//! Сверка модели с фикстурой W8 по допускам T1 (раннер для RW-6…12).
use crate::ops::sample_slice;
use crate::setup::Session;
use dp_air::fixtures::{Frame, read_case_data, read_desc};
use dp_air::{Cloud, Core, SampleMode};
use std::fmt::Write;

/// Допуск `|Δ| ≤ abs + rel·|ref|`.
#[derive(Clone, Copy, Debug)]
pub struct Tol {
    pub abs: f32,
    pub rel: f32,
}

impl Tol {
    fn of(&self, r: f32) -> f32 {
        self.abs + self.rel * r.abs()
    }
}

/// Допуски T1 — `docs/contracts/rust-wind/fixtures-tolerances.md` (W8 v1), одной таблицей.
pub mod tol {
    use super::Tol;
    /// MEAN, детерминированные слагаемые и FULL (при воспроизведённом шуме), по компоненте.
    pub const MEAN_V: Tol = Tol {
        abs: 0.05,
        rel: 0.02,
    };
    /// Слагаемое поля Пикара в точке.
    pub const FIELD_V: Tol = Tol {
        abs: 0.1,
        rel: 0.03,
    };
    pub const SIGMA: Tol = Tol {
        abs: 0.02,
        rel: 0.05,
    };
    /// Ядра: место `max(25 м, 2 % radius)`; w, radius — 3 %; top — 10 м; stage — 0,05.
    pub const CORE_PLACE_MIN: f32 = 25.0;
    pub const CORE_PLACE_REL: f32 = 0.02;
    pub const CORE_W_REL: f32 = 0.03;
    pub const CORE_RADIUS_REL: f32 = 0.03;
    pub const CORE_TOP: f32 = 10.0;
    pub const CORE_STAGE: f32 = 0.05;
    /// Облака: центр 50 м; база/верх 10 м; growth/decay 0,05.
    pub const CLOUD_CENTER: f32 = 50.0;
    pub const CLOUD_Z: f32 = 10.0;
    pub const CLOUD_GD: f32 = 0.05;
    /// База облаков, м.
    pub const CLOUDBASE: f32 = 5.0;
}

/// Накопитель по одной величине.
#[derive(Clone, Debug, Default)]
pub struct Row {
    pub name: String,
    pub n: usize,
    pub out: usize,
    pub max_abs: f32,
    /// max |Δ| / допуск; > 1 — вне допуска
    pub max_ratio: f32,
}

impl Row {
    fn new(name: &str) -> Self {
        Row {
            name: name.into(),
            ..Default::default()
        }
    }

    /// Добавляет сравнение; возвращает true, если вне допуска (NaN — вне).
    fn add(&mut self, delta: f32, tol: f32) -> bool {
        self.n += 1;
        let out = delta.is_nan() || delta > tol;
        if out {
            self.out += 1;
        }
        if delta.is_nan() {
            self.max_abs = f32::NAN;
            self.max_ratio = f32::INFINITY;
        } else if !self.max_abs.is_nan() {
            self.max_abs = self.max_abs.max(delta);
            self.max_ratio = self
                .max_ratio
                .max(if tol > 0.0 { delta / tol } else { 0.0 });
        }
        out
    }
}

#[derive(Clone, Debug)]
pub struct Violation {
    pub t: usize,
    pub point: usize,
    pub tag: String,
    pub what: String,
    pub delta: f32,
    pub tol: f32,
}

#[derive(Clone, Debug, Default)]
pub struct Report {
    pub rows: Vec<Row>,
    pub violations: Vec<Violation>,
    /// число точек (момент, точка), где хоть одна величина вне допуска
    pub points_out: usize,
    pub notes: Vec<String>,
}

pub struct Options {
    pub terms: bool,
    pub noise_replaced: bool,
}

impl Report {
    fn row(&mut self, name: &str) -> usize {
        if let Some(i) = self.rows.iter().position(|r| r.name == name) {
            return i;
        }
        self.rows.push(Row::new(name));
        self.rows.len() - 1
    }

    pub fn total_out(&self) -> usize {
        self.rows.iter().map(|r| r.out).sum()
    }

    pub fn passed(&self) -> bool {
        self.total_out() == 0
    }

    pub fn render(&self, max_viol: usize) -> String {
        let mut s = String::new();
        let _ = writeln!(
            s,
            "{:<22} {:>8} {:>8} {:>12} {:>10}",
            "quantity", "n", "out", "max|d|", "max d/tol"
        );
        for r in &self.rows {
            let _ = writeln!(
                s,
                "{:<22} {:>8} {:>8} {:>12.5} {:>10.3}",
                r.name, r.n, r.out, r.max_abs, r.max_ratio
            );
        }
        for n in &self.notes {
            let _ = writeln!(s, "note: {n}");
        }
        let _ = writeln!(s, "points out of tolerance: {}", self.points_out);
        for v in self.violations.iter().take(max_viol) {
            let _ = writeln!(
                s,
                "  t#{} point#{} [{}] {}: d={:.5} tol={:.5}",
                v.t, v.point, v.tag, v.what, v.delta, v.tol
            );
        }
        if self.violations.len() > max_viol {
            let _ = writeln!(s, "  ... {} more", self.violations.len() - max_viol);
        }
        let _ = writeln!(s, "{}", if self.passed() { "PASS" } else { "FAIL" });
        s
    }
}

/// Сверка скоростей и σ одного набора; `name` — префикс строк. Возвращает true, если точка вне допуска.
#[allow(clippy::too_many_arguments)]
fn compare_vel(
    rep: &mut Report,
    name: &str,
    vt: Tol,
    t: usize,
    p: usize,
    tag: &str,
    got: [f32; 4],
    want: [f32; 4],
) -> bool {
    let (d_sigma, ts) = ((got[3] - want[3]).abs(), tol::SIGMA.of(want[3]));
    let mut out = false;
    let vi = rep.row(&format!("{name}.v"));
    for k in 0..3 {
        let d = (got[k] - want[k]).abs();
        let tl = vt.of(want[k]);
        let o = rep.rows[vi].add(d, tl);
        if o {
            out = true;
            rep.violations.push(Violation {
                t,
                point: p,
                tag: tag.into(),
                what: format!("{name}.v{}", ["x", "y", "z"][k]),
                delta: d,
                tol: tl,
            });
        }
    }
    let si = rep.row(&format!("{name}.sigma"));
    if rep.rows[si].add(d_sigma, ts) {
        out = true;
        rep.violations.push(Violation {
            t,
            point: p,
            tag: tag.into(),
            what: format!("{name}.sigma"),
            delta: d_sigma,
            tol: ts,
        });
    }
    out
}

fn dist2(ax: f32, az: f32, bx: f32, bz: f32) -> f32 {
    (ax - bx).hypot(az - bz)
}

fn compare_cores(rep: &mut Report, t: usize, got: &[Core], want: &[Core]) {
    let ci = rep.row("cores.count");
    let o = rep.rows[ci].add((got.len() as f32 - want.len() as f32).abs(), 0.0);
    if o {
        rep.violations.push(Violation {
            t,
            point: 0,
            tag: "cores".into(),
            what: format!("cores.count got {} want {}", got.len(), want.len()),
            delta: (got.len() as f32 - want.len() as f32).abs(),
            tol: 0.0,
        });
        return;
    }
    for w in want {
        let g = got
            .iter()
            .find(|g| g.id == w.id)
            .or_else(|| {
                got.iter()
                    .min_by(|a, b| dist2(a.x, a.z, w.x, w.z).total_cmp(&dist2(b.x, b.z, w.x, w.z)))
            })
            .expect("counts equal and non-empty");
        let checks = [
            (
                "cores.place",
                dist2(g.x, g.z, w.x, w.z),
                tol::CORE_PLACE_MIN.max(tol::CORE_PLACE_REL * w.radius),
            ),
            ("cores.w", (g.w - w.w).abs(), tol::CORE_W_REL * w.w.abs()),
            (
                "cores.radius",
                (g.radius - w.radius).abs(),
                tol::CORE_RADIUS_REL * w.radius.abs(),
            ),
            ("cores.top", (g.top - w.top).abs(), tol::CORE_TOP),
            ("cores.stage", (g.stage - w.stage).abs(), tol::CORE_STAGE),
        ];
        for (n, d, tl) in checks {
            let i = rep.row(n);
            if rep.rows[i].add(d, tl) {
                rep.violations.push(Violation {
                    t,
                    point: w.id as usize,
                    tag: "cores".into(),
                    what: format!("{n} (core id {})", w.id),
                    delta: d,
                    tol: tl,
                });
            }
        }
    }
}

fn compare_clouds(rep: &mut Report, t: usize, got: &[Cloud], want: &[Cloud]) {
    let ci = rep.row("clouds.count");
    let dc = (got.len() as f32 - want.len() as f32).abs();
    if rep.rows[ci].add(dc, 0.0) {
        rep.violations.push(Violation {
            t,
            point: 0,
            tag: "clouds".into(),
            what: format!("clouds.count got {} want {}", got.len(), want.len()),
            delta: dc,
            tol: 0.0,
        });
        return;
    }
    for w in want {
        let g = got
            .iter()
            .find(|g| g.id == w.id)
            .or_else(|| {
                got.iter()
                    .min_by(|a, b| dist2(a.x, a.z, w.x, w.z).total_cmp(&dist2(b.x, b.z, w.x, w.z)))
            })
            .expect("counts equal and non-empty");
        let checks = [
            (
                "clouds.center",
                dist2(g.x, g.z, w.x, w.z),
                tol::CLOUD_CENTER,
            ),
            ("clouds.base", (g.base_msl - w.base_msl).abs(), tol::CLOUD_Z),
            ("clouds.top", (g.top_msl - w.top_msl).abs(), tol::CLOUD_Z),
            ("clouds.growth", (g.growth - w.growth).abs(), tol::CLOUD_GD),
            ("clouds.decay", (g.decay - w.decay).abs(), tol::CLOUD_GD),
        ];
        for (n, d, tl) in checks {
            let i = rep.row(n);
            if rep.rows[i].add(d, tl) {
                rep.violations.push(Violation {
                    t,
                    point: w.id as usize,
                    tag: "clouds".into(),
                    what: format!("{n} (cloud id {})", w.id),
                    delta: d,
                    tol: tl,
                });
            }
        }
    }
}

fn compare_frame(rep: &mut Report, sess: &Session, t: usize, fr: &Frame) {
    let mut cores = Vec::new();
    sess.model.cores([0.0; 3], 1.0e9, &mut cores);
    compare_cores(rep, t, &cores, &fr.cores);
    let mut clouds = Vec::new();
    sess.model.clouds([0.0; 3], 1.0e9, &mut clouds);
    compare_clouds(rep, t, &clouds, &fr.clouds);
    let bi = rep.row("cloudbase");
    let d = (sess.model.cloudbase_msl() - fr.cloudbase_msl).abs();
    if rep.rows[bi].add(d, tol::CLOUDBASE) {
        rep.violations.push(Violation {
            t,
            point: 0,
            tag: "cloudbase".into(),
            what: "cloudbase".into(),
            delta: d,
            tol: tol::CLOUDBASE,
        });
    }
    // Гребни в таблице допусков W8 не заданы: сверяется только число.
    let mut crests = Vec::new();
    sess.model
        .wave_crests([0.0; 2], 1.0e9, 0.0, 0.0, &mut crests);
    let ri = rep.row("crests.count");
    let dc = (crests.len() as f32 - fr.crests.len() as f32).abs();
    if rep.rows[ri].add(dc, 0.0) {
        rep.violations.push(Violation {
            t,
            point: 0,
            tag: "crests".into(),
            what: format!("crests.count got {} want {}", crests.len(), fr.crests.len()),
            delta: dc,
            tol: 0.0,
        });
    }
}

pub fn run(sess: &mut Session, opt: &Options) -> Result<Report, String> {
    let case = sess.case.clone();
    let data = read_case_data(&case, &sess.case_path).map_err(|e| e.to_string())?;
    let desc = read_desc(&case, &sess.case_path).map_err(|e| e.to_string())?;
    let mut rep = Report::default();
    let np = case.points.len();
    let mut got = vec![[0.0f32; 4]; np];
    let mut bad = vec![false; np];
    if opt.noise_replaced {
        rep.notes
            .push("FULL skipped (--noise-replaced): T3 and MEAN only".into());
    }
    if opt.terms && case.terms.is_none() {
        rep.notes.push("case has no terms: --terms ignored".into());
    }
    for (ti, &t) in case.times_s.iter().enumerate() {
        sess.go_to(t)?;
        bad.iter_mut().for_each(|b| *b = false);
        let mut modes = vec![(SampleMode::Mean, 1usize, "mean")];
        if !opt.noise_replaced {
            modes.push((SampleMode::Full, 0, "full"));
        }
        for (mode, k, name) in modes {
            sample_slice(sess.model.as_ref(), &case.points, mode, &mut got);
            for (p, (g, w)) in got.iter().zip(data.slab(ti, k)).enumerate() {
                if compare_vel(
                    &mut rep,
                    name,
                    tol::MEAN_V,
                    ti,
                    p,
                    &case.point_tags[p],
                    *g,
                    w,
                ) {
                    bad[p] = true;
                }
            }
        }
        if let (true, Some(terms)) = (opt.terms, case.terms.as_ref()) {
            let decs: Vec<_> = case
                .points
                .iter()
                .map(|&p| sess.model.decompose(p))
                .collect();
            for (ki, term) in terms.iter().enumerate() {
                let vt = if term == "field" {
                    tol::FIELD_V
                } else {
                    tol::MEAN_V
                };
                let name = format!("term.{term}");
                for (p, want) in data.slab(ti, 2 + ki).enumerate() {
                    let d = &decs[p];
                    match d.names.iter().position(|n| n == term) {
                        None => {
                            let i = rep.row(&format!("{name}.v"));
                            rep.rows[i].add(f32::NAN, 0.0);
                            rep.violations.push(Violation {
                                t: ti,
                                point: p,
                                tag: case.point_tags[p].clone(),
                                what: format!("{name}: missing in decomposition"),
                                delta: f32::NAN,
                                tol: 0.0,
                            });
                            bad[p] = true;
                        }
                        Some(j) => {
                            let v = d.vel[j];
                            let g = [v[0], v[1], v[2], d.sigma[j]];
                            if compare_vel(&mut rep, &name, vt, ti, p, &case.point_tags[p], g, want)
                            {
                                bad[p] = true;
                            }
                        }
                    }
                }
            }
        }
        rep.points_out += bad.iter().filter(|&&b| b).count();
        compare_frame(&mut rep, sess, ti, &desc[ti]);
    }
    Ok(rep)
}
