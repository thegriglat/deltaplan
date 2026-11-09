//! Источники термиков из поля Пикара (RW-10d): перенос `AirThermals` (AM-07; `docs/guide/air-model.md` →
//! «Масштаб 2: термики из поля»).
//!
//! `AirThermals::build` по среднему полю одного уровня (`Field`) и входам (поток тепла `H`, `z_i`,
//! фон `gam` — в самом поле; ветер на 10 м `u10` — параметр: в `FieldMeta` его нет) считает
//! источники термиков на час: где (`pos`), какой силы (`w0 = k·w*`, Аллен 2006), до какой высоты
//! (`top`, потолок частицы по θ̄ + θ′ поля), куда сносит (`drift`), радиус ядра (`radius`), водосбор
//! (`owner`, `area`, `flux`), и «между» пузырями — `expected_net`/`expected_up`: сколько
//! конвективной вертикали поля уже несут пузыри (`with_between` RW-10e вычитает это из `w_conv`).
//!
//! Законы: `w* = (g/θ0·H_kin·h)^(1/3)`, `h = max(z_i − hc,
//! 300)`; `w_m = (u*³ + 0,28 w*³)^(1/3)`, `Δθ = 6,5·H_kin/w_m`; `Φ = F̄ + max(W̄, 0)` — восходящий
//! поток поля; компенсирующее опускание `W̄_м` (гаусс `subsidence_smooth_m`) опускает верх слоя
//! столбца на `|W̄_м⁻|·τ_s`; плотность источников `n = n_A·Φ/Φ̂`, не больше `Φ/(w0·K̄)`; выбор по
//! убыванию Φ с радиусом исключения `√(0,696/n)`; водосбор — ближайшему источнику в досягаемости
//! (2 радиуса); вода (VI-7): точка источника только на суше, поток столбца источникам — с его суши.
//!
//! ## Числа
//! Эталон хранит массивы `Packed*` в `f32`, а скаляры и временные — в `f64`. Здесь так же:
//! массивы — `Vec<f32>`, арифметика — `f64`, а запись в массив округляет до `f32` ровно там, где
//! это делает GD (в том числе чтение «обратно» из округлённого массива: `kbar` берёт `radius[l]`
//! после округления). Сравнение `min`/`max`/`clamp` — как в эталоне (`gmin`/`gmax`/`gclamp`:
//! при NaN выбирается второй/нижний аргумент, не как у `f64::min`).
//!
//! ## Параллельность
//! Столбцы, точки источников, водосборы и параметры источников считаются полосами через `rayon`
//! (`BuildIn::bands`: 0 — по числу потоков, 1 — последовательно); каждая единица работы — чистая
//! функция столбца/источника, склейка — по порядку полос, поэтому итог от числа полос не зависит
//! побитно. Выбор источников (жадный по убыванию Φ) и суммы потоков водосборов — последовательные,
//! в порядке столбцов, как в эталоне.
//!
//! ## Границы модели
//! - Сила источника (`sun`), вода (`is_water`) и высота земли (`height_fn`) приходят снаружи
//!   (`PickGround`, замыкания): крейт `thermal_source_strength` — задача RW-10c.
//! - Облачные зацепки (тень на источнике, подсос) и жизнь термика (`ThermalField`, `AtmoThermal`) —
//!   RW-10e/RW-11. Здесь — только список источников и `fill` (параметры термика из источника, порядок
//!   вызовов `RandomNumberGenerator` буквально как у GD).
//! - `u10` GD берёт из `meta.u10` поля (иначе `cond.wind`); у `Field` его нет, поэтому `BuildIn::u10`.
//!   Шероховатость — `Field::z0` (лог-среднее карты), как `f.z0` GD.
//! - Времени сборки (`land_ms`) и сети (`mask_bytes` для ведущего) нет: маска `forced` принимается,
//!   `mask_bytes` отдаётся.
mod between;
mod columns;
mod expected;
mod owners;
mod pick;
mod sources;

pub use expected::Shape;
pub use pick::{PickGround, land_fraction, pick_in_column};
pub use sources::{Fill, FillWeather};

use crate::field::place_input::gauss2d;
use crate::field::wind_field::Field;
use columns::{ColsIn, cols_band};
use rayon::prelude::*;
use serde_json::Value;
use std::collections::HashMap;

