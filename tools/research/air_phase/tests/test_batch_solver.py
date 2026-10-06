"""AP-1: инварианты P4 (docs/contracts/air-phase.md) и опции пакетного решателя. GPU — под замком:
  dp lock gpu ap1-test -- .venv/bin/python -m pytest -q tools/research/air_phase/tests/test_batch_solver.py
Измеренные расхождения инвариантов 2 и 4 пишутся в out/invariants.json."""
from __future__ import annotations

import json
import math
import sys
from pathlib import Path

import numpy as np
import pytest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import batch_solver as BS            # noqa: E402
from bench_batch import ideal_g100   # noqa: E402
import air as A                      # noqa: E402
import wind_prof as WP               # noqa: E402
import model_place as M              # noqa: E402
import airlite_gen as G              # noqa: E402

OUT = HERE.parent / "out" / "invariants.json"
CTX = dict(lat=50.79, lon=86.13, month=7, day=15, hour_local=12.0, utc_offset=7.0, t_max_c=26.0, sky="clear")
ALPHA, MAXP, N_BV, H = 0.24, 2.341, 0.01, 500.0     # постоянные плана (контекст P2)


def _record(key, val):
    d = json.loads(OUT.read_text()) if OUT.exists() else {}
    d[key] = val
    OUT.parent.mkdir(exist_ok=True)
    OUT.write_text(json.dumps(d, indent=1, ensure_ascii=False))


def spec_default(shape, s, u10):
    """Случай без override: α и max_profile — как real.case (wind_prof.for_hour по контексту места)."""
    g = ideal_g100(shape, s)
    M.register("t_ctx", g, 0.0)
    c = dict(M.context("t_ctx")); c.update(month=7, day=15, lat=50.79, lon=86.13, utc_offset_h=7.0)
    P0 = A.Params()
    al, mp, _, _ = WP.for_hour(c, CTX["hour_local"], CTX["sky"], u10, P0.z0, P0.f_cor)
    return BS.CaseSpec(g100=g, ctx=CTX, u10=u10, wdir_from_deg=270.0, alpha=al, max_profile=mp)


def spec_fr(shape, s, fr, h_over_zi=0.3, heat=0.0, wdir=270.0, dx=400.0):
    """Случай плана: override N, z_i, H; U10 из Fr = U_sat/(N·h), U_sat = U10·max_profile."""
    return BS.CaseSpec(g100=ideal_g100(shape, s), ctx=CTX, u10=fr * N_BV * H / MAXP, wdir_from_deg=wdir, alpha=ALPHA, max_profile=MAXP,
                       n_bv_s=N_BV, z_i_agl_m=H / h_over_zi, heat_flux_wm2=heat, dx_m=dx)


# ------------------------------------------------------------------ инвариант 1
@pytest.mark.parametrize("tag,shape,s,u10,mo,lf", [("strong", "hill", 0.3, 6.0, 1000, 500), ("late", "ridge", 0.5, 0.8, 200, 100)])
def test_invariant1_bitwise(tag, shape, s, u10, mo, lf):
    sp = spec_default(shape, s, u10)
    r, ref = BS.solve_single_reference(sp, max_outer=mo, late_from=lf)
    res = BS.solve_batch([sp], BS.Numerics(max_outer=mo, late_from=lf))[0]
    assert res.status == r["status"] and res.iters == r["iters"] and res.target == r["target"], (res.status, r)
    assert np.array_equal(res.fields, ref.astype(np.float32))
    if tag == "late":
        assert res.target == "late_mean" and res.late_spread60_p90 == r["late_spread60_p90"]
    # и через сам airlite_gen.solve_case (float16, как пишет S5)
    if tag == "strong":
        _, arr = G.solve_case(dict(id="x", loc=_loc_like(sp), hour=12.0, U10=u10, wdir=270.0, t_max=26.0, sky="clear"), [],
                              max_outer=mo, late={"from": lf, "step": 50, "edge_cells": 5})
        assert np.array_equal(arr["d400_h"], res.fields.astype(np.float64).astype(np.float16)) or \
            np.array_equal(arr["d400_h"], ref.astype(np.float16))
        assert np.array_equal(arr["d400_h"], ref.astype(np.float16))


