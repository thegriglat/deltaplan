//! Клипмап окон 100/50 м в крейте (RW-6o): перенос `AirClipmap` (`air_clipmap.gd`) и окон
//! `AirRuntime` (`air_runtime.gd`: `_start_windows`, `_update_windows`, `_on_windows_failed`).
//! Решение каждого окна — `window.rs` (RW-6n: граница от родителя, поправка потока, тёплый
//! сдвиг) и `picard_rs::api::solve` (`Case.nest`, `init_cycles`, W11 v7).
//!
//! ## Что делает
//! - **Загрузка**: область, затем окна `air_model.window_levels_m` (по умолчанию 100 и 50 м, от
//!   грубого к мелкому) с центром на старте (первый фокус): угол кратен 25 м; родитель окна 100 м
//!   — область, каждого следующего — предыдущее окно (его новое решение); подача одним набором
//!   `[50, 100, область]`. Пара mech → heat на каждое окно, у каждого решения — своя граница от
//!   своего родителя ([`super::window::window_pair_inputs`]), старт «родитель» (30 V-циклов).
//! - **Пересчёт по сроку**: область, затем окна на прежних местах с тёплого старта от своих
//!   прошлых решений (4 V-цикла, сдвиг 0).
//! - **Сдвиг в покое**: когда фокус ушёл от центра окна дальше `window_shift_frac` стороны (по x
//!   или y), окно и все мельче пересчитываются с центром у фокуса, угол — прежний плюс целое число
//!   клеток окна ([`ClipMap::plan_shift`]); тёплый старт — прошлое окно со сдвигом. Родитель
//!   сдвигаемого окна — прежнее решение окна крупнее (или область). Сдвиг 100 м тянет и 50 м.
//! - **Откат**: ошибка окна (нет рельефа под окном, не сошлось, таймаут, подставной отказ) — подаётся
//!   поле без окон (только область); причина — в `Status.reason`; `ClipMap` без окон
//!   ([`ClipMap::unplaced`]) помнит область и места, следующий сдвиг пробует снова.
//! - `window_levels_m = []` — клипмапа нет.
//!
//! ## Данные
//! [`ParentArea`] — уровень, типы клеток и пара состояний области (родитель окна 100 м) и поля
//! `z_i` для столбцов окна; [`WinLevel`] — то же для окна и его готовое поле. [`ClipMap`] —
//! неизменяемый снимок (окна, область, условия, по которым посчитано): `Arc` делят `Formula` и
//! задачи, сдвиг не копирует массивы уровней, которые не менялись.
//!
//! ## Границы модели
//! - Входы окон (рельеф, погода, поток тепла, `z_i` от области) готовятся параллельно на пуле;
//!   решения идут по очереди сверху вниз (родитель нужен готовый).
//! - Условия окон — те же, что у области этого поля (`ClipMap.cond/rec/k`), и при сдвиге; час —
//!   начало срока поля.
//! - Окна не гасят нагрев у края (`taper = false`), решения окон — без запасных правил `ω` и
//!   фаз (как в игре: `AirWindowJob` их не получает).
//! - Фокус — первый; несколько фокусов клипмап не ведёт (игра: один пилот).
use super::case_prepare::CaseOpts;
use super::field_set::FieldSet;
use super::runtime::{
    CondRec, JobErr, JobIn, JobOut, JobReport, Pair, Source, Spec, build_field, check_cancel,
    solve_with, weather_for,
};
use super::weather_core::{Domain, FieldWeather};
use super::wind_field::Field;
use super::window::{
    AirWindowCase, N_WINDOW, PairInputs, ParentPair, ParentZi, PrevPair, WindowState,
    build_window_input, window_domain, window_pair_inputs,
};
use crate::Conditions;
use crate::level::{Level, NestSrc, ShiftSrc};
use picard_rs::api::StopReason;
use picard_rs::state::State;
use rayon::prelude::*;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Instant;

/// V-циклов старта окна от родителя (`air_picard:init`).
const INIT_CYCLES: u32 = 30;

// ---------------------------------------------------------------------------------------------
// данные
// ---------------------------------------------------------------------------------------------

/// `z_i` области для столбцов окна (`ParentZi` без заимствований).
#[derive(Clone, Debug)]
pub struct ZiArea {
    pub nx: usize,
    pub ny: usize,
    pub dx: f64,
    pub x0: f64,
    pub y0: f64,
    pub z_i: f64,
    pub z_i_col: Vec<f32>,
    pub alpha_on: bool,
}

