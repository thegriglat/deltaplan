//! Столбцы строк `[lo, hi)`: `w*`, `z_i` столбца с опусканием, `F̄`, `Φ`, потолок частицы, `z_l`,
//! радиус исключения, `n_A`, `K̄`, кандидаты (`_cols_band` GD). Чистая функция столбца.
use super::{
    HB_B, RHO_CP, ZI_MIN, allen_density, allen_r2, gclamp, gmax, gmin, wstar,
};
use crate::field::wind_field::Field;
use crate::terms::thermal::bubble_kbar;

pub(super) struct ColsIn<'a> {
    pub f: &'a Field,
    pub heat: &'a [f32],
    pub k1s: &'a [u32],
    pub hcs: &'a [f32],
    pub z_i: f64,
    pub ustar: f64,
    pub cb: f64,
    pub cut: f64,
    pub tbar: &'a [f32],
    pub theta: &'a [f32],
    pub land: Option<&'a [f32]>,
    pub zic: &'a [f32],
    pub col_w: &'a [f32],
    pub col_wm: &'a [f32],
    pub tau_s: f64,
}

/// Результат полосы: по столбцам полосы (порядок `j·nx + i`), кандидаты — глобальные номера.
pub(super) struct ColsOut {
    pub ws: Vec<f32>,
    pub zi: Vec<f32>,
    pub f: Vec<f32>,
    pub phi: Vec<f32>,
    pub ctop: Vec<f32>,
    pub zl: Vec<f32>,
    pub cand_r: Vec<f32>,
    pub na: Vec<f32>,
    pub k: Vec<f32>,
    pub cand: Vec<usize>,
    pub sub: Vec<f32>,
}

/// θ̄ фона на дробном уровне `x` (в единицах уровней); выше последнего — продолжение с наклоном
/// последнего шага.
fn tbar_at(tbar: &[f32], x: f64) -> f64 {
    let n = tbar.len();
    let i = x as usize;
    if i >= n - 1 {
        return if n > 1 {
            tbar[n - 1] as f64 + (x - (n - 1) as f64) * (tbar[n - 1] as f64 - tbar[n - 2] as f64)
        } else {
            tbar[n - 1] as f64
        };
    }
    let (a, b) = (tbar[i] as f64, tbar[i + 1] as f64);
    a + (b - a) * (x - i as f64)
}

