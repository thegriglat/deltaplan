//! Механизм B: пузырь срыва за гребнем (AP-10/AP-17 `envelope`): под огибающей `h_eff` — слабый
//! возвратный поток вдоль ветра, `w = 0`. Эталон — `AirPhaseCpu.mech` (r[4..7]).
use super::linear::{Slab, slab_at, u_prof};
use super::prepare::Prepared;

/// Поле B `(u, v, w)` в столбце `c` на высоте `zmsl`, если точка под огибающей срыва
/// (`h_eff − h_c > 0` и `z − h_c < h_eff − h_c`); иначе `None` (поле B = поле A).
///
/// Скорость пузыря: `u_top·(−r + (1 + r)·t²)`, `t = z_agl/depth` (от обратного потока у земли к
/// `u_top` на кромке), `u_top` — модуль скорости на нижнем уровне линейной теории.
/// Модуль `u_top` — в f32, как `Vector2.length()` GDScript.
pub fn wind_b(p: &Prepared, sl: &Slab, c: usize, zmsl: f64) -> Option<[f64; 3]> {
    let hc = p.cols.hc[c];
    let zagl = zmsl - hc;
    let depth = p.cols.heff[c] - hc;
    if !(depth > 0.0 && zagl < depth) {
        return None;
    }
    let (ex, ey) = (p.prm.ex, p.prm.ey);
    let l0 = sl.lev[0];
    let s0 = slab_at(p, sl, c, l0);
    let u0 = u_prof(p, l0);
    let (x, y) = ((u0 * ex + s0[0]) as f32, (u0 * ey + s0[1]) as f32);
    let utop = f64::from((x * x + y * y).sqrt());
    let tt = (zagl / depth).clamp(0.0, 1.0);
    let rv = p.prm.bub_r;
    let ubub = utop * (-rv + (1.0 + rv) * tt * tt);
    Some([ubub * ex, ubub * ey, 0.0])
}