pub const G: f64 = 9.81;
pub const THETA0: f64 = 300.0;
pub const RHO_CP: f64 = 1.2 * 1005.0;
pub const KAPPA: f64 = 0.4;
/// Холтслаг–Бовилль (1993): избыток θ частицы = b·w'θ'₀/w_m.
pub const HB_B: f64 = 6.5;
/// Мин. толщина слоя перемешивания, м.
pub const ZI_MIN: f64 = 300.0;
/// Пик Гедеона / средний подъём Аллена: пик = e·среднее; среднее Аллена максимально 0,4575.
// литерал e как в эталоне (`2.718281828`): сила источника совпадает с ним, а не с `E`
#[allow(clippy::approx_constant)]
pub const K_ALLEN: f64 = 2.718281828 * 0.4575;
/// Доля ядра Гедеона в потоке (`∫₀¹ e^(−u)(1 − u) du = e⁻¹`).
pub const CORE_FLUX: f64 = 0.36787944;
/// Аллен (2006): `r₂ = max(R_MIN, 0,102·ζ^(1/3)(1 − 0,25ζ)·z_i)`, число потоков `0,6·A/(z_i·r₂(½))`.
pub const ALLEN_R2: f64 = 0.102;
pub const ALLEN_R_MIN: f64 = 10.0;
pub const ALLEN_N: f64 = 0.6;
/// Случайная последовательная укладка кругов (насыщение 0,547): шаг исключения `√(0,696/n)`.
pub const RSA_K: f64 = 0.834;
/// Точек профиля потока ядра по ξ.
pub const NQ: usize = 33;
/// Шаг таблицы среднего потока ядра по глубине столба, м.
pub const SM_STEP: f64 = 25.0;
/// Ячейка поиска источников по месту, м.
pub const BUCKET_M: f64 = 1000.0;
/// Ячейка поиска источников, столбцов.
pub const B: usize = 4;
/// Доля суши столбца — по `LAND_N × LAND_N` точкам.
pub const LAND_N: usize = 4;

/// `MAX`/`MIN`/`CLAMP` эталона (`maxf`, `minf`, `clampf`): сравнением, а не `f64::max` — при NaN
/// результат тот же, что у эталона.
#[inline]
pub fn gmax(a: f64, b: f64) -> f64 {
    if a > b { a } else { b }
}
#[inline]
pub fn gmin(a: f64, b: f64) -> f64 {
    if a < b { a } else { b }
}
#[inline]
pub fn gclamp(x: f64, lo: f64, hi: f64) -> f64 {
    if x < lo {
        lo
    } else if x > hi {
        hi
    } else {
        x
    }
}

/// `smoothstep(from, to, x)` эталона.
pub fn smoothstep(from: f64, to: f64, x: f64) -> f64 {
    if (from - to).abs() <= 1.0e-5 * from.abs().max(1.0) {
        return if x <= from { 0.0 } else { 1.0 };
    }
    let s = gclamp((x - from) / (to - from), 0.0, 1.0);
    s * s * (3.0 - 2.0 * s)
}

/// Масштаб Дирдорфа столбца (= `WindField.deardorff_wstar`, те же выражения).
pub fn wstar(heat_wm2: f64, z_i: f64, hc: f64) -> f64 {
    if heat_wm2 <= 0.0 || !z_i.is_finite() {
        return 0.0;
    }
    (G / THETA0 * heat_wm2 / RHO_CP * gmax(z_i - hc, ZI_MIN)).powf(1.0 / 3.0)
}

/// Радиус восходящего потока Аллена на высоте ζ = z/z_i слоя толщины `zi`, м.
pub fn allen_r2(zeta: f64, zi: f64) -> f64 {
    gmax(
        ALLEN_R_MIN,
        ALLEN_R2 * zeta.powf(1.0 / 3.0) * (1.0 - 0.25 * zeta) * zi,
    )
}

/// Живых потоков Аллена на м² в слое толщины `zi`.
pub fn allen_density(zi: f64) -> f64 {
    ALLEN_N / (zi * allen_r2(0.5, zi))
}

/// Конфиг сборки: секция `atmosphere → thermal` (+ погода: доля жизни `duty`, кромка `cloudbase_msl`).
#[derive(Clone, Debug, PartialEq)]
pub struct AirThermalsCfg {
    /// Доля циклов с термиком (`thermal_duty` погоды).
    pub duty: f64,
    /// Середины диапазонов `grow_s`, `mature_s`, `decay_s`, `gap_s`, с.
    pub grow_s: f64,
    pub mature_s: f64,
    pub decay_s: f64,
    pub gap_s: f64,
    pub ground_ramp_m: f64,
    pub top_taper_m: f64,
    pub radius_min_factor: f64,
    pub profile_cutoff_radii: f64,
    /// Кромка облаков из погоды, м над морем (`INFINITY` — нет).
    pub cloudbase_msl: f64,
    pub subsidence_tau_s: f64,
    pub subsidence_smooth_m: f64,
    /// Кандидатов точки источника в столбце (`pick_in_column`).
    pub source_candidates: usize,
}

