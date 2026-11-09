"""pytest sw_ground/vii2 (SWG-11): ровная земля — равновесие и поле = potential_jh ±1 %; слой выключен и σ_d = 0 —
potential побитно; линейный оператор связи против разностной производной; Аньези H/L 0,5 — сходимость Ньютона, отрыв
(C_f < 0: положение, длина), u(z) 10–100 м за гребнем; Ньютон против явной Carter (vii, SWG-10) на пологом Аньези
и на Askervein (raw/carter_ASK.json, стадия `run carter`). Числа — out/swg-11/agnesi.json."""
import json

import numpy as np
import pytest

from ground import common as K
from ground import model as M
from vii import bl
from vii import core as V
from vii2 import core as W
from wake import synth as S

OUT = K.SG / "out" / "swg-11"
XS = (150.0, 300.0, 450.0, 600.0, 900.0)
ZZ = (10.0, 20.0, 50.0, 100.0)


def _merge(d):
    f = OUT / "agnesi.json"
    OUT.mkdir(parents=True, exist_ok=True)
    old = json.load(open(f)) if f.exists() else {}
    old.update(d)
    from vii2.run import clean
    K.dump_json(f, clean(old))


@pytest.fixture(scope="module")
def flat():
    r = S.agnesi_run(H=0.0, ds_min=50.0, hx=1500.0, hy=1500.0, focus_x=np.array([0.0]), backend="auto")
    vi = W.VII2(r)
    res = vi.solve()
    return r, vi, res


def test_flat_equilibrium_and_jh(flat):
    r, vi, res = flat
    assert res["converged"] and res["rmax"] < W.TOL and res["iters_total"] <= 10
    assert np.max(np.abs(vi.a - 1)) < 1e-6 and np.max(np.abs(vi.lam - vi.eq.lam0)) < 1e-6
    lf = V.LayerField(vi.strips, vi.layer_grid(), vi.z0)
    xs = np.array([-500.0, 0.0, 500.0])
    for zagl in (10.0, 50.0, 300.0):
        z = r.panels.height(xs, 0 * xs) + zagl
        pv = W.vii2_parts(r, xs, 0 * xs, z, vi.sig_d, lf)
        pj = M.jh_parts(r, xs, 0 * xs, z)
        assert np.max(np.abs(pv["speed"] / pj["speed"] - 1)) < 0.01


def test_layer_off_zero_blowing_bitwise(flat):
    r = flat[0]
    xs = np.array([-300.0, 0.0, 300.0])
    for zagl in (10.0, 50.0, 300.0):
        z = r.panels.height(xs, 0 * xs) + zagl
        pj = M.jh_parts(r, xs, 0 * xs, z)
        pv = W.vii2_parts(r, xs, 0 * xs, z, None, None)
        assert np.array_equal(pv["speed"], pj["pot_speed"])


@pytest.fixture(scope="module")
def agnesi():
    r = S.agnesi_run(ds_min=25.0, hy=1500.0, focus_x=np.arange(-600.0, 1201.0, 150.0), backend="auto")
    vi = W.VII2(r)
    res = vi.solve()
    return r, vi, res


def test_coupling_operator_linear(agnesi):
    """G_lin (связь в якобиане) = разностная производная точного U_e(σ_d(m)) по m (до 1e-5 отн.)."""
    r, vi, _ = agnesi
    m = vi.m
    _, Ut = vi.surf(vi.sigma_of_m(m))
    that = Ut / np.linalg.norm(Ut, axis=1, keepdims=True)
    rng = np.random.default_rng(0)
    dm = vi.smooth(rng.standard_normal(m.size)) * 0.01 * np.abs(m).mean()
    lin = vi.G_lin(dm, that)
    up = vi.surf(vi.sigma_of_m(m + dm))[0]
    dn = vi.surf(vi.sigma_of_m(m - dm))[0]
    fd = 0.5 * (up - dn)
    assert np.max(np.abs(lin - fd)) < 1e-5 * np.max(np.abs(fd)) + 1e-12