impl ZiArea {
    fn parent(&self) -> ParentZi<'_> {
        ParentZi {
            nx: self.nx,
            ny: self.ny,
            dx: self.dx,
            x0: self.x0,
            y0: self.y0,
            z_i: self.z_i,
            z_i_col: &self.z_i_col,
            alpha_on: self.alpha_on,
        }
    }
}

/// Область как родитель окна (`AirPicardJob.parent_data()`): уровень, типы клеток, решения
/// без нагрева и с нагревом.
#[derive(Clone, Debug)]
pub struct ParentArea {
    pub level: Level,
    pub tc: Vec<u8>,
    pub pair: Arc<Pair>,
    pub zi: ZiArea,
}

/// Посчитанное окно: положение, уровень сетки, типы клеток, решения пары и готовое поле.
#[derive(Clone, Debug)]
pub struct WinLevel {
    pub dx: f64,
    /// Юго-западный угол в осях решателя (x — восток, y — север = −z мира).
    pub x0: f64,
    pub y0: f64,
    pub level: Level,
    pub tc: Vec<u8>,
    pub pair: Arc<Pair>,
    pub field: Arc<Field>,
}

/// Итог расчёта одного окна (для журнала и замеров).
#[derive(Clone, Debug, PartialEq)]
pub struct WinReport {
    pub dx: f64,
    pub x0: f64,
    pub y0: f64,
    /// Старт тёплый (прошлое окно).
    pub warm: bool,
    /// Итерации решений `[mech, heat]`.
    pub iters: [usize; 2],
    pub stop: [StopReason; 2],
    /// `div_rms` невязки `[mech, heat]` (диагностика RW-6z).
    pub div_rms: [f64; 2],
    /// Поправка потока границы `[mech, heat]`, м/с.
    pub corr: [f32; 2],
    /// Секунды: подготовка входа (параллельно на все окна), граница и старт, решения, поле.
    pub secs: [f64; 4],
}

/// Что считать: места окон, уровни выше сдвигаемого (не пересчитываются) и прошлые окна для
/// тёплого старта.
#[derive(Clone, Debug, Default)]
pub struct Plan {
    /// Углы всех окон (от грубого к мелкому).
    pub corners: Vec<[f64; 2]>,
    /// Окна крупнее пересчитываемых (готовые, остаются как есть); пересчёт — с `keep.len()`.
    pub keep: Vec<Arc<WinLevel>>,
    /// Прошлые окна (весь набор) — тёплый старт одноимённых уровней; пусто — холодный.
    pub prev: Vec<Arc<WinLevel>>,
}

impl Plan {
    /// Все окна заново с центром `center` (оси решателя).
    pub fn fresh(dxs: &[f64], center: [f64; 2]) -> Plan {
        Plan {
            corners: dxs.iter().map(|&dx| corner(center, dx)).collect(),
            ..Plan::default()
        }
    }
}

/// Окна, область и условия, по которым они посчитаны (снимок).
#[derive(Clone, Debug)]
pub struct ClipMap {
    /// Клетки окон от грубого к мелкому, м.
    pub dxs: Vec<f64>,
    /// Углы окон. Окна не посчитаны (`wins` пусто) — места последней попытки.
    pub corners: Vec<[f64; 2]>,
    /// Окна от грубого к мелкому: все или ни одного.
    pub wins: Vec<Arc<WinLevel>>,
    pub area: Arc<ParentArea>,
    pub area_field: Arc<Field>,
    /// Условия, по которым посчитаны область и окна (сдвиг считает окна по ним же).
    pub cond: Conditions,
    pub rec: CondRec,
    pub k: f64,
}

/// Угол окна `dx` с центром `center` (кратен 25 м; `AirClipmap._corner`).
pub fn corner(center: [f64; 2], dx: f64) -> [f64; 2] {
    let d = window_domain(dx, center[0], center[1], N_WINDOW);
    [d.x0, d.y0]
}

/// Центр окна по углу.
pub fn center_of(corner: [f64; 2], dx: f64) -> [f64; 2] {
    let h = 0.5 * N_WINDOW as f64 * dx;
    [corner[0] + h, corner[1] + h]
}

/// Какое окно (с какого уровня от грубого) пора сдвигать за `pilot`: первое, чей центр дальше
/// `frac` стороны (`AirClipmap.update`). `None` — не пора.
pub fn shift_level(corners: &[[f64; 2]], dxs: &[f64], pilot: [f64; 2], frac: f64) -> Option<usize> {
    corners.iter().zip(dxs).position(|(c, &dx)| {
        let m = center_of(*c, dx);
        let side = N_WINDOW as f64 * dx;
        (pilot[0] - m[0]).abs().max((pilot[1] - m[1]).abs()) > frac * side
    })
}

