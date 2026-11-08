"""pytest sw_ground/wake (SWG-4): выдув 0 → potential_jh побитно; ровная земля — следа нет; совпадение с
velocity_jh(couple=True); хребет Аньези H/L = 0,5 — числа следа за холмом."""
import numpy as np
import pytest

from ground import model as M
from panels3d import velocity_jh
from wake import core as W
from wake import synth as S


@pytest.fixture(scope="module")
def agnesi():
    r = S.agnesi_run(ds_min=25.0, focus_x=np.arange(-600.0, 1201.0, 150.0), backend="numpy")   # без GPU: общая GPU бывает занята
    g = W.WakeGrid(r.terrain, (1.0, 0.0), 25.0)
    sw, info = W.wake_sigma(r, g)
    return r, g, sw, info


def test_profile_hull_and_closure():
    s = np.arange(-2000.0, 2000.1, 12.5)
    z = 125.0 / (1 + (s / 250.0) ** 2)
    d, segs = W.profile_dstar(s, z, 25.0)
    g = [q for q in segs if q["gated"]]
    assert len(g) == 1 and g[0]["slope"] > W.SLOPE_MIN
    assert np.all(d[s < g[0]["s_s"] - 1e-9] == 0) and np.all(d[s > g[0]["s_r"] + 1e-9] == 0)
    assert d.max() > 0 and d[np.searchsorted(s, g[0]["s_r"])] < 1e-9      # δ* → 0 к присоединению
    # пологий холм (уклон < 0,27) — следа нет
    d2, segs2 = W.profile_dstar(s, 0.3 * z, 25.0)
    assert not any(q["gated"] for q in segs2) and d2.max() == 0


def test_flat_ground_no_wake():
    x = np.arange(-1000.0, 1000.1, 50.0)
    import panels3d as P
    t = P.Terrain3D(x, x, np.zeros((x.size, x.size)), far_m=3000.0)
    g = W.WakeGrid(t, (1.0, 0.0), 50.0)
    assert g.D.max() == 0 and not g.segs


def test_zero_blowing_bitwise(agnesi):
    r, g, sw, info = agnesi
    xs = np.array([-300.0, 0.0, 300.0, 600.0, 900.0])
    for zagl in (10.0, 50.0, 300.0):
        z = r.panels.height(xs, 0 * xs) + zagl
        pj = M.jh_parts(r, xs, 0 * xs, z)
        pw = W.wake_parts(r, xs, 0 * xs, z, np.zeros(r.panels.N))
        assert np.array_equal(pj["speed"], pw["speed"])
        assert np.array_equal(pj["pot_speed"], pw["pot_speed"])


def test_matches_velocity_jh_couple(agnesi):
    r, g, sw, info = agnesi
    xs = np.array([-300.0, 0.0, 300.0, 600.0, 900.0])
    for zagl in (10.0, 50.0, 300.0):
        z = r.panels.height(xs, 0 * xs) + zagl
        pw = W.wake_parts(r, xs, 0 * xs, z, sw)
        u, v, _ = velocity_jh(r.panels, r.sigma + sw, r.bg, xs, 0 * xs, z, r.z0, extra=W._zero_extra,
                              infl=r.infl, couple=True)
        assert np.max(np.abs(np.hypot(u, v) / pw["speed"] - 1)) < 1e-9


def test_agnesi_wake_numbers(agnesi):
    """Хребет H = 125 м, a = 250 м (H/L = 0,5, уклон 0,32 > 0,27): след от x_s ≈ +50 м до подножия x_r ≈ +750 м.
    Числа (U_ref, отношение wake_jh / potential_jh на 10 м): в середине лее — ускорение (тело вытеснения заполняет
    вогнутое подножие), за присоединением и у гребня — торможение. Это и есть результат SWG-4 (см. README)."""
    r, g, sw, info = agnesi
    seg = [q for q in g.segs if q["gated"] and abs(q["c"]) < 30][0]
    assert 0.0 <= seg["s_s"] <= 150.0 and 600.0 <= seg["s_r"] <= 900.0
    it = info["iters"]
    assert it[-1]["dq_rel"] < 0.1                                   # итерации U_e сходятся
    xs = np.array([0.0, 300.0, 500.0, seg["s_r"] + 100.0])
    z = r.panels.height(xs, 0 * xs) + 10.0
    pj = M.jh_parts(r, xs, 0 * xs, z)
    pw = W.wake_parts(r, xs, 0 * xs, z, sw)
    ratio = pw["speed"] / pj["speed"]
    assert ratio[0] < 0.97                       # гребень: торможение у начала выдува
    assert ratio[1] > 1.15 and ratio[2] > 1.1    # середина лее: ускорение, не дефицит
    assert ratio[3] < 0.95                       # за присоединением (сток): дефицит