impl Default for AirThermalsCfg {
    /// Значения секция `atmosphere → thermal`.
    fn default() -> Self {
        AirThermalsCfg {
            duty: 1.0,
            grow_s: 180.0,
            mature_s: 510.0,
            decay_s: 225.0,
            gap_s: 180.0,
            ground_ramp_m: 150.0,
            top_taper_m: 120.0,
            radius_min_factor: 0.45,
            profile_cutoff_radii: 2.5,
            cloudbase_msl: f64::INFINITY,
            subsidence_tau_s: 10800.0,
            subsidence_smooth_m: 10000.0,
            source_candidates: 8,
        }
    }
}

fn mid(v: Option<&Value>, dv: f64) -> f64 {
    match v {
        Some(Value::Array(a)) if a.len() >= 2 => {
            0.5 * (a[0].as_f64().unwrap_or(dv) + a[1].as_f64().unwrap_or(dv))
        }
        Some(x) => x.as_f64().unwrap_or(dv),
        None => dv,
    }
}

impl AirThermalsCfg {
    /// Из секции `thermal` конфига секция `atmosphere`; `duty` и `cloudbase_msl` — из погоды и облаков.
    /// Нет ключа — значение по умолчанию (`Default`).
    pub fn from_thermal(thermal: &Value, duty: f64, cloudbase_msl: f64) -> Self {
        let d = AirThermalsCfg::default();
        let g = |k: &str, dv: f64| thermal.get(k).and_then(Value::as_f64).unwrap_or(dv);
        AirThermalsCfg {
            duty,
            grow_s: mid(thermal.get("grow_s"), d.grow_s),
            mature_s: mid(thermal.get("mature_s"), d.mature_s),
            decay_s: mid(thermal.get("decay_s"), d.decay_s),
            gap_s: mid(thermal.get("gap_s"), d.gap_s),
            ground_ramp_m: g("ground_ramp_m", d.ground_ramp_m),
            top_taper_m: g("top_taper_m", d.top_taper_m),
            radius_min_factor: g("radius_min_factor", d.radius_min_factor),
            profile_cutoff_radii: g("profile_cutoff_radii", d.profile_cutoff_radii),
            cloudbase_msl,
            subsidence_tau_s: g("subsidence_tau_s", d.subsidence_tau_s),
            subsidence_smooth_m: g("subsidence_smooth_m", d.subsidence_smooth_m),
            source_candidates: thermal
                .get("source_candidates")
                .and_then(Value::as_f64)
                .map_or(d.source_candidates, |x| x as usize),
        }
    }
}

/// Вход сборки сверх поля.
pub struct BuildIn<'a> {
    pub cfg: &'a AirThermalsCfg,
    /// Ветер прогноза на 10 м, м/с (для `u*`); 0 — нет.
    pub u10: f64,
    /// Настоящая высота земли в точке источника; нет — рельеф сетки.
    pub height_fn: Option<&'a (dyn Fn(f64, f64) -> f64 + Sync)>,
    /// Точка источника в столбце `(i, j)` (`pick_in_column`); `None` из замыкания — столбец не
    /// источник (вода). Нет самой функции — центр столбца.
    pub pick_fn: Option<&'a (dyn Fn(usize, usize) -> Option<[f32; 2]> + Sync)>,
    /// Доля суши по столбцам (прежней сборки той же сетки); иной размер — не используется.
    pub land: Option<&'a [f32]>,
    /// Вода в точке (x, z мира) — для `land_fraction`, если `land` не дано.
    pub water_fn: Option<&'a (dyn Fn(f64, f64) -> bool + Sync)>,
    /// Маска столбцов-источников (сеть: список ведущего), бит на столбец `j·nx + i`; `None` — выбрать.
    pub forced: Option<&'a [u8]>,
    /// Полос параллельной сборки: 0 — по числу потоков, 1 — последовательно.
    pub bands: usize,
    /// Число источников по циклу без `duty` (RW-26): живых термиков в итоге `Аллен · duty`, т. е.
    /// падает вместе с `thermal_duty` погоды; пиковая скорость `w0 = K_ALLEN·w*` от `duty` не
    /// зависит (граница модели: суммарный поток вечером падает вместе с числом термиков). `false` - как эталон: источников столько, чтобы живых
    /// при `duty` было `Аллен` (число живых от `duty` не зависит).
    pub count_by_cycle: bool,
}

impl<'a> BuildIn<'a> {
    pub fn new(cfg: &'a AirThermalsCfg, u10: f64) -> Self {
        BuildIn {
            cfg,
            u10,
            height_fn: None,
            pick_fn: None,
            land: None,
            water_fn: None,
            forced: None,
            bands: 0,
            count_by_cycle: false,
        }
    }
}