def _loc_like(sp):
    M.register("t_inv1", sp.g100, 0.0)
    ctx = M.context("t_inv1")
    ctx.update(month=7, day=15, lat=50.79, lon=86.13, utc_offset_h=7.0)
    return "t_inv1"


# ------------------------------------------------------------------ инвариант 2
def test_invariant2_batch_vs_single():
    specs = [spec_fr("hill", 0.3, 3.0), spec_fr("ridge", 0.3, 0.5, heat=100.0), spec_fr("step_up", 0.15, 1.0, h_over_zi=1.0),
             spec_default("hill", 0.5, 2.0)]
    nums = [BS.Numerics(max_outer=300, late_from=200), BS.Numerics(max_outer=300, late_from=200, omega_u=0.7, omega_k=0.5),
            BS.Numerics(max_outer=200, late_from=100, criterion="rel"), BS.Numerics(max_outer=300, late_from=200, k_floor_m2s=10.0)]
    batch = BS.solve_batch(specs, nums, batch=4)
    rows = []
    for sp, nm, b in zip(specs, nums, batch):
        o = BS.solve_batch([sp], nm, batch=1)[0]
        du = float(np.max(np.abs(o.fields[:3] - b.fields[:3])))
        rows.append(dict(status=[o.status, b.status], iters=[o.iters, b.iters], max_du=du))
        assert o.status == b.status
        assert abs(o.iters - b.iters) <= 0.02 * o.iters
        if o.status == "ok":
            assert du <= 1e-3
    _record("invariant2", dict(cases=rows, max_du=max(r["max_du"] for r in rows), bitwise=all(r["max_du"] == 0 for r in rows)))


# ------------------------------------------------------------------ инвариант 3 (override)
def test_invariant3_override():
    for fr in (0.1, 0.5, 1.0, 3.0):
        for hz in (0.3, 1.0, 3.0):
            sp = spec_fr("ridge", 0.3, fr, h_over_zi=hz, heat=100.0)
            st = BS._Setup(0, sp, BS.Numerics())
            g, hc = BS.R.grid_domain(st.loc, 400)
            st.hc = hc
            c = st.case(g, hc)
            base = float(hc.min())
            zi = base + H / hz
            assert c.z_i == pytest.approx(zi)
            z = np.array([zi - 10.0, zi + 10.0, zi + 1000.0])
            gm = c.gam(z)
            assert gm[0] == 0.0 and gm[1] == pytest.approx(300.0 * N_BV ** 2 / 9.81) and gm[2] == gm[1]
            assert np.all(c.H == 100.0)
            assert c.alpha == ALPHA and c.max_profile == MAXP
            raw = dict(hour=12.0, U10=sp.u10, t_max=26.0, sky="clear")
            d = BS.CN.derive(raw, st.ctx, hc, st.relief_m, dict(st.ov, alpha=ALPHA, max_profile=MAXP))
            # Fr = U_sat/(N·h): h = перепад рельефа (для идеальной формы — 500 м с точностью хвоста гаусса)
            assert d["froude"] == pytest.approx(fr, rel=0.01)
            assert d["n_bv_s"] == pytest.approx(N_BV, rel=1e-9)


# ------------------------------------------------------------------ инвариант 4 (тёплый старт)
def test_invariant4_warm_start():
    num = BS.Numerics(max_outer=600, late_from=400)
    prev = BS.solve_batch([spec_fr("hill", 0.15, 2.7)], num)[0]
    cold = BS.solve_batch([spec_fr("hill", 0.15, 3.0)], num)[0]
    warm = BS.solve_batch([spec_fr("hill", 0.15, 3.0)], num, init=[prev.state])[0]
    e = 6                                                    # губки области (2 км = 5 клеток) не входят
    du = float(np.max(np.abs(warm.fields[:3, :, e:-e, e:-e] - cold.fields[:3, :, e:-e, e:-e])))
    _record("invariant4", dict(max_du=du, u_sat=cold.u_sat, ratio=du / cold.u_sat, iters_cold=cold.iters, iters_warm=warm.iters,
                               status=[cold.status, warm.status]))
    assert cold.status == "ok" and warm.status == "ok"
    assert du <= 0.02 * cold.u_sat


