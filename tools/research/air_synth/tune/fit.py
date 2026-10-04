"""Шаг 3: полиномы наблюдаемых по θ (среднее по зёрнам), подгонка θ к КАЖДОМУ реальному квадрату,
облако out/theta_cloud.json, eigentunes, out/tune_summary.json.
Запуск: ../corpus/.venv/bin/python fit.py [--deg 2]"""
import argparse, json, os, sys
import numpy as np
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import tunelib as T  # noqa: E402
import observables as ob  # noqa: E402

OUT = os.environ.get("SY5_OUT", os.path.join(HERE, "out"))
SIG_FLOOR = 1e-3


def load_runs(names):
    D = json.load(open(os.path.join(OUT, "design.json")))
    runs = [json.loads(l) for l in open(os.path.join(OUT, "runs.jsonl"))]
    P = D["n_points"]
    Y = {}
    for r in runs:
        Y.setdefault(r["point"], []).append([r["obs"][n] if r["obs"][n] is not None else np.nan for n in names])
    pts = sorted(p for p, v in Y.items() if len(v) >= 2)
    return D, pts, [np.array(Y[p], float) for p in pts]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--deg", type=int, default=2)
    a = ap.parse_args()
    names = ob.NAMES
    ref = json.load(open(os.path.join(OUT, "ref_obs.json")))
    D, pts, Ys = load_runs(names)
    U = np.array(D["U"])[pts]
    dim = U.shape[1]
    # nan (например saddle_km при <3 вершинах): среднее по зёрнам без nan; точка без значения — выпадает из подгонки этой наблюдаемой
    M = np.array([np.nanmean(y, 0) for y in Ys])
    nseed = np.array([np.sum(np.isfinite(y), 0) for y in Ys])
    var_w = np.array([np.nanvar(y, 0, ddof=1) for y in Ys])           # дисперсия по зёрнам в точке
    sig_gen = np.sqrt(np.nanmean(var_w, 0))                           # шум одной реализации генератора, усреднён по точкам
    ok_cols = np.isfinite(M).all(0)
    # полиномы по каждой наблюдаемой отдельно, чтобы nan в одной не ломал остальные
    sur_cols = {}
    loo = np.full(len(names), np.nan)
    coefs = {}
    for j, n in enumerate(names):
        m = np.isfinite(M[:, j])
        if m.sum() < 60:
            continue
        s = T.Surrogate(U[m], M[m, j:j + 1], a.deg)
        sur_cols[j] = s
        loo[j] = s.loo_rms[0]
    from professor_core import design, monomials
    mons = monomials(dim, a.deg)
    CO = np.full((len(mons), len(names)), np.nan)
    for j, s_ in sur_cols.items():
        CO[:, j] = s_.coef[:, 0]

    class Sur:
        def __call__(self, u):
            return design(np.atleast_2d(u), mons) @ CO
    sur = Sur()
    # диапазон достижимости: min/max средних по точкам
    rmin, rmax = np.nanmin(M, 0), np.nanmax(M, 0)
    sq = ref["squares"]
    dsys = np.array(ref["detail_minus_far_center"]["std"])
    dmean = np.array(ref["detail_minus_far_center"]["mean"])
    dsys = np.sqrt(dsys ** 2 + dmean ** 2)                             # систематика detail/far — в неопределённость эталона
    sigma = np.sqrt(sig_gen ** 2 + loo ** 2 + dsys ** 2 + SIG_FLOOR ** 2)
    fits = []
    # T (t_total_yr) — одно для всего облака: сетка по u_T, на каждом узле подгонка остальных θ к каждому квадрату (мало стартов),
    # выбор u_T с минимальной суммой χ², затем окончательная подгонка при этом T.
    squares = [r for r in sq if r["kind"] != "far_center"]   # far_center — дубль участка detail, только для сравнения источников
    Yq = [np.array([r["obs"][n] if r["obs"][n] is not None else np.nan for n in names], float) for r in squares]
    fixed = {}
    T_scan = None
    if "t_total_yr" in D["names"]:
        kT = D["names"].index("t_total_yr")
        grid = np.linspace(-1, 1, 9)
        tot = []
        for uT in grid:
            tot.append(sum(T.fit_one(sur, y, sigma, dim, starts=4, fixed={kT: uT})[1] for y in Yq))
            print(f"u_T {uT:+.2f} sum chi2 {tot[-1]:.0f}", flush=True)
        i = int(np.argmin(tot)); lo_, hi_ = grid[max(i - 1, 0)], grid[min(i + 1, 8)]
        grid2 = np.linspace(lo_, hi_, 5)
        tot2 = [sum(T.fit_one(sur, y, sigma, dim, starts=4, fixed={kT: uT})[1] for y in Yq) for uT in grid2]
        uT = float(grid2[int(np.argmin(tot2))])
        fixed = {kT: uT}
        T_scan = dict(grid=grid.tolist(), sum_chi2=tot, refine_grid=grid2.tolist(), refine_sum_chi2=tot2, u_T=uT)
    for r, y in zip(squares, Yq):
        u, chi2, res, ndf = T.fit_one(sur, y, sigma, dim, fixed=fixed)
        fits.append(dict(name=r["name"], kind=r["kind"], place=r["place"], u=u.tolist(), chi2=chi2, ndf=ndf, res=res.tolist(),
                         y=y.tolist(), at_bound=bool((np.abs(u) > 0.999).any())))
        print(f"{r['name']:20s} chi2/ndf {chi2:7.1f}/{ndf}", flush=True)
    sp = T.Space(dict(zip(D["names"], zip(D["lo"], D["hi"], [1.0] * dim))))
    R = np.array([f["res"] for f in fits])
    chi2_obs = np.nanmean(R ** 2, 0)                                   # средний вклад наблюдаемой в χ² на квадрат (≈1 — хорошо)
    rms_obs = np.sqrt(chi2_obs)
    out_of_range = []
    for j, n in enumerate(names):
        ys = np.array([f["y"][j] for f in fits])
        frac_out = float(np.mean((ys < rmin[j] - 2 * sigma[j]) | (ys > rmax[j] + 2 * sigma[j])))
        out_of_range.append(frac_out)
    res_mean = np.nanmean(R, 0)                                        # знаковое смещение (генератор − эталон)/σ: >0 — у эталона больше... см. README
    unreachable = [n for j, n in enumerate(names) if chi2_obs[j] > 3 or out_of_range[j] > 0.1 or abs(res_mean[j]) > 0.5]
    # облако
    ndfs = np.array([f["ndf"] for f in fits]); chis = np.array([f["chi2"] for f in fits])
    pts_theta = [sp.from_u(f["u"]).tolist() for f in fits]
    w = np.clip(ndfs / np.maximum(chis, 1e-9), 0.05, 1.0)
    cloud = dict(names=D["names"], points=pts_theta, weights=w.tolist(),
                 source=f"SY-5 Professor deg{a.deg}: подгонка к каждому реальному квадрату (4 detail + 64 far), генератор {D['generator']}")
    json.dump(cloud, open(os.path.join(OUT, "theta_cloud.json"), "w"), indent=1)
    # eigentunes: подгонка к среднему эталону каждого места, cov по якобиану
    eig = {}
    for place in sorted({f["place"] for f in fits}):
        Fp = [f for f in fits if f["place"] == place]
        Yp = np.array([f["y"] for f in Fp])
        ym = np.nanmean(Yp, 0)
        sd_place = np.nanstd(Yp, 0, ddof=1)
        sg = np.sqrt(sig_gen ** 2 / len(Fp) + loo ** 2 + dsys ** 2 + SIG_FLOOR ** 2 + 0 * sd_place)
        u, chi2, res, ndf = T.fit_one(sur, ym, sg, dim, fixed=fixed)
        okm = np.isfinite(ym) & np.isfinite(sg)
        cov = T.chi2_cov(sur, u, sg, okm)
        if fixed:
            kk = list(fixed)[0]; cov[kk, :] = 0; cov[:, kk] = 0
        lam, V = T.eigentunes(cov)
        eig[place] = dict(u=u.tolist(), theta=sp.from_u(u).tolist(), chi2=chi2, ndf=ndf,
                          sigma_u=np.sqrt(np.diag(cov)).tolist(), eigenvalues=lam.tolist(), eigenvectors=V.T.tolist(),
                          eigentune_points=[sp.from_u(np.clip(u + s * np.sqrt(max(l, 0)) * v, -1, 1)).tolist()
                                            for l, v in zip(lam, V.T) for s in (-1, 1)])
    qs = [5, 25, 50, 75, 95]
    P = np.array(pts_theta)
    summ = dict(names=names, deg=a.deg, generator=D["generator"], n_points=len(pts), n_seeds=D["n_seeds"], tunable=D["names"],
                sigma=dict(zip(names, sigma.tolist())), sigma_gen=dict(zip(names, sig_gen.tolist())), loo_rms=dict(zip(names, loo.tolist())),
                sigma_detail_far=dict(zip(names, dsys.tolist())),
                chi2_per_observable=dict(zip(names, chi2_obs.tolist())), mean_signed_residual=dict(zip(names, res_mean.tolist())),
                n_squares_at_param_bound=int(sum(f['at_bound'] for f in fits)),
                frac_at_bound_per_param={n: float(np.mean([abs(f['u'][i]) > 0.999 for f in fits])) for i, n in enumerate(D['names'])}, frac_squares_out_of_range=dict(zip(names, out_of_range)),
                unreachable_observables=unreachable,
                chi2_per_square={f["name"]: dict(chi2=f["chi2"], ndf=f["ndf"], at_bound=f["at_bound"]) for f in fits},
                chi2_ndf_median=float(np.median(chis / ndfs)),
                cloud_quantiles={n: dict(zip(map(str, qs), np.percentile(P[:, i], qs).tolist())) for i, n in enumerate(D["names"])},
                eigentunes=eig, T_scan=T_scan)
    json.dump(summ, open(os.path.join(OUT, "tune_summary.json"), "w"), indent=1)
    print("median chi2/ndf", summ["chi2_ndf_median"], "unreachable:", unreachable)


if __name__ == "__main__":
    main()