/// Один источник (срез SoA `AirThermals`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AirSource {
    /// Номер столбца `j·nx + i`.
    pub col: usize,
    /// Точка (x, y рельефа, z мира).
    pub pos: [f32; 3],
    /// Сила ядра на пике, м/с.
    pub w0: f32,
    /// Радиус ядра у верха (Аллен), м.
    pub radius: f32,
    /// `w*` водосбора, м/с.
    pub wstar: f32,
    /// Потолок частицы, м над морем (без кромки).
    pub top: f32,
    /// Снос — средний ветер столба (x, z мира), м/с.
    pub drift: [f32; 2],
    /// Поток водосбора `M`, м³/с; из него несут ядра `carried`; чистый поток пузыря `net`.
    pub flux: f32,
    pub carried: f32,
    pub net: f32,
    /// Множитель кольца Гедеона.
    pub ring: f32,
    /// Площадь водосбора (с учётом суши), м².
    pub area: f32,
    /// Глубина столба `D`, м.
    pub depth: f32,
}

/// Источники термиков из поля (SoA, как `AirThermals` GD). Поля — результат `build`.
#[derive(Clone, Debug)]
pub struct AirThermals {
    /// Подпись сетки `dx, x0, y0, nx, ny` — для сети и кеша доли суши.
    pub grid_sig: String,
    nx: usize,
    ny: usize,
    x0: f64,
    y0: f64,
    dx: f64,
    pub col: Vec<usize>,
    pub pos: Vec<[f32; 3]>,
    pub w0: Vec<f32>,
    pub radius: Vec<f32>,
    pub wstar: Vec<f32>,
    pub top: Vec<f32>,
    pub drift: Vec<[f32; 2]>,
    pub flux: Vec<f32>,
    pub carried: Vec<f32>,
    pub net: Vec<f32>,
    pub ring: Vec<f32>,
    pub area: Vec<f32>,
    pub depth: Vec<f32>,
    /// По столбцам: чей водосбор (−1 — ничей), Φ (м/с), H (Вт/м²), W̄ (м/с), F̄ (м/с).
    pub owner: Vec<i32>,
    pub phi: Vec<f32>,
    pub col_heat: Vec<f32>,
    pub col_w: Vec<f32>,
    pub col_f: Vec<f32>,
    /// Потолок частицы столбца (над морем; без нагрева — высота земли; пропущенный — NaN) и `w*` столбца.
    pub c_top: Vec<f32>,
    pub col_wstar: Vec<f32>,
    /// CLF-10: `W̄_м` (сглаженный), `z_i` столбца с опусканием, опускание верха `Δz_s`, м.
    pub col_wm: Vec<f32>,
    pub col_zi: Vec<f32>,
    pub col_sub: Vec<f32>,
    /// Доля суши по столбцам 0..1; пусто — воды не знаем (вся суша).
    pub land: Vec<f32>,
    /// Средний по столбу поток ядра на 1 м/с пика, м² (`K̄/⟨жизнь⟩`).
    pub shape_area: f64,
    /// Средняя по времени доля (огибающая × доля циклов).
    pub life_mean: f64,
    /// Доля времени, когда термик источника жив.
    pub alive_frac: f64,
    /// Средний Φ кандидатов с весом `n_A`, м/с.
    pub phi_ref: f64,
    /// Поток, не доставшийся ни одному водосбору; весь поток; поток, который несут ядра, м³/с.
    pub lost_flux: f64,
    pub total_flux: f64,
    pub carried_flux: f64,
    shape: Shape,
    hcs: Vec<f32>,
    u_scale: Vec<f32>,
    n_scale: Vec<f32>,
    src_depth: Vec<f32>,
    index: HashMap<usize, usize>,
    buckets: HashMap<(i64, i64), Vec<usize>>,
    edge_cells: f64,
    z_bot: f64,
    z_top: f64,
    inv_dx: f64,
    inv_dz: f64,
}

/// Есть ли в поле всё нужное: `H`, `z_i`, `gam` (`AirThermals.has_inputs`).
pub fn has_inputs(f: &Field) -> bool {
    !f.heat_flux().is_empty() && !f.z_i().is_nan() && f.gam().len() == f.grid().nz
}

/// Подпись сетки уровня.
pub fn signature(f: &Field) -> String {
    let g = f.grid();
    format!("{:.3},{:.3},{:.3},{},{}", g.dx, g.x0, g.y0, g.nx, g.ny)
}

/// Два уровня покрывают одни и те же точки (сетка, верх, рельеф, кромка).
pub fn same_cover(a: &Field, b: &Field) -> bool {
    std::ptr::eq(a, b)
        || (a.grid() == b.grid() && a.edge_cells == b.edge_cells && a.raw_hc() == b.raw_hc())
}