def test_agnesi_newton_separation(agnesi):
    """Аньези H = 125 м, a = 250 м (H/L = 0,5), z0 = 0,1 м: Ньютон сходится; отрыв (C_f < 0) — положение и длина;
    u(z) 10–100 м за гребнем против potential_jh."""
    r, vi, res = agnesi
    st, om = vi.strips, vi.om
    ic = int(np.argmin(np.abs(st.cvals)))
    li = [k for k, ln in enumerate(om.lines) if ln[0] == ic][0]
    _, i0, n, o = om.lines[li]
    x = st.X[ic, i0:i0 + n]
    sv = bl.state(vi.a[o:o + n], vi.lam[o:o + n], vi.z0)
    cf = 2 * sv["cf2"]
    sep = np.nonzero((cf < 0) & (x > 0))[0]
    lf = V.LayerField(st, vi.layer_grid(), vi.z0)
    prof, prof_jh, prof_pot = {}, {}, {}
    for xx in XS:
        zz = np.array(ZZ)
        X = np.full(zz.size, xx)
        z = r.panels.height(X, 0 * X) + zz
        pv = W.vii2_parts(r, X, 0 * X, z, vi.sig_d, lf)
        pj = M.jh_parts(r, X, 0 * X, z)
        prof[f"{xx:g}"] = (pv["speed"] * pv["upar_sign"] / vi.U_l).tolist()
        prof_jh[f"{xx:g}"] = (pj["speed"] / vi.U_l).tolist()
        prof_pot[f"{xx:g}"] = (pj["pot_speed"] / vi.U_l).tolist()
    out = dict(H=125.0, a=250.0, z0=vi.z0, delta0=vi.delta0, L_rule=vi.L_rule, U_l=vi.U_l, converged=res["converged"],
               newton_iters_final=res["iters_final"], newton_iters_total=res["iters_total"], rmax=res["rmax"],
               branch_eps=res["branch_eps"], n_active=int(vi.active.sum()),
               hist=[{k: h.get(k) for k in ("phase", "eps", "it", "rmax", "n_bad_lines", "n_sep", "H_max", "n_active",
                                            "gmres_it", "rlx_min")} for h in res["hist"]],
               separated=bool(sep.size), x_sep=float(x[sep[0]]) if sep.size else None,
               x_reatt=float(x[sep[-1]]) if sep.size else None,
               sep_len=float(x[sep[-1]] - x[sep[0]] + st.step) if sep.size else 0.0,
               cf_min=float(cf[x > 0].min()), H_max=float(sv["H"].max()),
               z=list(ZZ), x=list(XS), u_over_Ul=prof, potential_jh=prof_jh, potential=prof_pot,
               centerline=dict(x=x[::4].tolist(), H=sv["H"][::4].tolist(), cf=cf[::4].tolist(),
                               delta=sv["delta"][::4].tolist(), U=(vi.U[o:o + n][::4] / vi.U_l).tolist(),
                               U_inv=(vi.U_inv[o:o + n][::4] / vi.U_l).tolist()))
    _merge(dict(agnesi=out))
    print({k: out[k] for k in ("converged", "newton_iters_final", "rmax", "separated", "x_sep", "x_reatt", "cf_min", "H_max")})
    assert res["converged"]
    assert all(np.all(np.isfinite(v)) for v in prof.values())