/// Угол окна после сдвига: прежний плюс целое число клеток так, чтобы `pilot` был у центра.
pub fn shifted_corner(c: [f64; 2], dx: f64, pilot: [f64; 2]) -> [f64; 2] {
    let m = center_of(c, dx);
    [
        c[0] + ((pilot[0] - m[0]) / dx).round() * dx,
        c[1] + ((pilot[1] - m[1]) / dx).round() * dx,
    ]
}

impl ClipMap {
    /// Окна не посчитаны (отказ): область и места для новой попытки.
    pub fn unplaced(
        dxs: &[f64],
        corners: Vec<[f64; 2]>,
        area: Arc<ParentArea>,
        area_field: Arc<Field>,
        cond: Conditions,
        rec: CondRec,
        k: f64,
    ) -> ClipMap {
        ClipMap {
            dxs: dxs.to_vec(),
            corners,
            wins: Vec::new(),
            area,
            area_field,
            cond,
            rec,
            k,
        }
    }

    /// Все окна посчитаны (есть что сдвигать).
    pub fn ready(&self) -> bool {
        !self.dxs.is_empty() && self.wins.len() == self.dxs.len()
    }

    /// Уровни от мелкого к грубому: окна и область (посчитанные).
    pub fn levels(&self) -> Vec<Arc<Field>> {
        let mut v: Vec<Arc<Field>> = self.wins.iter().rev().map(|w| w.field.clone()).collect();
        v.push(self.area_field.clone());
        v
    }

    /// Центр окна `q` (от грубого), оси решателя.
    pub fn center(&self, q: usize) -> [f64; 2] {
        center_of(self.corners[q], self.dxs[q])
    }

    /// Пора ли сдвигать за `pilot` и с какого уровня. Окна не посчитаны — первая же попытка
    /// проверяется по местам прежней (отказавшей) — как сдвиг.
    pub fn shift_target(&self, pilot: [f64; 2], frac: f64) -> Option<usize> {
        shift_level(&self.corners, &self.dxs, pilot, frac)
    }

    /// План сдвига с уровня `q` за `pilot`: окна `q…` получают новые углы, остальные остаются;
    /// окна не посчитаны — заново вокруг `pilot`.
    pub fn plan_shift(&self, q: usize, pilot: [f64; 2]) -> Plan {
        if !self.ready() {
            return Plan::fresh(&self.dxs, pilot);
        }
        let q = q.min(self.dxs.len());
        let corners = (0..self.dxs.len())
            .map(|i| {
                if i < q {
                    self.corners[i]
                } else {
                    shifted_corner(self.corners[i], self.dxs[i], pilot)
                }
            })
            .collect();
        Plan {
            corners,
            keep: self.wins[..q].to_vec(),
            prev: self.wins.clone(),
        }
    }
}

/// Итог расчёта окон.
pub struct Windows {
    pub clip: Arc<ClipMap>,
    pub reports: Vec<WinReport>,
}

// ---------------------------------------------------------------------------------------------
// расчёт
// ---------------------------------------------------------------------------------------------

fn nest_src<'a>(tc: &'a [u8], s: &'a State) -> NestSrc<'a> {
    NestSrc {
        tc,
        u: &s.u,
        v: &s.v,
        w: &s.w,
        th: &s.th,
        thd: Some(&s.thd),
    }
}

fn shift_src(s: &State) -> ShiftSrc<'_> {
    ShiftSrc {
        u: &s.u,
        v: &s.v,
        w: &s.w,
        th: &s.th,
        thd: &s.thd,
        p: &s.p,
    }
}

fn to_state(l: &Level, w: WindowState) -> State {
    State {
        case: String::new(),
        input: String::new(),
        it: 0,
        dims: [l.nx, l.ny, l.nz],
        halo: 1,
        n: [l.nx - 2, l.ny - 2, l.nz - 2],
        u: w.u,
        v: w.v,
        w: w.w,
        th: w.th,
        thd: w.thd,
        p: w.p,
        nu: None,
        nuh: None,
        residuals: None,
    }
}