/// Полосы `[n·b/nb, n·(b+1)/nb)` — по порядку; `nb = 1` — один вызов. Результаты — по порядку полос.
pub(crate) fn run_bands<T: Send>(
    n: usize,
    bands: usize,
    f: impl Fn(usize, usize) -> T + Sync,
) -> Vec<T> {
    let nb = if bands == 0 {
        rayon::current_num_threads().max(1)
    } else {
        bands
    }
    .clamp(1, n.max(1));
    if nb == 1 {
        return vec![f(0, n)];
    }
    (0..nb)
        .into_par_iter()
        .map(|b| f(n * b / nb, n * (b + 1) / nb))
        .collect()
}

impl AirThermals {
    /// Построить источники. `None` — нет входа (`H`, `z_i`) или размеры не сходятся.
    pub fn build(f: &Field, inp: &BuildIn) -> Option<AirThermals> {
        let g = *f.grid();
        let (nx, ny, nz) = (g.nx, g.ny, g.nz);
        let n_col = nx * ny;
        let heat = f.heat_flux();
        if heat.len() != n_col || f.z_i().is_nan() {
            return None;
        }
        let cfg = inp.cfg;
        let k1s = f.raw_k1();
        let hcs = f.raw_hc();
        let z_i = f.z_i();
        let mut zic: Vec<f32> = f.z_i_col().to_vec();
        if zic.len() != n_col {
            zic = vec![z_i as f32; n_col];
        }
        let mut gam: Vec<f32> = f.gam().to_vec();
        if gam.len() != nz {
            gam = vec![0.0; nz];
        }
        let ustar = if inp.u10 > 0.0 {
            KAPPA * inp.u10 / (10.0 / f.z0()).ln()
        } else {
            0.0
        };
        let cb = cfg.cloudbase_msl;
        let shape = Shape::new(cfg);
        let cut = cfg.profile_cutoff_radii;
        // ∫ кольца Гедеона 1..cut² e^(−u)(1 − u) du = cut²·e^(−cut²) − e⁻¹ (< 0)
        let ring_int = (cut * cut * (-cut * cut).exp() - CORE_FLUX).abs();
        let wconv = f.raw_w_conv();
        let nxy = n_col;
        let theta = f.raw_theta();
        // θ̄ относительно низа сетки (интеграл dθ̄/dz по центрам уровней)
        let mut tbar = vec![0f32; nz];
        let mut acc = 0.0f64;
        for k in 0..nz {
            if k > 0 {
                acc += 0.5 * (gam[k - 1] as f64 + gam[k] as f64) * g.dz;
            }
            tbar[k] = acc as f32;
        }
        let col_heat = heat.to_vec();
        let mut col_w = vec![0f32; n_col];
        let tau_s = gmax(cfg.subsidence_tau_s, 0.0);
        // W̄: средний w_conv по воздушным клеткам столбца в слое 0..h поля (h — по z_i столбца поля,
        // без опускания: W̄ — вход опускания, не его следствие); столбец без воздуха — 0.
        for c in 0..n_col {
            let k1 = k1s[c] as usize;
            if k1 >= nz || (zic[c] as f64).is_nan() {
                continue;
            }
            let h0 = gmax(zic[c] as f64 - hcs[c] as f64, ZI_MIN);
            let mut sw = 0.0f64;
            let mut nw = 0usize;
            for k in k1..nz {
                if g.z_bot + (k as f64 + 0.5) * g.dz - hcs[c] as f64 > h0 {
                    break;
                }
                sw += wconv[k * nxy + c] as f64;
                nw += 1;
            }
            col_w[c] = if nw > 0 { (sw / nw as f64) as f32 } else { 0.0 };
        }
        // W̄_м: W̄, сглаженный гауссом до мезомасштаба горно-равнинной циркуляции (CLF-10)
        let mut col_wm = col_w.clone();
        let sm = cfg.subsidence_smooth_m / g.dx;
        if tau_s > 0.0 && sm > 0.3 {
            let w64: Vec<f64> = col_w.iter().map(|&x| x as f64).collect();
            let sg = gauss2d(&w64, nx, ny, sm);
            for c in 0..n_col {
                col_wm[c] = sg[c] as f32;
            }
        }
        let cell_a = g.dx * g.dx;
        let land: Vec<f32> = match inp.land {
            Some(l) if l.len() == n_col => l.to_vec(),
            _ => match inp.water_fn {
                Some(w) => land_fraction(f, w),
                None => Vec::new(),
            },
        };
        let has_land = !land.is_empty();
        let lnd = |c: usize| if has_land { land[c] as f64 } else { 1.0 };
        // --- столбцы полосами строк: Φ, потолок частицы, z_l, n_A, K̄, кандидаты
        let cin = ColsIn {
            f,
            heat,
            k1s,
            hcs,
            z_i,
            ustar,
            cb,
            cut,
            tbar: &tbar,
            theta,
            land: if has_land { Some(&land) } else { None },
            zic: &zic,
            col_w: &col_w,
            col_wm: &col_wm,
            tau_s,
        };
        let parts = run_bands(ny, inp.bands, |lo, hi| cols_band(&cin, lo, hi));
        let mut col_wstar = Vec::with_capacity(n_col);
        let mut col_zi = Vec::with_capacity(n_col);
        let mut col_f = Vec::with_capacity(n_col);
        let mut phi = Vec::with_capacity(n_col);
        let mut c_top = Vec::with_capacity(n_col);
        let mut c_zl = Vec::with_capacity(n_col);
        let mut cand_r = Vec::with_capacity(n_col);
        let mut c_na = Vec::with_capacity(n_col);
        let mut c_k = Vec::with_capacity(n_col);
        let mut cand: Vec<usize> = Vec::new();
        let mut col_sub = Vec::with_capacity(n_col);
        for p in parts {
            col_wstar.extend(p.ws);
            col_zi.extend(p.zi);
            col_f.extend(p.f);
            phi.extend(p.phi);
            c_top.extend(p.ctop);
            c_zl.extend(p.zl);
            cand_r.extend(p.cand_r);
            c_na.extend(p.na);
            c_k.extend(p.k);
            cand.extend(p.cand);
            col_sub.extend(p.sub);
        }
        // --- плотность: живых n_A (Аллен) на площадь, распределённых по Φ (Φ/Φ̂), ÷ доля жизни;
        // ядра не несут больше Φ столбца.
        let mut s_na = 0.0f64;
        let mut s_naphi = 0.0f64;
        for &c in &cand {
            s_na += c_na[c] as f64;
            s_naphi += c_na[c] as f64 * phi[c] as f64;
        }
        let phi_ref = if s_na > 0.0 { s_naphi / s_na } else { 0.0 };
        let count_frac = if inp.count_by_cycle {
            shape.cycle_frac
        } else {
            shape.alive_frac
        };
        for c in 0..n_col {
            if c_na[c] <= 0.0 || phi_ref <= 0.0 {
                continue;
            }
            let mut dens = c_na[c] as f64 * phi[c] as f64 / phi_ref / gmax(count_frac, 1.0e-3);
            let cap = phi[c] as f64 / gmax(K_ALLEN * col_wstar[c] as f64 * c_k[c] as f64, 1.0e-9);
            dens = gmin(dens, cap);
            let rc = cand_r[c] as f64;
            cand_r[c] = gclamp(
                RSA_K / gmax(dens, 1.0e-12).sqrt(),
                rc,
                gmax(4.0 * c_zl[c] as f64, rc),
            ) as f32;
        }
        // --- выбор источников и точки
        let nbx = nx.div_ceil(B);
        let nby = ny.div_ceil(B);
        let mut chosen = owners::choose(
            nx, ny, nz, g.dx, k1s, &cand, &phi, &cand_r, nbx, nby, inp.forced,
        );
        let mut picked: HashMap<usize, [f32; 2]> = HashMap::new();
        if let Some(pf) = inp.pick_fn {
            // точки — параллельно (детерминированы по столбцу и сиду)
            let pts: Vec<Option<[f32; 2]>> = run_bands(chosen.len(), inp.bands, |lo, hi| {
                (lo..hi)
                    .map(|s| pf(chosen[s] % nx, chosen[s] / nx))
                    .collect::<Vec<_>>()
            })
            .into_iter()
            .flatten()
            .collect();
            let mut kept = Vec::with_capacity(chosen.len());
            for (s, &c) in chosen.iter().enumerate() {
                if let Some(p) = pts[s] {
                    picked.insert(c, p);
                    kept.push(c);
                }
            }
            chosen = kept;
        }
        // --- водосборы
        let ns = chosen.len();
        let (owner, _reach) = owners::watersheds(
            nx,
            ny,
            nz,
            g.dx,
            k1s,
            if has_land { Some(&land) } else { None },
            &chosen,
            &cand_r,
            nbx,
            nby,
            inp.bands,
        );
        let mut m_i = vec![0f64; ns];
        let mut o_i = vec![0f64; ns];
        let mut a_i = vec![0f64; ns];
        let mut total_flux = 0.0f64;
        let mut lost_flux = 0.0f64;
        for c in 0..n_col {
            if k1s[c] as usize >= nz {
                continue;
            }
            total_flux += phi[c] as f64 * cell_a;
            let o = owner[c];
            if o < 0 {
                lost_flux += phi[c] as f64 * cell_a;
                continue;
            }
            let o = o as usize;
            let la = cell_a * lnd(c);
            m_i[o] += phi[c] as f64 * cell_a;
            o_i[o] += gmax(col_w[c] as f64, 0.0) * la;
            a_i[o] += la;
        }
        let mut hsum = vec![0f64; ns];
        for c in 0..n_col {
            if owner[c] >= 0 {
                hsum[owner[c] as usize] += gmax(heat[c] as f64, 0.0) * cell_a * lnd(c);
            }
        }
        // --- параметры источников
        let sin = sources::SrcIn {
            f,
            chosen: &chosen,
            picked: &picked,
            hcs,
            k1s,
            s_top: &c_top,
            c_zl: &c_zl,
            cb,
            s_zi: &col_zi,
            hsum: &hsum,
            m_i: &m_i,
            o_i: &o_i,
            a_i: &a_i,
            ring_int,
            height_fn: inp.height_fn,
        };
        let sp = run_bands(ns, inp.bands, |lo, hi| sources::src_band(&sin, lo, hi));
        let mut t = AirThermals {
            grid_sig: signature(f),
            nx,
            ny,
            x0: g.x0,
            y0: g.y0,
            dx: g.dx,
            col: chosen.clone(),
            pos: Vec::with_capacity(ns),
            w0: Vec::with_capacity(ns),
            radius: Vec::with_capacity(ns),
            wstar: Vec::with_capacity(ns),
            top: Vec::with_capacity(ns),
            drift: Vec::with_capacity(ns),
            flux: Vec::with_capacity(ns),
            carried: Vec::with_capacity(ns),
            net: Vec::with_capacity(ns),
            ring: Vec::with_capacity(ns),
            area: Vec::with_capacity(ns),
            depth: Vec::with_capacity(ns),
            owner,
            phi,
            col_heat,
            col_w,
            col_f,
            c_top,
            col_wstar,
            col_wm,
            col_zi,
            col_sub,
            land,
            shape_area: shape.shape_area,
            life_mean: shape.life_mean,
            alive_frac: shape.alive_frac,
            phi_ref,
            lost_flux,
            total_flux,
            carried_flux: 0.0,
            shape,
            hcs: hcs.to_vec(),
            u_scale: vec![0.0; n_col],
            n_scale: vec![0.0; n_col],
            src_depth: vec![1.0; n_col],
            index: HashMap::new(),
            buckets: HashMap::new(),
            edge_cells: f.edge_cells,
            z_bot: g.z_bot,
            z_top: g.z_bot + nz as f64 * g.dz,
            inv_dx: 1.0 / g.dx,
            inv_dz: 1.0 / g.dz,
        };
        for p in sp {
            t.pos.extend(p.pos);
            t.top.extend(p.top);
            t.depth.extend(p.depth);
            t.wstar.extend(p.wstar);
            t.flux.extend(p.flux);
            t.area.extend(p.area);
            t.radius.extend(p.radius);
            t.w0.extend(p.w0);
            t.carried.extend(p.carried);
            t.net.extend(p.net);
            t.ring.extend(p.ring);
            t.drift.extend(p.drift);
        }
        let mut cf = 0.0f64;
        for s in 0..ns {
            cf += t.carried[s] as f64;
        }
        t.carried_flux = cf;
        // --- по столбцам водосбора: поток ядер и чистый поток / A_i
        for c in 0..n_col {
            if t.owner[c] >= 0 {
                let s = t.owner[c] as usize;
                t.u_scale[c] = (t.carried[s] as f64 / gmax(a_i[s], 1.0)) as f32;
                t.n_scale[c] = (t.net[s] as f64 / gmax(a_i[s], 1.0)) as f32;
                t.src_depth[c] = t.depth[s];
            }
        }
        for (s, &cs) in chosen.iter().enumerate() {
            t.index.insert(cs, s);
            let bk = (
                (t.pos[s][0] as f64 / BUCKET_M).floor() as i64,
                (t.pos[s][2] as f64 / BUCKET_M).floor() as i64,
            );
            t.buckets.entry(bk).or_default().push(s);
        }
        Some(t)
    }

