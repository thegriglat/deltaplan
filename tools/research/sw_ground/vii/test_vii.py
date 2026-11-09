"""pytest sw_ground/vii (SWG-10): равновесие на ровной земле; рост H и предел отрыва для U ∝ x^m против литературы;
обратный ход воспроизводит прямой; слой выключен и σ_d = 0 → potential побитно; Аньези H/L = 0,5 — сходимость
связи и профиль u(z) за гребнем (числа печатаются и пишутся в out/swg-10/agnesi.json)."""
import json

import numpy as np
import pytest

from ground import common as K
from ground import model as M
from vii import bl
from vii import core as V
from wake import synth as S

OUT = K.SG / "out" / "swg-10"


def _power_law(m, z0=0.1, x0=3000.0, L=30000.0):
    eq = bl.Equilibrium(z0, 500.0, 10.0)
    eq.S_m = eq.S_e = 0.0                       # пластина без стоков равновесия АПС (лабораторная постановка)
    s = np.arange(0.0, L, 12.5)[None]
    U = 10.0 * ((x0 + s) / x0) ** m
    dU = m * U / (x0 + s)
    return bl.march(s, U, dU, np.ones_like(s, bool), eq, htmax=99.0), s


def test_flat_equilibrium_march():
    for z0 in (0.03, 1.8):
        eq = bl.Equilibrium(z0, 500.0, 9.0)
        s = np.arange(0.0, 8000.0, 12.5)[None]
        U = np.full_like(s, 9.0)
        r = bl.march(s, U, 0 * U, np.ones_like(s, bool), eq)
        assert np.max(np.abs(r["theta"] / eq.theta0 - 1)) < 1e-9 and np.max(np.abs(r["a"] - 1)) < 1e-9
        assert abs(eq.H0 - eq.lam0 / (eq.lam0 - 2)) < 1e-3          # чистый лог: H = λ/(λ − 2)


def test_power_law_separation_limit():
    """U ∝ (x0 + s)^m: предел прямого хода (H ≥ HTMAX = 2,5 в пределах 10·x0) против m_sep ≈ −0,216 − 0,4·Re_p^−1/3
    (Vigdorovich 2014, JETP 119:961, гладкая стенка, Re → ∞). Шероховатая стенка (z0 = 0,1 м, λ0 = 8,5)."""
    def sep(m):
        r, s = _power_law(m)
        return bool(np.nanmax(r["H"]) >= bl.HTMAX)
    lo, hi = -0.6, -0.02                     # lo — отрыв, hi — нет
    assert sep(lo) and not sep(hi)
    for _ in range(14):
        mid = 0.5 * (lo + hi)
        lo, hi = (mid, hi) if sep(mid) else (lo, mid)
    m_crit = 0.5 * (lo + hi)
    r, _ = _power_law(-0.1)
    H = r["H"][0]
    assert np.all(np.diff(H[:241]) > 0) and H[240] > H[0] + 0.02     # неблагоприятный градиент — H растёт (первые x0)
    assert np.nanmax(H) < bl.HTMAX                                    # слабый градиент — к равновесному H, без отрыва
    print("m_crit", m_crit)
    OUT.mkdir(parents=True, exist_ok=True)
    _merge(dict(power_law=dict(m_crit=m_crit, literature=-0.216, z0=0.1, criterion="H >= 2.5 (XFOIL HTMAX)")))
    assert -0.35 < m_crit < -0.12


def test_inverse_reproduces_direct():
    """Обратный ход с δ* прямого хода восстанавливает U_e (непротиворечивость обратной постановки)."""
    r, s = _power_law(-0.15, L=12000.0)
    inv = np.ones_like(r["dstar"], bool)
    U = 10.0 * ((3000.0 + s) / 3000.0) ** -0.15
    eq = bl.Equilibrium(0.1, 500.0, 10.0)
    eq.S_m = eq.S_e = 0.0
    r2 = bl.march(s, U, -0.15 * U / (3000.0 + s), np.ones_like(s, bool), eq, r["dstar"], inv)
    assert np.nanmax(np.abs(r2["U"] / U - 1)) < 0.02


def _merge(d):
    f = OUT / "agnesi.json"
    old = json.load(open(f)) if f.exists() else {}
    old.update(d)
    K.dump_json(f, old)


@pytest.fixture(scope="module")
def flat():
    return S.agnesi_run(H=0.0, ds_min=50.0, hx=1500.0, hy=1500.0, focus_x=np.array([0.0]), backend="numpy")


def test_flat_ground_profile_equals_background(flat):
    r = flat
    vi = V.VII(r)
    res = vi.run_layer()
    assert res["converged"] and np.nanmax(np.abs(res["layer"]["a"] - 1)) < 1e-6
    lf = V.LayerField(vi.strips, res["layer"], vi.z0)
    xs = np.array([-500.0, 0.0, 500.0])
    for zagl in (10.0, 50.0, 300.0):
        z = r.panels.height(xs, 0 * xs) + zagl
        pv = V.vii_parts(r, xs, 0 * xs, z, vi.sig_d, lf, vi.sig_u, vi.U_inf)
        pj = M.jh_parts(r, xs, 0 * xs, z)
        assert np.max(np.abs(pv["speed"] / pj["speed"] - 1)) < 0.01