/// Решения пары окна: сначала без нагрева, затем с нагревом (`AirPicardJob`, `mech = true`).
/// Старт «родитель» — 30 V-циклов, тёплый — 4. Возвращает `[mech, heat]` и итерации.
pub struct PairSolved {
    pub mech: State,
    pub heat: State,
    pub iters: [usize; 2],
    pub stop: [StopReason; 2],
    /// `div_rms` невязки поданных решений `[mech, heat]` (диагностика RW-6z).
    pub div_rms: [f64; 2],
}

/// Решает пару `inputs` (старт переносится в состояния решателя, без копий).
pub fn solve_pair(
    cfg: &super::runtime::RtCfg,
    cancel: &Arc<AtomicBool>,
    inputs: &mut PairInputs,
) -> Result<PairSolved, JobErr> {
    solve_pair_counted(cfg, cancel, None, inputs)
}

/// [`solve_pair`] со счётчиком итераций этапа.
pub fn solve_pair_counted(
    cfg: &super::runtime::RtCfg,
    cancel: &Arc<AtomicBool>,
    stage: Option<&super::runtime::StageCounter>,
    inputs: &mut PairInputs,
) -> Result<PairSolved, JobErr> {
    let cycles = (!inputs.warm).then_some(INIT_CYCLES);
    let level = inputs.level;
    let spec = || Spec {
        init_cycles: cycles,
        ..Spec::default()
    };
    let take = |s: &mut WindowState| std::mem::replace(s, WindowState::zeros(0));
    let sm = solve_with(
        cfg,
        cancel,
        stage,
        &inputs.mech.case,
        Some(to_state(&level, take(&mut inputs.mech.start))),
        spec(),
    )?;
    let sh = solve_with(
        cfg,
        cancel,
        stage,
        &inputs.heat.case,
        Some(to_state(&level, take(&mut inputs.heat.start))),
        spec(),
    )?;
    Ok(PairSolved {
        iters: [sm.iters, sh.iters],
        stop: [sm.stop, sh.stop],
        div_rms: [sm.residuals.div_rms, sh.residuals.div_rms],
        mech: sm.state,
        heat: sh.state,
    })
}

/// Окно с нагревом для угла `corner`: погода, вход и случай (`AirWindowCase.window_at`).
fn window_case(
    job: &JobIn,
    area: &ParentArea,
    dx: f64,
    corner: [f64; 2],
    k: f64,
) -> Result<AirWindowCase, JobErr> {
    check_cancel(job)?;
    let cfg = &job.cfg;
    let dom = Domain {
        x0: corner[0],
        y0: corner[1],
        nx: N_WINDOW,
        ny: N_WINDOW,
        dx,
    };
    let fw: FieldWeather = weather_for(job, &dom)?;
    check_cancel(job)?;
    let pz = area.zi.parent();
    let inp = build_window_input(&job.place, &cfg.wc.sh, &cfg.zi, &dom, &fw.day, Some(&pz))?;
    check_cancel(job)?;
    let opts = CaseOpts {
        k,
        inflow_mode: job.rec.inflow,
        heat: true,
    };
    Ok(AirWindowCase::from_input(
        &inp,
        &fw.wind,
        fw.inputs.u10,
        fw.inputs.wdir,
        Some(&fw.heat),
        &opts,
    )?)
}

/// Подставной отказ окон (тесты): один из `job.win_fail` расходуется.
fn injected_failure(job: &JobIn) -> bool {
    job.win_fail
        .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |n| n.checked_sub(1))
        .is_ok()
}