    pub fn count(&self) -> usize {
        self.col.len()
    }

    /// Размеры сетки уровня: `(nx, ny)`.
    pub fn dims(&self) -> (usize, usize) {
        (self.nx, self.ny)
    }

    /// Источник `s` целиком.
    pub fn source(&self, s: usize) -> AirSource {
        AirSource {
            col: self.col[s],
            pos: self.pos[s],
            w0: self.w0[s],
            radius: self.radius[s],
            wstar: self.wstar[s],
            top: self.top[s],
            drift: self.drift[s],
            flux: self.flux[s],
            carried: self.carried[s],
            net: self.net[s],
            ring: self.ring[s],
            area: self.area[s],
            depth: self.depth[s],
        }
    }

    /// Номер источника в столбце `(i, j)` (`index` GD: ключ — пара `(j, i)`).
    pub fn index_of(&self, i: usize, j: usize) -> Option<usize> {
        self.index.get(&(j * self.nx + i)).copied()
    }

    /// Маска столбцов-источников (бит на столбец `j·nx + i`) — для сети.
    pub fn mask_bytes(&self) -> Vec<u8> {
        let mut m = vec![0u8; (self.nx * self.ny).div_ceil(8)];
        for &c in &self.col {
            m[c >> 3] |= 1 << (c & 7);
        }
        m
    }