def test_newton_vs_carter_gentle():
    """Пологий Аньези (H = 40 м, H/L = 0,16): явная Carter (vii, SWG-10: ω = 0,5, без сглаживания δ*) на том же тонком
    слое сходится; решение Ньютона совпадает (δ*, U_e — до 1 %: разные разностные схемы — RK2 против трапеции)."""
    r = S.agnesi_run(H=40.0, ds_min=25.0, hy=1500.0, focus_x=np.arange(-600.0, 1201.0, 150.0), backend="auto")
    vi = W.VII2(r, fine=False)                  # у Carter (vii) нет подсеточного закона — сравнение без него
    res = vi.solve()
    vc = V.VII(r, strips=vi.strips, delta0=vi.delta0, omega=bl.OMEGA, d_smooth=0.0)
    rc = vc.run_layer(coupled=True, k_max=80, tol=1e-5)
    om = vi.om
    dsc = rc["layer"]["dstar"][om.node_ic, om.node_is]
    Uc = rc["layer"]["U"][om.node_ic, om.node_is]
    ok = np.isfinite(dsc + Uc)
    ds2 = bl.state(vi.a, vi.lam, vi.z0)["dstar"]
    r_ds = np.abs(dsc[ok] / ds2[ok] - 1)
    r_U = np.abs(Uc[ok] / vi.U[ok] - 1)
    e_ds, e_U = float(r_ds.max()), float(r_U.max())
    st_ = dict(dstar_rel=dict(mean=float(r_ds.mean()), p99=float(np.percentile(r_ds, 99)), max=e_ds),
               U_rel=dict(mean=float(r_U.mean()), p99=float(np.percentile(r_U, 99)), max=e_U))
    _merge(dict(carter_gentle=dict(H=40.0, newton_iters=res["iters_final"], newton_conv=res["converged"],
                                   H_max=float(bl.state(vi.a, vi.lam, vi.z0)["H"].max()),
                                   carter_iters=len(rc["hist"]), carter_conv=rc["converged"],
                                   n=int(ok.sum()), **st_)))
    print("Carter", rc["converged"], len(rc["hist"]), "Newton", res["converged"], res["iters_final"], st_)
    assert res["converged"] and rc["converged"]
    # в среднем совпадают; p99/max (RK2 против трапеции, разные отрезки профилей у края растра) — в README
    assert st_["dstar_rel"]["mean"] < 0.01 and st_["U_rel"]["mean"] < 0.01 and st_["U_rel"]["p99"] < 0.02


def test_goldstein_stall_without_cap():
    """Без предела HTMAX (та же система, H свободен): продолжение по рельефу останавливается до ε = 1 в точке, где у
    семейства Coles + Хед dH1/dH = 0 (аналог сингулярности Голдстейна), при C_f > 0. Записывается ε, H, H1 остановки
    (Аньези H/L 0,5; сетка ds_min 50 м — дешевле основной)."""
    r = S.agnesi_run(H=125.0, ds_min=50.0, hx=1500.0, hy=1000.0, focus_x=np.arange(-600.0, 1201.0, 150.0), backend="auto")
    vi = W.VII2(r, cap=False)
    res = vi.solve(newton_max=3, ds_min=0.02)   # остановка грубее (шаг дуги 0,02): тест дешевле
    x, e = vi.branch[-1]
    a, lam, _ = vi._unpack(x)
    st = bl.state(a, lam, vi.z0)
    k = int(np.argmax(st["H"]))
    # H1 вдоль a при том же λ: минимум H1 по a (точка dH1/dH = 0)
    aa = np.linspace(0.05, 1.0, 400)
    s2 = bl.state(aa, np.full(aa.size, lam[k]), vi.z0)
    out = dict(eps_stall=float(e), reached=bool(e >= 1.0), converged_eps1=res["converged"], H_stall=float(st["H"][k]),
               a_stall=float(a[k]), H1_stall=float(st["H1"][k]), cf_stall=float(2 * st["cf2"][k]),
               H1_min_family=float(s2["H1"].min()), H_at_H1_min=float(s2["H"][np.argmin(s2["H1"])]),
               n_sep_stall=int((st["cf2"] < 0).sum()), branch_eps=res["branch_eps"])
    _merge(dict(goldstein_stall=out))
    print(out)
    assert not out["reached"] and out["cf_stall"] > 0


def test_newton_vs_carter_askervein():
    """Askervein (стадия `run carter`): Ньютон и явная Carter на одном тонком слое — совпадение δ*, U_e."""
    f = OUT / "raw" / "carter_ASK.json"
    if not f.exists():
        pytest.skip("нет raw/carter_ASK.json (py -m vii2.run carter)")
    d = json.load(open(f))
    assert d["newton"]["converged"] and d["carter"]["converged"]
    # в среднем совпадают (разные разностные схемы и отрезки профилей); p99/max — в README
    assert d["dstar_rel"]["mean"] < 0.01 and d["U_rel"]["mean"] < 0.01 and d["U_rel"]["p99"] < 0.02