/// Считает окна по `plan` от области `area` (решения пар сверху вниз); `progress` — доля 0..1.
/// Окна `plan.keep` остаются как есть. Ошибка любого окна — ошибка всего набора (откат на
/// область — дело вызывающего); отмена — `Cancelled`.
pub fn solve_windows(
    job: &JobIn,
    area: &Arc<ParentArea>,
    area_field: &Arc<Field>,
    k: f64,
    plan: Plan,
    progress: &dyn Fn(f32),
) -> Result<Windows, JobErr> {
    let cfg = &job.cfg;
    let n = cfg.window_dx.len();
    if plan.corners.len() != n || plan.keep.len() > n {
        return Err(JobErr::Failed(
            "windows: plan does not match window_levels_m".into(),
        ));
    }
    let from = plan.keep.len();
    progress(0.0);
    check_cancel(job)?;
    if injected_failure(job) {
        return Err(JobErr::Failed("windows: failure (injected)".into()));
    }
    // входы окон не зависят от родителя (кроме z_i области): параллельно
    let t_prep = Instant::now();
    let cases: Vec<Result<AirWindowCase, JobErr>> = (from..n)
        .into_par_iter()
        .map(|q| window_case(job, area, cfg.window_dx[q], plan.corners[q], k))
        .collect();
    let mut wcases = Vec::with_capacity(cases.len());
    for c in cases {
        wcases.push(c?);
    }
    let prep_s = t_prep.elapsed().as_secs_f64();
    progress(0.1);
    let mut wins: Vec<Arc<WinLevel>> = plan.keep.clone();
    let mut reports = Vec::with_capacity(wcases.len());
    for (i, wcase) in wcases.iter().enumerate() {
        let q = from + i;
        check_cancel(job)?;
        let t0 = Instant::now();
        let dx = cfg.window_dx[q];
        let [x0, y0] = plan.corners[q];
        let (plevel, ptc, ppair): (&Level, &[u8], &Pair) = if q == 0 {
            (&area.level, &area.tc, &area.pair)
        } else {
            let p = &wins[q - 1];
            (&p.level, &p.tc, &p.pair)
        };
        let parent = ParentPair {
            level: plevel,
            heat: nest_src(ptc, &ppair.heat),
            mech: nest_src(ptc, &ppair.mech),
        };
        let prev = plan.prev.get(q);
        let prev_pair = prev.map(|p| PrevPair {
            level: &p.level,
            heat: shift_src(&p.pair.heat),
            mech: shift_src(&p.pair.mech),
        });
        let mut inputs = window_pair_inputs(wcase, &parent, prev_pair.as_ref())?;
        let start_s = t0.elapsed().as_secs_f64();
        check_cancel(job)?;
        let t1 = Instant::now();
        let solved = solve_pair_counted(cfg, &job.cancel, Some(&job.stage), &mut inputs)?;
        let solve_s = t1.elapsed().as_secs_f64();
        let t2 = Instant::now();
        let field = build_field(
            &wcase.case,
            &inputs.heat.planes,
            &inputs.heat.case,
            &solved.heat,
            &solved.mech,
            cfg,
        )?;
        let field = FieldSet::prepare(vec![field], cfg.limits, cfg.edge_blend_cells)
            .pop()
            .ok_or_else(|| JobErr::Failed("empty window field".into()))?;
        reports.push(WinReport {
            dx,
            x0,
            y0,
            warm: inputs.warm,
            iters: solved.iters,
            stop: solved.stop,
            div_rms: solved.div_rms,
            corr: [inputs.mech.corr, inputs.heat.corr],
            secs: [prep_s, start_s, solve_s, t2.elapsed().as_secs_f64()],
        });
        wins.push(Arc::new(WinLevel {
            dx,
            x0,
            y0,
            level: inputs.level,
            tc: inputs.tc,
            pair: Arc::new(Pair {
                mech: solved.mech,
                heat: solved.heat,
            }),
            field,
        }));
        progress(0.1 + 0.9 * (i + 1) as f32 / wcases.len().max(1) as f32);
    }
    Ok(Windows {
        clip: Arc::new(ClipMap {
            dxs: cfg.window_dx.clone(),
            corners: plan.corners,
            wins,
            area: area.clone(),
            area_field: area_field.clone(),
            cond: job.cond.clone(),
            rec: job.rec.clone(),
            k,
        }),
        reports,
    })
}

/// Сдвиг окон (задача `Formula`): `job.clip` — поле в атмосфере, `q` — с какого уровня, `pilot` —
/// центр в осях решателя. Условия — те же, что у `clip`. Итог — `JobOut` с новыми уровнями и
/// `ClipMap` (область и состояния, не затронутые сдвигом, делятся по `Arc`).
pub fn run_shift(job: JobIn, q: usize, pilot: [f64; 2]) -> Result<JobOut, JobErr> {
    let t0 = Instant::now();
    let Some(clip) = job.clip.clone() else {
        return Err(JobErr::Failed("shift: no clipmap".into()));
    };
    let plan = clip.plan_shift(q, pilot);
    let none = |_: f32| {};
    let w = solve_windows(&job, &clip.area, &clip.area_field, clip.k, plan, &none)?;
    Ok(JobOut {
        levels: w.clip.levels(),
        k: clip.k,
        rec: clip.rec.clone(),
        pair: None,
        clip: Some(w.clip),
        report: JobReport {
            passes: Vec::new(),
            planned: 0,
            log: Vec::new(),
            pass_failed: None,
            not_converged: false,
            wall_s: t0.elapsed().as_secs_f64(),
            source: Source::Computed,
            notes: Vec::new(),
            windows: w.reports,
            windows_error: None,
        },
        cache_put: None,
    })
}