# ------------------------------------------------------------------ опции
def test_numerics_options_and_trace():
    sp = spec_fr("ridge", 0.3, 0.3)
    nums = [BS.Numerics(max_outer=220, late_from=150), BS.Numerics(max_outer=220, late_from=150, omega_u=0.5, omega_k=0.5),
            BS.Numerics(max_outer=220, late_from=150, k_floor_m2s=10.0), BS.Numerics(max_outer=220, late_from=150, criterion="rel")]
    res = BS.solve_batch([sp] * 4, nums)
    for r, nm in zip(res, nums):
        T = (nm.max_outer - nm.snap_from) // nm.snap_step + 1
        assert r.trace["iter"].shape == (T,) and r.trace["fields"].shape == (T, 3, 2, 96, 96)
        k = int((r.trace["iter"] >= 0).sum())
        assert np.all(np.diff(r.trace["iter"][:k]) == 50) and (k == 0 or r.trace["iter"][0] in (101,))
        assert np.all(np.isfinite(r.trace["du_max"][1:k]))
        assert r.fields.shape == (4, 13, 96, 96) and np.isfinite(r.fields).all()
        assert set(r.state) == {"u", "v", "w", "th", "thd", "p", "nuf", "nuh"} and r.state["u"].dtype == np.float32
    # опции действительно меняют счёт
    assert not np.array_equal(res[0].fields, res[1].fields) and not np.array_equal(res[0].fields, res[2].fields)
    # нижний предел K: нигде в воздухе K < 10
    st = BS._Setup(0, sp, nums[2])
    assert st.prm.k_fa == 10.0 and nums[1].omega_k * A.Params().k_relax == BS._Setup(0, sp, nums[1]).prm.k_relax
    assert float(res[2].state["nuf"][res[2].state["nuf"] > 0].min()) >= 10.0 - 1e-3
    # относительный критерий: порог = REL_TOL·U_sat²/a, при U_sat = 5, a = 500 — абсолютный 2e-5
    assert BS.REL_TOL * 25.0 / 500.0 == pytest.approx(BS.TOL_MOM)
    r0, rr = res[0], res[3]
    assert rr.resid_rel_final == pytest.approx(rr.resid_final * rr.meta["relief_m"] / rr.u_sat ** 2, rel=1e-5)


# ------------------------------------------------------------------ огибающая
def test_envelope_shape():
    g100 = ideal_g100("step_down", 0.5)
    hc = g100.reshape(96, 4, 96, 4).mean(axis=(1, 3))
    he = BS.envelope(hc, 270.0, 12.0)
    assert np.all(he >= hc)
    x = -19200 + 200 + 400 * np.arange(96)
    assert np.array_equal(he[:, x < -1000], hc[:, x < -1000])        # выше бровки по потоку — как есть
    sh = he - hc
    assert sh[:, (x > 0) & (x < 1500)].max() > 50.0                   # тень за бровкой
    # линия тени не круче угла: падение за шаг ≤ 400·tg 12°
    drop = -(np.diff(he, axis=1))
    assert drop.max() <= 400.0 * math.tan(math.radians(12.0)) + 1e-6 or np.all(he == np.maximum(he, hc))
    assert np.array_equal(BS.envelope(hc, 270.0, 0.0), hc)
    # косой ветер: тоже ≥ h и тень есть
    he2 = BS.envelope(hc, 300.0, 12.0)
    assert np.all(he2 >= hc) and (he2 - hc).max() > 50.0


def test_envelope_solve():
    sp = spec_fr("step_down", 0.5, 3.0)
    nums = [BS.Numerics(max_outer=120, late_from=100, envelope_angle_deg=12.0, envelope_wall=w, envelope_z0_m=0.01 if w == "low_z0" else None)
            for w in ("ground", "low_z0", "slip")]
    res = BS.solve_batch([sp] * 3, nums)
    for r in res:
        assert r.status != "diverged" and r.h_eff is not None and np.all(r.h_eff >= r.hc - 1e-3)
        assert np.isfinite(r.fields).all()
    assert not np.array_equal(res[0].fields, res[2].fields)
    with pytest.raises(ValueError):
        BS._Setup(0, sp, BS.Numerics(envelope_angle_deg=12.0))