    /// Точка `(x, z)` мира там, где термики берутся из поля (вес края уровня ≥ ½ на высоте
    /// рельефа сетки + 10 м). `ground` — настоящая земля в точке (`Field::ground_height`).
    pub fn covers(&self, f: &Field, p: [f64; 2]) -> bool {
        let y = f.ground_height(p[0] as f32, p[1] as f32) + 10.0;
        f.edge_weight([p[0] as f32, y as f32, p[1] as f32]) >= 0.5
    }

    /// Источники с точкой (x, z мира) в круге радиуса `r` вокруг `c` или, при `r < 0`, в
    /// прямоугольнике `c ± half`. Порядок — как у GD (по ячейкам 1 км).
    pub fn sources_in(&self, c: [f64; 2], r: f64, half: [f64; 2]) -> Vec<usize> {
        let h = if r < 0.0 { half } else { [r, r] };
        let (lo, hi) = ([c[0] - h[0], c[1] - h[1]], [c[0] + h[0], c[1] + h[1]]);
        let mut out = Vec::new();
        for bz in (lo[1] / BUCKET_M).floor() as i64..=(hi[1] / BUCKET_M).floor() as i64 {
            for bx in (lo[0] / BUCKET_M).floor() as i64..=(hi[0] / BUCKET_M).floor() as i64 {
                let Some(arr) = self.buckets.get(&(bx, bz)) else {
                    continue;
                };
                for &s in arr {
                    let p = self.pos[s];
                    let (px, pz) = (p[0] as f64, p[2] as f64);
                    if px < lo[0] || px > hi[0] || pz < lo[1] || pz > hi[1] {
                        continue;
                    }
                    let (dx, dz) = (px - c[0], pz - c[1]);
                    if r < 0.0 || dx * dx + dz * dz <= r * r {
                        out.push(s);
                    }
                }
            }
        }
        out
    }

