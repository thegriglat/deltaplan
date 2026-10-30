//! Зона отрыва за гребнем в масштабе 3 (`_measure_burst`,
//! ): признак отрыва из поля, σ слоя смешения по ΔU, рывки вниз (часть
//! болтанки слоя смешения, нулевое среднее), доля эвристики обратного потока.
use super::gust::GustUnit;
use super::sigma::{TurbCfg, smoothstep};
use crate::field::wind_field::{T_AOUT, T_DESC, T_UOUT};
use crate::rand::Pcg32;

/// Опасность подветренной зоны 0..1 от ветра прогноза на высоте точки (`_lee_danger`).
pub fn lee_danger(cfg: &TurbCfg, u_ref: f64) -> f64 {
    smoothstep(cfg.danger_min, cfg.danger_full, u_ref)
}

/// σ слоя смешения за гребнем `(σ_u, σ_w)` по скачку скорости ΔU (уже × признак отрыва):
/// `u′/ΔU ≈ 0,18`, `w′/ΔU ≈ 0,14` (Bell & Mehta 1990; Pope 2000, §5.4).
pub fn sep_sigma(cfg: &TurbCfg, du: f64) -> [f64; 2] {
    // `Vector2` эталона — f32
    [
        f64::from((cfg.sep_su * du) as f32),
        f64::from((cfg.sep_sw * du) as f32),
    ]
}

/// Доля эвристики обратного потока 0..1: `1 − smoothstep(n0, n1, L/dx)`, `L = bubble_len·r` —
/// длина пузыря отрыва (Menke 2019: L/H ≈ 2,8), `dx` — клетка поля в точке. Пузырь, разрешённый
/// решателем (≥ n1 клеток), эвристика не повторяет.
pub fn reverse_unresolved(cfg: &TurbCfg, relief: f64, dx: f64) -> f64 {
    if dx <= 0.0 {
        return 1.0;
    }
    1.0 - smoothstep(
        cfg.resolved_n0,
        cfg.resolved_n1,
        cfg.bubble_len * relief.max(0.0) / dx,
    )
}

/// Признак отрыва из поля 0..1: дефицит скорости в точке против лог-профиля под «внешним» ветром
/// столба, `ex = 1 − (|U|/U_out)/(ln(z/z0)/ln(a_out/z0))` (у прилегающего потока ex ≲ 0,3, в следе
/// и пузыре ex → 1), × опускание столба. Выше `a_out` (верх следа) — 0. `uf` — скорость поля.
pub fn lee(cfg: &TurbCfg, z0: f64, uf: f64, agl: f64, tb: &[f32]) -> f64 {
    let u_out = f64::from(tb[T_UOUT]);
    let a_out = f64::from(tb[T_AOUT]);
    if u_out < 0.5 || agl >= a_out {
        return 0.0;
    }
    let r = (agl.max(2.0 * z0) / z0).ln() / (a_out.max(2.0 * z0) / z0).ln();
    let ex = 1.0 - uf / u_out / r.max(1.0e-3);
    let sep = smoothstep(cfg.ex0, cfg.ex1, ex);
    if sep <= 0.0 {
        return 0.0;
    }
    sep * smoothstep(0.0, cfg.desc, f64::from(tb[T_DESC]))
}

/// Пятно рывка 0..1: `clamp((n − порог)/ширина)` детерминированного шума, переносится ветром `u`
/// (`_lee_burst_g`). `pos` — точка, `t` — время атмосферы, `dir` — направление ветра.
pub fn burst_g(cfg: &TurbCfg, g: &GustUnit, pos: [f32; 3], t: f64, dir: [f64; 2], u: f64) -> f64 {
    let k = cfg.burst_k as f32;
    let p = [pos[0] * k, pos[1] * k, pos[2] * k];
    let nb = f64::from(g.gust_unit(p, t, dir, u * cfg.burst_k, 0.0)[0]);
    ((nb - cfg.burst_thr) / cfg.burst_width).clamp(0.0, 1.0)
}

/// Среднее и СКО `g` рывка по распределению шума рывков (`_measure_burst`: сид 4242, 2048
/// случайных точек; шум нормирован на СКО 1). Считается один раз.
pub fn measure_burst(cfg: &TurbCfg, g: &GustUnit) -> (f64, f64) {
    let mut rng = Pcg32::from_seed(4242);
    let (mut s, mut s2) = (0.0, 0.0);
    for _ in 0..2048 {
        let x = rng.randf_range(-3000.0, 3000.0);
        let y = rng.randf_range(0.0, 3000.0);
        let z = rng.randf_range(-3000.0, 3000.0);
        let k = cfg.burst_k as f32;
        let p = [x * k, y * k, z * k];
        let nb = f64::from(g.gust_unit(p, 0.0, [0.0, 0.0], 0.0, 0.0)[0]);
        let gg = ((nb - cfg.burst_thr) / cfg.burst_width).clamp(0.0, 1.0);
        s += gg;
        s2 += gg * gg;
    }
    let mean = s / 2048.0;
    (mean, (s2 / 2048.0 - mean * mean).max(0.0).sqrt())
}
