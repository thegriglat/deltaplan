"""Восстановление условий случая (FiLM, поток тепла) против того, что видел решатель; кеш подготовки; обратное преобразование цели.
Нужны готовые части счёта SY-10 (пробный каталог hg_v1__hgw24…__trial); без них тесты пропускаются."""
import os
import sys
from pathlib import Path

import numpy as np
import pytest

import s7_data as D

_CAND = [Path(os.path.expanduser(f"~/air_synth_data/solve/{n}")) for n in
         ("hg_v2__hgw24__s0-939a467__trial", "hg_v2__hgw24__s0-939a467", "hg_v1__hgw24__s0-939a467__trial")]
TRIAL = next((p for p in _CAND if (p / "solve.h5").exists()), _CAND[0])
pytestmark = pytest.mark.skipif(not (TRIAL / "solve.h5").exists(), reason="нет пробного счёта SY-10")


@pytest.fixture(scope="module")
def cache(tmp_path_factory):
    d = tmp_path_factory.mktemp("cache")
    D.build_cache(TRIAL, d, workers=1, chunk=6)
    return D.Cache(d)


def test_heat_flux_and_hc_equal_solver(cache):
    """Для всех случаев пробы: восстановленный поток тепла (с гашением у края) = inputs/heat_flux решателя (float16), hc совпадает."""
    assert len(cache) >= 3
    assert cache.meta["heat_dev"].max() == 0.0
    assert cache.meta["hc_dev"].max() < 1e-3          # float32 → float64


def test_film_numbers_vs_conditions_table(cache):
    """Числа FiLM из восстановления = таблице условий S2 v4 (выводит их другим кодом — conditions.derive) в пределах округления `day.summary`."""
    import s5_io as S5
    import corpus_io as cio
    from pilotnn.prep import FILM_NAMES
    man = __import__("json").loads((TRIAL / "manifest.json").read_text())
    conds = cio.Conditions(man["conditions"])
    cmap = {(int(r["relief_id"]), int(r["cond_id"])): r for r in conds.table}
    X, F = cache.load_xf(np.arange(len(cache)))
    i = {n: k for k, n in enumerate(FILM_NAMES)}
    for j in range(3):
        c = cmap[(int(cache.meta["relief_id"][j]), int(cache.meta["cond_id"][j]))]
        hm = cache.meta["hc_mean"][j]
        f = F[j]
        assert abs(f[i["U10"]] * 10 - c["u10_m_s"]) < 1e-4
        assert abs((f[i["alpha"]] * 0.1 + 0.2) - c["alpha"]) < 1e-5
        assert abs((f[i["max_profile"]] * 0.5 + 1.5) - c["max_profile"]) < 1e-5
        assert abs(f[i["z_i"]] * 1000 + hm - c["z_i_m"]) < 1.01                 # summary: целые метры
        assert abs(f[i["z_lcl"]] * 1000 + hm - c["z_lcl_m"]) < 1.01
        assert abs(f[i["sun_el"]] * 90 - c["sun_el_deg"]) < 1e-3
        assert abs(f[i["heat"]] - c["heat"]) < 0.0011
        assert abs(f[i["t_max"]] * 8 + 26 - c["t_max_c"]) < 1e-4
        assert abs(f[i["hour"]] * 6 + 14 - c["hour_local"]) < 1e-4
        assert abs(f[i["t_air"]] * 10 + 20 - c["t_c"]) < 0.011
        assert abs(f[i["stab"]] * 2.5 + 2.5 - c["stability_class"]) < 1e-5
        assert abs(f[i["brk"]] - c["brk"]) < 0.0011
        assert (f[i["cap_flag"]] > 0) == bool(c["has_cap"])
        assert np.isfinite(F).all() and np.isfinite(X).all()


def test_target_roundtrip_to_physical(cache):
    """to_physical(цель) = поля решателя (float16) — преобразование цели обратимо; |ΔV| через цель = через физические поля."""
    import s5_io as S5
    from pilotnn import prep as P
    sol = S5.Solve(TRIAL)
    for j in (0, 5, 19):
        Y = cache.gather_y([j])[0].astype(np.float64)
        meta = dict(k=int(cache.meta["k"][j]), r=float(cache.meta["r"][j]), S=float(cache.meta["S"][j]), alpha=float(cache.meta["alpha"][j]),
                    mp=float(cache.meta["mp"][j]), U10=float(cache.meta["U10"][j]))
        ph = P.to_physical(Y, meta)
        fm, fh = sol.get("fields/m", j).astype(np.float64), sol.get("fields/h", j).astype(np.float64)
        assert np.abs(ph["m"] - fm).max() < 0.02 * max(meta["S"], 1) + 0.02
        assert np.abs(ph["h"] - fh).max() < 0.02 * max(meta["S"], 1) + 0.02


def test_error_through_target_equals_physical(cache):
    """|ΔV| на 60 м, посчитанный по цели (кодировка), совпадает с вычисленным по физическим полям (to_physical) для искажённого прогноза."""
    from pilotnn import prep as P
    import s7_eval as E
    j = 3
    yt = cache.gather_y([j]).astype(np.float32)
    rng = np.random.default_rng(0)
    yp = yt + rng.normal(0, 0.05, yt.shape).astype(np.float32)
    S = np.array([cache.meta["S"][j]])
    dv, _ = E.errors(yp, yt, S, "h")
    meta = dict(k=int(cache.meta["k"][j]), r=float(cache.meta["r"][j]), S=float(cache.meta["S"][j]), alpha=float(cache.meta["alpha"][j]),
                mp=float(cache.meta["mp"][j]), U10=float(cache.meta["U10"][j]))
    a, b = P.to_physical(yp[0].astype(np.float64), meta)["h"], P.to_physical(yt[0].astype(np.float64), meta)["h"]
    i50, i75 = 1, 2
    f = lambda F, c: 0.6 * F[c, i50] + 0.4 * F[c, i75]
    ref = P.rot_scalar(np.hypot(f(a, 0) - f(b, 0), f(a, 1) - f(b, 1)), meta["k"])[5:-5, 5:-5]      # физическая система -> повёрнутая
    assert np.abs(dv[0] - ref).max() < 1e-4


def test_val_split_by_place():
    ids = np.repeat(np.arange(100, 140), 24)
    m = D.split_val(ids, 0.1, seed=1)
    assert 0 < m.sum() < len(ids)
    assert len(np.unique(ids[m])) == 4
    for p in np.unique(ids):
        s = m[ids == p]
        assert s.all() or not s.any()                   # место целиком в проверке или целиком в обучении
    assert (D.split_val(ids, 0.1, seed=1) == m).all()
