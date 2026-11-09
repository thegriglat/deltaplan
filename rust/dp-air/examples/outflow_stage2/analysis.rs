//! Этап 2 (OB4): разбор снимков решения 400 м — эталон R, метрики `eN_*`, `err_hist`, `inc_hist`.
//! Функции принимают срезы [`metrics::slice`] (`[3 высоты][u, v, w][ny][nx]`) и состояния, а не решатель,
//! поэтому проверяются на синтетических полях.
use crate::metrics::{self, AGL_M, Geo};
use picard_rs::state::State;
use serde_json::{Map, Value, json};

/// Параметры разбора.
pub struct Params<'a> {
    pub nx: usize,
    pub ny: usize,
    pub edge: usize,
    pub every: usize,
    pub n_eval: &'a [usize],
    pub late_from: usize,
    pub late_step: usize,
}

/// Номера итераций снимков: every, 2·every, …, предел (max_iters, округлённый вверх до кратного every).
pub fn snap_points(every: usize, max_iters: usize) -> Vec<usize> {
    let every = every.max(1);
    let limit = max_iters.div_ceil(every) * every;
    (every..=limit).step_by(every).collect()
}

/// Снимки позднего среднего: late_from, late_from + step, …, предел.
pub fn late_points(p: &Params, limit: usize) -> Vec<usize> {
    let mut v: Vec<usize> = (p.late_from..=limit).step_by(p.late_step.max(1)).collect();
    if v.last() != Some(&limit) {
        v.push(limit);
    }
    v
}

/// Срез одной высоты (`hi`) из среза трёх высот: `[u, v, w][ny][nx]`.
pub fn height_view(s: &[f32], hi: usize, np: usize) -> &[f32] {
    &s[hi * 3 * np..(hi + 1) * 3 * np]
}

/// Среднее срезов (все высоты и компоненты), в f64 → f32.
pub fn mean_slices(v: &[&[f32]]) -> Vec<f32> {
    let n = v.len() as f64;
    (0..v[0].len())
        .map(|q| (v.iter().map(|s| f64::from(s[q])).sum::<f64>() / n) as f32)
        .collect()
}

/// Результат разбора снимков.
pub struct Analysis {
    /// `converged` | `late_mean`.
    pub ref_kind: &'static str,
    /// Эталон R: срез `[3 высоты][u, v, w][ny][nx]`.
    pub reference: Vec<f32>,
    /// Поля записи: `late_spread_h_p90`, `eN_h_*`, `err_hist`.
    pub fields: Map<String, Value>,
}

/// Снимки `slices[k]` — срезы поля после `pts[k]` итераций (после остановки — итоговое поле),
/// `ok` — решение сошлось (эталон — итоговое поле `last`), иначе эталон — среднее снимков позднего окна.
pub fn analyze(
    slices: &[Vec<f32>],
    pts: &[usize],
    last: &[f32],
    ok: bool,
    p: &Params,
    cells: &[(f64, f64)],
) -> Analysis {
    debug_assert_eq!(pts.first(), Some(&p.every));
    let np = p.nx * p.ny;
    let late = late_points(p, *pts.last().unwrap());
    let late_idx: Vec<usize> = late
        .iter()
        .filter_map(|it| pts.iter().position(|x| x == it))
        .collect();
    let (ref_kind, reference) = if ok {
        ("converged", last.to_vec())
    } else {
        let v: Vec<&[f32]> = late_idx.iter().map(|&k| slices[k].as_slice()).collect();
        ("late_mean", mean_slices(&v))
    };
    let mut f = Map::new();
    for (hi, a) in AGL_M.iter().enumerate() {
        let spread = if ok {
            0.0
        } else {
            let sn: Vec<Vec<f32>> = late_idx
                .iter()
                .map(|&k| height_view(&slices[k], hi, np).to_vec())
                .collect();
            metrics::late_spread_p90(&sn, p.nx, p.ny, p.edge)
        };
        f.insert(format!("late_spread_{}_p90", *a as i64), json!(spread));
    }
    // сравнение каждого снимка с R: [высота] -> Cmp
    let cmp: Vec<[metrics::Cmp; 3]> = slices
        .iter()
        .map(|s| [0, 1, 2].map(|hi| metrics::compare(s, &reference, hi, p.nx, p.ny, p.edge, cells)))
        .collect();
    let start_max = |c: &[metrics::Cmp; 3]| -> Option<f64> {
        c.iter()
            .filter_map(|x| x.start_max)
            .fold(None, |m, v| Some(m.map_or(v, |m: f64| m.max(v))))
    };
    for &n in p.n_eval {
        let k = pts.iter().position(|&x| x == n);
        for (hi, a) in AGL_M.iter().enumerate() {
            let a = *a as i64;
            let c = k.map(|k| &cmp[k][hi]);
            f.insert(
                format!("e{n}_{a}_start_max"),
                json!(c.and_then(|c| c.start_max)),
            );
            f.insert(format!("e{n}_{a}_int_rms"), json!(c.map(|c| c.int_rms)));
            f.insert(format!("e{n}_{a}_int_p99"), json!(c.map(|c| c.int_p99)));
            f.insert(format!("e{n}_{a}_int_max"), json!(c.map(|c| c.int_max)));
        }
    }
    let hist: Vec<Value> = pts
        .iter()
        .zip(&cmp)
        .map(|(it, c)| {
            json!([
                it,
                c[0].int_p99,
                c[1].int_p99,
                c[2].int_p99,
                c[0].int_max,
                c[1].int_max,
                c[2].int_max,
                start_max(c)
            ])
        })
        .collect();
    f.insert("err_hist".into(), Value::Array(hist));
    Analysis {
        ref_kind,
        reference,
        fields: f,
    }
}