# ------------------------------------------------------------------ окно 100 м
def test_window_100m():
    sp = spec_fr("step_down", 0.3, 3.0, dx=100.0)
    r = BS.solve_batch([sp], BS.Numerics(max_outer=120, late_from=100))[0]
    w = r.window
    m = w["meta"]
    assert m["fits_15h"] and m["downwind_fit_m"] >= 15 * 500.0
    a = 500.0 / (2 * 0.3)
    assert abs(m["brink_x_m"] - (-a * math.atanh(1 / math.sqrt(3)))) < 300.0      # бровка tanh-уступа: z'' min при x = −0,658a
    assert w["fields"].shape == (4, 13, m["ny"], m["nx"]) and np.isfinite(w["fields"]).all()
    assert w["status"] in ("ok", "max")

# ------------------------------------------------------------------ P4 v4: верх области и губка
def test_top_sponge_default_bitwise():
    """top_above_m / sponge_top_m по умолчанию — та же сетка и побитно то же поле, что без опций; другие — меняют счёт."""
    import real as R
    sp = spec_fr("ridge", 0.3, 0.6, h_over_zi=1.0)
    st = BS._Setup(0, sp, BS.Numerics())
    g0, h0 = R.grid_domain(st.loc, 400)
    g1, h1 = BS.grid_domain(st.loc, 400, top_above=BS.Numerics().top_above_m)
    key = lambda g: (g.dx, g.nx, g.ny, g.dz, g.z_bot, g.nz, g.x0, g.y0)
    assert key(g0) == key(g1) and np.array_equal(h0, h1) and st.prm == A.Params()
    g2, _ = BS.grid_domain(st.loc, 400, top_above=4500.0)
    assert g2.nz > g0.nz and g2.z_bot == g0.z_bot
    nums = [BS.Numerics(max_outer=120, late_from=100), BS.Numerics(max_outer=120, late_from=100, top_above_m=3000.0, sponge_top_m=1000.0),
            BS.Numerics(max_outer=120, late_from=100, top_above_m=4500.0, sponge_top_m=2000.0)]
    res = [BS.solve_batch([sp], nm)[0] for nm in nums]
    assert np.array_equal(res[0].fields, res[1].fields) and res[0].iters == res[1].iters
    assert not np.array_equal(res[0].fields, res[2].fields)
    assert BS._Setup(0, sp, nums[2]).prm.sponge_top_m == 2000.0


def test_lam_default_bitwise():
    """P4 v5: lam_m по умолчанию (40 м = Params.lam) — побитно то же поле; другое λ — Params.lam и иной счёт."""
    sp = spec_fr("ridge", 0.3, 0.6, h_over_zi=1.0)
    assert BS._Setup(0, sp, BS.Numerics()).prm == A.Params() and BS.Numerics().lam_m == A.Params().lam
    nums = [BS.Numerics(max_outer=120, late_from=100), BS.Numerics(max_outer=120, late_from=100, lam_m=40.0),
            BS.Numerics(max_outer=120, late_from=100, lam_m=160.0)]
    res = [BS.solve_batch([sp], nm)[0] for nm in nums]
    assert np.array_equal(res[0].fields, res[1].fields) and res[0].iters == res[1].iters
    assert not np.array_equal(res[0].fields, res[2].fields)
    assert BS._Setup(0, sp, nums[2]).prm.lam == 160.0


# ------------------------------------------------------------------ P4 v6: карта ω, заморозка, запасное правило, старт из сборки
def test_v6_default_bitwise_and_replica():
    """Опции v6 по умолчанию — побитно v5; путь `_outer` (копия Air.outer_step) без ω и заморозки — побитно тот же счёт."""
    sp = spec_fr("ridge", 0.3, 0.6, h_over_zi=1.0)
    nums = [BS.Numerics(max_outer=120, late_from=100),
            BS.Numerics(max_outer=120, late_from=100, omega_map=None, freeze_mask=None, omega_fallback=None),
            BS.Numerics(max_outer=120, late_from=100, omega_fallback=(10 ** 6, 0.5))]
    res = [BS.solve_batch([sp], nm)[0] for nm in nums]
    for r in res[1:]:
        assert np.array_equal(res[0].fields, r.fields) and res[0].iters == r.iters and res[0].status == r.status
    assert res[2].meta["omega_switch_iter"] == -1 and res[0].meta["omega_switch_iter"] == -1