#[cfg_attr(
    target_arch = "x86_64",
    multiversion::multiversion(targets("x86_64+avx2+fma"))
)]
pub(super) fn cols_band(c: &ColsIn, lo: usize, hi: usize) -> ColsOut {
    let g = *c.f.grid();
    let (nx, nz) = (g.nx, g.nz);
    let nxy = nx * g.ny;
    let nb = (hi - lo) * nx;
    let c0 = lo * nx;
    let mut o = ColsOut {
        ws: vec![0.0; nb],
        zi: c.zic[c0..c0 + nb].to_vec(),
        f: vec![0.0; nb],
        phi: vec![0.0; nb],
        ctop: vec![f32::NAN; nb],
        zl: vec![ZI_MIN as f32; nb],
        cand_r: vec![0.0; nb],
        na: vec![0.0; nb],
        k: vec![0.0; nb],
        cand: Vec::new(),
        sub: vec![0.0; nb],
    };
    let land = |col: usize| c.land.map_or(1.0, |l| l[col] as f64);
    for j in lo..hi {
        for i in 0..nx {
            let col = j * nx + i;
            let l = col - c0;
            let k1 = c.k1s[col] as usize;
            if k1 >= nz || c.z_i.is_nan() {
                continue;
            }
            let hc = c.hcs[col] as f64;
            let hk = c.heat[col] as f64 / RHO_CP;
            let wbar = c.col_w[col] as f64;
            // Компенсирующее опускание (CLF-10, Q3): за время действия циркуляции τ_s верх слоя над
            // столбцом ниже на Δz_s = |W̄_м⁻|·τ_s (бюджет dz_i/dt = w_e − |w_s|, Stull 1988 §11.2);
            // один z_i столбца на всё: h, w*, F̄, потолок частицы, радиус и плотность Аллена.
            let dz_s = gmin(
                gmax(-(c.col_wm[col] as f64), 0.0) * c.tau_s,
                gmax(c.zic[col] as f64 - hc - ZI_MIN, 0.0),
            );
            o.sub[l] = dz_s as f32;
            let zi_c = c.zic[col] as f64 - dz_s;
            o.zi[l] = zi_c as f32;
            let ws = wstar(c.heat[col] as f64, zi_c, hc);
            // Фон θ̄ столбца: z_i столбца выше опорного (CLF-К6) — θ̄ = max(θ̄(z), θ̄(z_i_col));
            // ниже опорного (рельеф или опускание) — тот же фон, опущенный на Δ = z_i_ref − z_i.
            let mut tb_lift = f64::NEG_INFINITY;
            if zi_c > c.z_i {
                let kz = gclamp((zi_c - g.z_bot) / g.dz - 0.5, 0.0, nz as f64 - 1.0);
                let kk = (kz as usize).min(nz - 2);
                let (a, b) = (c.tbar[kk] as f64, c.tbar[kk + 1] as f64);
                tb_lift = a + (b - a) * (kz - kk as f64);
            }
            let dsh = gmax(c.z_i - zi_c, 0.0) / g.dz;
            let wm = (c.ustar * c.ustar * c.ustar + 0.28 * ws * ws * ws).powf(1.0 / 3.0);
            o.ws[l] = ws as f32;
            // F̄: средний по слою 0..h поток массы подсеточной конвекции, w_m/(2b)
            let fbar = if hk > 0.0 { wm / (2.0 * HB_B) } else { 0.0 };
            o.f[l] = fbar as f32;
            // Φ — подсеточный (есть, пока греет земля) + организованный подъём; W̄⁻ в Φ не входит.
            // Источникам — поток только с суши столбца (над водой источника нет, VI-7).
            o.phi[l] = ((fbar + gmax(wbar, 0.0)) * land(col)) as f32;
            // Потолок частицы: θ_p = θ′(k1) + Δθ; выше — θ̄ + θ′ поля.
            let mut t_top = g.z_bot + nz as f64 * g.dz;
            if hk > 0.0 {
                let ex = HB_B * hk / gmax(wm, 1.0e-3);
                let base = gmax(tbar_at(c.tbar, k1 as f64 + dsh), tb_lift);
                let tp = base + c.theta[k1 * nxy + col] as f64 + ex;
                let mut prev = base + c.theta[k1 * nxy + col] as f64;
                for k in k1 + 1..nz {
                    let te = gmax(tbar_at(c.tbar, k as f64 + dsh), tb_lift)
                        + c.theta[k * nxy + col] as f64;
                    if te >= tp {
                        let fr = (tp - prev) / gmax(te - prev, 1.0e-6);
                        t_top = g.z_bot + (k as f64 - 0.5 + gclamp(fr, 0.0, 1.0)) * g.dz;
                        break;
                    }
                    prev = te;
                }
            } else {
                t_top = hc;
            }
            o.ctop[l] = t_top as f32;
            let d_top = gmin(t_top, c.cb) - hc;
            let zl = gmax(t_top - hc, ZI_MIN);
            o.zl[l] = zl as f32;
            let rc = allen_r2(1.0, zl);
            o.cand_r[l] = (c.cut * rc) as f32;
            if hk > 0.0 && o.phi[l] > 0.0 {
                o.na[l] = allen_density(zl) as f32;
                // K̄ шаблона пузыря по z_l и w* столба (TB4 v3)
                o.k[l] = bubble_kbar::kbar(zl, ws) as f32;
            }
            // Кандидат: греется (H > 0), поток есть, столб частицы ≥ ZI_MIN, внутри поля (вес края ≥ ½)
            if hk <= 0.0 || o.phi[l] <= 0.0 || d_top < ZI_MIN {
                continue;
            }
            let ctr = [
                (g.x0 + (i as f64 + 0.5) * g.dx) as f32,
                (hc + 10.0) as f32,
                (-(g.y0 + (j as f64 + 0.5) * g.dx)) as f32,
            ];
            if c.f.edge_weight(ctr) < 0.5 {
                continue;
            }
            o.cand.push(col);
        }
    }
    o
}