/// RMS |Δ(u, v, w)| центров воздушных клеток области без `edge` клеток у края между двумя состояниями
/// (3D, все уровни воздуха), м/с.
pub fn inc3d_rms(g: &Geo, a: &State, b: &State, edge: usize) -> f64 {
    let idx = |k: usize, jh: usize, ih: usize| (k * g.nyh + jh) * g.nxh + ih;
    let (mut acc, mut n) = (0.0f64, 0usize);
    for j in edge..g.ny.saturating_sub(edge) {
        for i in edge..g.nx.saturating_sub(edge) {
            let (jh, ih) = (j + 1, i + 1);
            let k0 = g.kf[jh * g.nxh + ih].max(1) as usize;
            for k in k0..=g.nz {
                let d = |s: &State, t: &State| -> f64 {
                    // разность центров клеток: среднее двух граней
                    let u = 0.5
                        * f64::from(
                            (s.u[idx(k, jh, ih)] - t.u[idx(k, jh, ih)])
                                + (s.u[idx(k, jh, ih + 1)] - t.u[idx(k, jh, ih + 1)]),
                        );
                    let v = 0.5
                        * f64::from(
                            (s.v[idx(k, jh, ih)] - t.v[idx(k, jh, ih)])
                                + (s.v[idx(k, jh + 1, ih)] - t.v[idx(k, jh + 1, ih)]),
                        );
                    let w = 0.5
                        * f64::from(
                            (s.w[idx(k, jh, ih)] - t.w[idx(k, jh, ih)])
                                + (s.w[idx(k + 1, jh, ih)] - t.w[idx(k + 1, jh, ih)]),
                        );
                    u * u + v * v + w * w
                };
                acc += d(a, b);
                n += 1;
            }
        }
    }
    (acc / n.max(1) as f64).sqrt()
}