def test_layer_off_zero_blowing_bitwise(flat):
    r = flat
    xs = np.array([-300.0, 0.0, 300.0])
    for zagl in (10.0, 50.0, 300.0):
        z = r.panels.height(xs, 0 * xs) + zagl
        pj = M.jh_parts(r, xs, 0 * xs, z)
        pv = V.vii_parts(r, xs, 0 * xs, z, np.zeros(r.panels.N), None)
        assert np.array_equal(pv["speed"], pj["pot_speed"])


def _agnesi_case(r, omega, d_smooth):
    vi = V.VII(r, omega=omega, d_smooth=d_smooth)
    res = vi.run_layer()
    st = vi.strips
    ic = int(np.argmin(np.abs(st.cvals)))
    L = res["layer"]
    lf = V.LayerField(st, L, vi.z0)
    prof = {}
    for x in (150.0, 300.0, 450.0, 600.0, 900.0):
        zz = np.array([10.0, 20.0, 50.0, 100.0])
        X = np.full(zz.size, x)
        z = r.panels.height(X, 0 * X) + zz
        pv = V.vii_parts(r, X, 0 * X, z, vi.sig_d, lf, vi.sig_u, vi.U_inf)
        prof[f"{x:g}"] = (pv["speed"] * pv["upar_sign"] / vi.U_inf).tolist()
    h = res["hist"][-1]
    out = dict(omega=omega, d_smooth=d_smooth, converged=res["converged"], iters=len(res["hist"]),
               dmax_last=h["dmax"], n_bad_last=h["n_bad"], n_inv_last=h["n_inv"],
               H_max=float(np.nanmax(L["H"][ic])), cf_min=float(np.nanmin(L["cf"][ic])),
               separated=bool(np.nanmin(L["cf"][ic]) <= 0), profiles_over_Uinf=prof,
               centerline=dict(x=st.X[ic][::8].tolist(), H=np.nan_to_num(L["H"][ic, ::8]).tolist(),
                               cf=np.nan_to_num(L["cf"][ic, ::8]).tolist(),
                               Ui=np.nan_to_num(res["Ui"][ic, ::8] / vi.U_inf).tolist()))
    return out, vi, res


def test_agnesi_separation_convergence():
    """Хребет Аньези H = 125 м, a = 250 м (H/L = 0,5), z0 = 0,1 м. (1) Литературная релаксация Carter ω = 0,5 без
    сглаживания — связь сходится (max|Δδ*|/δ* < 1e-3); (2) рабочий набор (ω = 0,2, сглаживание δ* 50 м) — число и
    смещение u(z) против (1) записываются (оценка смещения стабилизатора). Числа отрыва и u(z) — в agnesi.json."""
    r = S.agnesi_run(ds_min=25.0, focus_x=np.arange(-600.0, 1201.0, 150.0), backend="numpy")
    lit, vi, res = _agnesi_case(r, bl.OMEGA, 0.0)
    work, _, _ = _agnesi_case(r, V.OMEGA_RUN, V.D_SMOOTH)
    nc = V.VII(r).run_layer(coupled=False)
    st = vi.strips
    ic = int(np.argmin(np.abs(st.cvals)))
    lf0 = V.LayerField(st, nc["layer"], vi.z0)
    prof_nc, prof_jh = {}, {}
    for x in (150.0, 300.0, 450.0, 600.0, 900.0):
        zz = np.array([10.0, 20.0, 50.0, 100.0])
        X = np.full(zz.size, x)
        z = r.panels.height(X, 0 * X) + zz
        p0 = V.vii_parts(r, X, 0 * X, z, None, lf0, vi.sig_u, vi.U_inf)
        pj = M.jh_parts(r, X, 0 * X, z)
        prof_nc[f"{x:g}"] = (p0["speed"] * p0["upar_sign"] / vi.U_inf).tolist()
        prof_jh[f"{x:g}"] = (pj["speed"] / vi.U_inf).tolist()
    bias = max(abs(a - b) for k in lit["profiles_over_Uinf"] for a, b in zip(lit["profiles_over_Uinf"][k],
                                                                            work["profiles_over_Uinf"][k]))
    out = dict(z=[10.0, 20.0, 50.0, 100.0], literature=lit, working=work, max_abs_bias_over_Uinf=bias,
               uncoupled=dict(H_max=float(np.nanmax(nc["layer"]["H"][ic])), cf_min=float(np.nanmin(nc["layer"]["cf"][ic])),
                              profiles_over_Uinf=prof_nc),
               potential_jh=dict(profiles_over_Uinf=prof_jh))
    _merge(dict(agnesi=out))
    print({k: lit[k] for k in ("converged", "iters", "H_max", "cf_min", "separated")},
          {k: work[k] for k in ("converged", "iters", "dmax_last", "n_bad_last")}, "bias", bias)
    assert lit["converged"]
    assert all(np.all(np.isfinite(v)) for v in lit["profiles_over_Uinf"].values())