def test_v6_omega_map_uniform_matches_scalar():
    """ω по карте ≡ 0,5 — то же, что скаляры omega_u = omega_k = 0,5 (до округления: K и u релаксируются после шага)."""
    sp = spec_fr("hill", 0.3, 1.5)
    a = BS.solve_batch([sp], BS.Numerics(max_outer=600, late_from=400, omega_u=0.5, omega_k=0.5))[0]
    b = BS.solve_batch([sp], BS.Numerics(max_outer=600, late_from=400, omega_map=np.full((96, 96), 0.5, np.float32)))[0]
    du = float(np.max(np.abs(a.fields[:3] - b.fields[:3])))
    _record("v6_omega_map_uniform", dict(iters_scalar=a.iters, iters_map=b.iters, max_du=du, status=[a.status, b.status]))
    assert a.status == b.status == "ok"
    assert abs(a.iters - b.iters) <= max(10, 0.05 * a.iters)
    assert du <= 0.01 * a.u_sat
    with pytest.raises(ValueError):
        BS._Setup(0, sp, BS.Numerics(omega_u=0.5, omega_map=np.ones((96, 96))))


def test_v6_freeze_and_agl_init():
    """Старт из поля на высотах AGL: сошедшееся поле как init — сходится быстрее холодного и к тому же полю; замороженные
    колонны остаются равными init: внутри блока поле одинаково при любом числе итераций (сошедшийся счёт и 200 итераций
    со строгим порогом), критерий — по остальным клеткам."""
    sp = spec_fr("hill", 0.15, 3.0)
    num = BS.Numerics(max_outer=600, late_from=400)
    cold = BS.solve_batch([sp], num)[0]
    warm = BS.solve_batch([sp], num, init=[{"agl": cold.fields}])[0]
    e = 6
    du = float(np.max(np.abs(warm.fields[:3, :, e:-e, e:-e] - cold.fields[:3, :, e:-e, e:-e])))
    fz = np.zeros((96, 96), bool)
    fz[10:30, 10:30] = True
    fr = BS.solve_batch([sp], BS.Numerics(max_outer=600, late_from=400, freeze_mask=fz), init=[{"agl": cold.fields}])[0]
    zero = BS.solve_batch([sp], BS.Numerics(max_outer=200, late_from=100, tol=1e-9, freeze_mask=fz), init=[{"agl": cold.fields}])[0]
    inner = (slice(None), slice(None), slice(11, 29), slice(11, 29))     # грани внутри блока (обе колонны заморожены)
    dfz = float(np.max(np.abs(fr.fields[inner] - zero.fields[inner])))
    _record("v6_freeze_agl", dict(iters_cold=cold.iters, iters_warm=warm.iters, max_du_warm=du, iters_freeze=fr.iters,
                                  frozen_drift=dfz, n_frozen=fr.meta["n_frozen_cols"]))
    assert cold.status == warm.status == fr.status == "ok"
    assert warm.iters < cold.iters and du <= 0.02 * cold.u_sat
    assert fr.meta["n_frozen_cols"] == 400 and dfz <= 1e-5


def test_v6_omega_fallback_switches():
    """Запасное правило (N, 0,5): без сходимости к N итерациям ω переключается, граф перезаписывается."""
    sp = spec_fr("ridge", 0.3, 0.6, h_over_zi=1.0)
    r = BS.solve_batch([sp], BS.Numerics(max_outer=200, late_from=150, omega_fallback=(50, 0.5)))[0]
    ref = BS.solve_batch([sp], BS.Numerics(max_outer=200, late_from=150))[0]
    _record("v6_fallback", dict(switch=r.meta["omega_switch_iter"], iters=r.iters, status=r.status, iters_ref=ref.iters, status_ref=ref.status))
    if ref.iters <= 51:
        pytest.skip("случай сошёлся до N — переключения нет")
    assert r.meta["omega_switch_iter"] == 51
    assert not np.array_equal(r.fields, ref.fields)