/// `inc_hist`: на каждый снимок со второго `[it, inc3d_rms, inc10_p99, inc50_p99, inc300_p99, inc_int_max]` —
/// приращение против предыдущего снимка. `eff[k]` — состояние после `pts[k]` итераций (после остановки —
/// итоговое), `slices[k]` — его срез.
pub fn inc_hist(
    g: &Geo,
    eff: &[&State],
    slices: &[Vec<f32>],
    pts: &[usize],
    p: &Params,
) -> Vec<Value> {
    (1..pts.len())
        .map(|k| {
            let c: [metrics::Cmp; 3] = [0, 1, 2].map(|hi| {
                metrics::compare(&slices[k], &slices[k - 1], hi, p.nx, p.ny, p.edge, &[])
            });
            let mx = c.iter().map(|x| x.int_max).fold(0.0, f64::max);
            json!([
                pts[k],
                inc3d_rms(g, eff[k], eff[k - 1], p.edge),
                c[0].int_p99,
                c[1].int_p99,
                c[2].int_p99,
                mx
            ])
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn params(n_eval: &[usize]) -> Params<'_> {
        Params {
            nx: 12,
            ny: 12,
            edge: 5,
            every: 10,
            n_eval,
            late_from: 20,
            late_step: 10,
            // 12 клеток, полоса 5: внутри 2x2
        }
    }

    /// Срез из трёх высот, u = f(высота) везде.
    fn flat(u: [f32; 3]) -> Vec<f32> {
        let np = 144;
        let mut s = vec![0f32; 9 * np];
        for (hi, x) in u.iter().enumerate() {
            s[hi * 3 * np..hi * 3 * np + np].fill(*x);
        }
        s
    }

    #[test]
    fn points_round_up_to_every() {
        assert_eq!(snap_points(10, 300).len(), 30);
        assert_eq!(snap_points(10, 305).last(), Some(&310));
        let p = params(&[]);
        assert_eq!(late_points(&p, 50), vec![20, 30, 40, 50]);
    }

    #[test]
    fn converged_reference_is_last_and_errors_vanish_after_stop() {
        // сошлось на 3-м снимке: снимки 4, 5 = итоговое поле
        let pts = [10, 20, 30, 40, 50];
        let last = flat([1.0, 1.0, 1.0]);
        let sl = vec![
            flat([3.0, 2.0, 1.5]),
            flat([1.5, 1.2, 1.1]),
            last.clone(),
            last.clone(),
            last.clone(),
        ];
        let p = params(&[20, 50]);
        let a = analyze(&sl, &pts, &last, true, &p, &[]);
        assert_eq!(a.ref_kind, "converged");
        assert_eq!(a.fields["late_spread_50_p90"], json!(0.0));
        assert!((a.fields["e20_10_int_max"].as_f64().unwrap() - 0.5).abs() < 1e-6);
        assert_eq!(a.fields["e50_10_int_max"], json!(0.0));
        let h = a.fields["err_hist"].as_array().unwrap();
        assert_eq!(h.len(), 5);
        // err_hist согласуется с eN_*: it = 20 -> e10_p99 = [1], e10_max = [4]
        assert_eq!(h[1][0], json!(20));
        assert_eq!(h[1][1], a.fields["e20_10_int_p99"]);
        assert_eq!(h[1][6], a.fields["e20_300_int_max"]);
        assert_eq!(h[4][4], json!(0.0));
    }

    #[test]
    fn wandering_reference_is_the_late_mean_with_spread() {
        // поздние снимки (20..50) чередуют u = 1, 3: среднее 2, разброс 1
        let pts = [10, 20, 30, 40, 50];
        let sl = vec![
            flat([0.0; 3]),
            flat([1.0; 3]),
            flat([3.0; 3]),
            flat([1.0; 3]),
            flat([3.0; 3]),
        ];
        let p = params(&[10]);
        let a = analyze(&sl, &pts, &sl[4], false, &p, &[]);
        assert_eq!(a.ref_kind, "late_mean");
        assert!((a.reference[0] - 2.0).abs() < 1e-6);
        let sp = a.fields["late_spread_300_p90"].as_f64().unwrap();
        assert!((sp - 1.0).abs() < 1e-6, "{sp}");
        // снимок 10 (u = 0) против R = 2
        assert!((a.fields["e10_50_int_max"].as_f64().unwrap() - 2.0).abs() < 1e-6);
    }

    #[test]
    fn missing_n_gives_null() {
        let pts = [10, 20];
        let sl = vec![flat([0.0; 3]), flat([1.0; 3])];
        let p = params(&[100]);
        let a = analyze(&sl, &pts, &sl[1], true, &p, &[]);
        assert!(a.fields["e100_10_int_p99"].is_null());
    }

    #[test]
    fn increments_between_consecutive_snapshots() {
        use picard_rs::state::State;
        let (nx, ny, nz) = (12usize, 12usize, 3usize);
        let (nxh, nyh, nzh) = (nx + 2, ny + 2, nz + 2);
        let n = nxh * nyh * nzh;
        let mk = |u: f32| State {
            case: String::new(),
            input: String::new(),
            it: 0,
            dims: [nxh, nyh, nzh],
            halo: 1,
            n: [nx, ny, nz],
            u: vec![u; n],
            v: vec![0.0; n],
            w: vec![0.0; n],
            th: vec![0.0; n],
            thd: vec![0.0; n],
            p: vec![0.0; n],
            nu: None,
            nuh: None,
            residuals: None,
        };
        let g = Geo {
            nx,
            ny,
            nz,
            nxh,
            nyh,
            z_bot: 0.0,
            dz: 100.0,
            x0: -2400.0,
            y0: -2400.0,
            dx: 400.0,
            hp: vec![0.0; nxh * nyh],
            kf: vec![1; nxh * nyh],
        };
        let (a, b) = (mk(1.0), mk(3.0));
        assert!((inc3d_rms(&g, &a, &b, 5) - 2.0).abs() < 1e-6);
        assert_eq!(inc3d_rms(&g, &a, &a, 5), 0.0);
        let sl = vec![flat([1.0; 3]), flat([3.0; 3]), flat([3.0; 3])];
        let p = params(&[]);
        let h = inc_hist(&g, &[&a, &b, &b], &sl, &[10, 20, 30], &p);
        assert_eq!(h.len(), 2);
        assert_eq!(h[0][0], json!(20));
        assert!((h[0][1].as_f64().unwrap() - 2.0).abs() < 1e-6);
        assert!((h[0][5].as_f64().unwrap() - 2.0).abs() < 1e-6);
        assert_eq!(h[1][1], json!(0.0));
    }
}
