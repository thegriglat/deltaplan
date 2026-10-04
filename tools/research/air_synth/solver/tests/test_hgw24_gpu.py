"""SY-10, GPU под замком (`dp lock gpu sy10-test -- pytest …`): возмущения погоды доходят до настоящего решателя, а нулевые — побитно как раньше.
Три решения области (max_outer 40 — только сравнение, не сходимость): (а) обычное условие (v2: sky clear, без столбцов hgw24);
(б) hgw24 с нулевыми возмущениями (cover 0, dt_upper 0, градиент как в конфиге, множители 1) — поля побитно равны (а);
(в) hgw24 с возмущениями (dt_upper +5 К, градиент 8 К/км, cover 0,6) — θ′, поток тепла и толщина слоя решателя меняются."""
import sys
from pathlib import Path

import numpy as np
import pytest

SOL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SOL))
import s5_io as S5   # noqa: E402
import solve_corpus as SC   # noqa: E402
import make_hgw24 as H   # noqa: E402


def hill():
    j, i = np.mgrid[0:384, 0:384].astype(float)
    return 1200 + 400 * np.exp(-(((i - 192) / 60) ** 2 + ((j - 192) / 90) ** 2)) + 0.1 * i


def _row(over=None):
    g = hill()
    summ = dict(relief_m=float(g.max() - g.min()), h_min_m=float(g.min()), h_max_m=float(g.max()))
    r = H.rows_for(H.SEED, 1, "hg_t", 47.0, 10.0, g, summ, "W")[5]
    d = {n: (r[n].item() if hasattr(r[n], "item") else r[n]) for n in r.dtype.names}
    d.update(month=6, day=15, hour_local=13.0, u10_m_s=6.0, wind_from_deg=270.0, t_max_c=24.0, sky=0, cond_id=0)
    d.update(over or {})
    return g, d


def test_perturbation_reaches_real_solver():
    SC._init()
    SC._W["mo"] = 40
    SC._W["late"] = None
    g, base = _row()
    plain = {k: v for k, v in base.items() if k not in S5.HG_COLUMNS and k != "dtheta_dz_k_per_km"}     # v2/v3: без возмущений
    lapse0 = S5._air3d_weather().CFG["upper_air"]["lapse_k_per_km"]
    neutral = dict(base, dt_upper_k=0.0, lapse_k_per_km=lapse0, inv_depth_m=1.0, inv_range_k=1.0, cloud_cover=0.0)
    pert = dict(base, dt_upper_k=5.0, lapse_k_per_km=8.0, inv_depth_m=1.0, inv_range_k=1.0, cloud_cover=0.6)
    out = [SC.solve_one((k, 1, g, c)) for k, c in enumerate((plain, neutral, pert))]
    for key in ("m", "h", "H", "hbl", "hc"):
        assert np.array_equal(out[0][key], out[1][key]), key                  # нулевые возмущения — побитно как раньше
    assert not np.array_equal(out[0]["H"], out[2]["H"])                       # cover 0,6 — поток тепла меньше
    assert float(np.mean(out[2]["H"])) < float(np.mean(out[0]["H"]))
    assert not np.array_equal(out[0]["hbl"], out[2]["hbl"]) or not np.array_equal(out[0]["h"], out[2]["h"])
    assert np.abs(out[0]["h"].astype(float) - out[2]["h"].astype(float)).max() > 0.01       # поля с нагревом изменились
    assert S5._air3d_weather().CFG["upper_air"]["lapse_k_per_km"] == lapse0   # конфиг после случая возвращён