    /// Номера источников с позицией в радиусе `r` от `(x, z)` (тесты, отладка).
    pub fn near(&self, x: f64, z: f64, r: f64) -> Vec<usize> {
        (0..self.count())
            .filter(|&s| {
                let (dx, dz) = (self.pos[s][0] as f64 - x, self.pos[s][2] as f64 - z);
                dx.hypot(dz) <= r
            })
            .collect()
    }

    /// Ожидаемый средний поток ядер пузырей водосбора в точке (x, y, z мира), м/с. Вне поля — 0.
    pub fn expected_up(&self, p: [f32; 3]) -> f64 {
        self.expected(p, &self.u_scale)
    }

    /// Ожидаемый средний чистый поток пузырей (ядро + кольцо) в точке, м/с: столько `w_conv` поля
    /// уже несут пузыри — «между» = `w_conv` − это.
    pub fn expected_net(&self, p: [f32; 3]) -> f64 {
        self.expected(p, &self.n_scale)
    }

    fn expected(&self, p: [f32; 3], scale: &[f32]) -> f64 {
        let i = ((p[0] as f64 - self.x0) / self.dx).floor();
        let j = ((-(p[2] as f64) - self.y0) / self.dx).floor();
        if i < 0.0 || j < 0.0 || i >= self.nx as f64 || j >= self.ny as f64 {
            return 0.0;
        }
        let c = j as usize * self.nx + i as usize;
        let u = scale[c] as f64;
        if u == 0.0 {
            return 0.0;
        }
        let xi = (p[1] as f64 - self.hcs[c] as f64) / self.src_depth[c] as f64;
        if xi <= 0.0 || xi >= 1.0 {
            return 0.0;
        }
        u * self.shape.q_at_profile(xi) / self.shape.q_mean
    }

    /// Уровень покрывает (x, z) с весом края ≥ ½ на `y` — проверка по сохранённой геометрии,
    /// без самого поля (вес как у `Field::edge_weight`).
    pub fn edge_weight(&self, pos: [f32; 3]) -> f64 {
        let gx = (pos[0] as f64 - self.x0) * self.inv_dx;
        let gy = (-(pos[2] as f64) - self.y0) * self.inv_dx;
        let d = gx
            .min(self.nx as f64 - gx)
            .min(gy)
            .min(self.ny as f64 - gy)
            .min((self.z_top - pos[1] as f64) * self.inv_dz);
        if d <= 0.0 {
            0.0
        } else if d >= self.edge_cells {
            1.0
        } else {
            let t = d / self.edge_cells;
            t * t * (3.0 - 2.0 * t)
        }
    }

    /// Низ сетки уровня, м над морем.
    pub fn z_bot(&self) -> f64 {
        self.z_bot
    }
}
