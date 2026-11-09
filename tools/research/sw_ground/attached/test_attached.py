"""pytest sw_ground/attached (SWG-9): интеграл слоя Таунсенда против квадратуры; нулевой градиент → potential_jh
тождественно (оба правила); выше l — без изменений; хребет Аньези: знак правила (лее < 1, наветренная > 1);
нелинейный Бернулли — линеаризация = JH; формат SWG2 файла out/swg-9/ground.json."""
import json
import sys
import types

import numpy as np
import pytest
from scipy.integrate import quad

from attached import core as AC
from attached import assemble as AS
from ground import common as K
from ground import model as M


@pytest.mark.parametrize("a,g", [(1.0, 0.0), (0.3, 0.43), (-0.5, 1.0), (2.0, -0.1), (1.5, -0.5), (0.05, 3.0)])
def test_townsend_integral_vs_quad(a, g):
    z0, z = 0.03, 10.0
    br = -a / g if g else None
    pts = [br] if br is not None and z0 < br < z else None
    num = quad(lambda t: np.sqrt(max(a + g * t, 0.0)) / t, z0, z, points=pts, limit=400)[0]
    assert abs(AC._F(a, g, z, z0) - num) < 1e-7 * max(1.0, abs(num))


def test_matching_and_zero_gradient():
    l, z0 = 14.0, 0.03
    for g in (-0.3, -0.05, 0.0, 0.05, 0.4, 2.0):
        a = AC.solve_uw2(np.array([g]), l, z0)[0]
        assert abs(AC._F(a, g, l, z0) - np.log(l / z0)) < 1e-8          # u(l) = u_JH(l)
    fac, a = AC.apg_factor(np.array([2.0, 5.0, 10.0, 14.0, 30.0]), 14.0, z0, 0.0)
    assert np.array_equal(fac, np.ones(5)) and np.all(a == 1.0)
    fac, _ = AC.apg_factor(np.array([2.0, 10.0, 20.0]), 14.0, z0, 0.4)
    assert fac[0] < fac[1] < 1.0 and fac[2] == 1.0                      # неблагоприятный: дефицит у земли, выше l — 1
    fac, _ = AC.apg_factor(np.array([2.0, 10.0]), 14.0, z0, -0.2)
    assert np.all(fac > 1.0)                                            # благоприятный: профиль полнее


def test_rules_identity_at_zero_gradient():
    rng = np.random.default_rng(1)
    n = 50
    q = dict(uin=rng.uniform(0.3, 1.2, n), uh=rng.uniform(0.5, 1.5, n), t=rng.uniform(0, 1, n), A=rng.uniform(1, 3, n),
             dS=np.zeros(n), u0=rng.uniform(0.3, 1.0, n), l=rng.uniform(5, 60, n))
    z = rng.uniform(2, 300, n)
    r, _ = AS.rule_ratio(q, 0.5, "attached_jh", np.zeros(n), rng.uniform(1, 1.5, n), z)
    assert np.array_equal(r, np.ones(n))
    q["uin"] = q["u0"].copy()                                           # ΔS = 0 → u_in = u0
    r, _ = AS.rule_ratio(q, 0.5, "attached_jh_nl", None, None, z)
    assert np.max(np.abs(r - 1)) < 1e-14


def test_nl_linearization():
    A = np.array([1.5, 2.2])
    for dS in (1e-4, -1e-4):
        assert np.max(np.abs(AC.nl_factor(A, dS) - (1 + A * dS))) < 2 * A.max() ** 2 * dS ** 2 + 1e-12
    assert AC.nl_factor(np.array([2.0]), np.array([-0.4]))[0] == 0.0    # 1 + A((1+ΔS)² − 1) < 0 → 0, не обратный поток


@pytest.fixture(scope="module")
def agnesi():
    from wake import synth as S
    r = S.agnesi_run(ds_min=25.0, focus_x=np.arange(-600.0, 1201.0, 150.0))
    r.abs_points = types.MethodType(lambda self, x, y, z: (np.asarray(x, float), np.asarray(y, float),
                                                           self.panels.height(np.asarray(x, float), np.asarray(y, float))
                                                           + np.asarray(z, float)), r)
    yield r
    r.infl = None


def test_agnesi_sign(agnesi):
    """Хребет Аньези H/L = 0,5 (ветер +x): на подветренном склоне ∂ΔS/∂s < 0 → множитель на 10 м < 1, на наветренном > 1;
    перед холмом и далеко за ним |множитель − 1| мал; ΔS по линии зонда совпадает с dS jh_parts на l."""
    r = agnesi
    xs = np.array([-1200.0, -300.0, 150.0, 300.0, 450.0, 2400.0])
    pr = AC.probe(r, xs, 0 * xs, (-1200.0, 0.0, 100.0))
    i0 = AC.OFF.index(0.0)
    zg = r.panels.height(xs, 0 * xs)
    pj = M.jh_parts(r, xs, 0 * xs, zg + 1.0)                             # z < l → dS на l
    assert np.max(np.abs(pr["dS_line"][:, i0] - pj["dS"])) < 1e-9
    k10 = AC.ZP.index(10.0)
    uin = pr["u0"][:, k10] * (1 + pr["A"][:, k10] * pr["dS"][:, k10])
    l = pr["l"]
    uin_l = uin * np.log(l / r.z0) / np.log(10.0 / r.z0)
    g = AC.g_of(pr["dSdx"], pr["u0hm"], uin_l, l, r.z0)
    fac, _ = AC.apg_factor(np.full(xs.size, 10.0), l, r.z0, g)
    assert pr["dSdx"][2] < 0 and pr["dSdx"][3] < 0 and fac[2] < 1.0 and fac[3] < 0.97     # лее (x = 150, 300 м)
    assert pr["dSdx"][4] > 0 and fac[4] > 1.0                           # у подножия (x = 450 м) ΔS уже растёт
    assert pr["dSdx"][1] > 0 and fac[1] > 1.0                           # наветренный склон
    assert abs(fac[0] - 1) < 0.03 and abs(fac[5] - 1) < 0.03


def test_ground_file_contract():
    f = K.SG / "out" / "swg-9" / "ground.json"
    if not f.exists():
        pytest.skip("нет out/swg-9/ground.json (py -m attached.run assemble)")
    sys.path.insert(0, str(K.SG / "contract"))
    import check_contract as CC
    doc = json.load(open(f))
    ids = {r["id"] for r in json.load(open(K.OUT_POINTS))["rows"]}
    assert CC.check_ground(doc, ids)
    assert {"potential", "potential_jh", "attached_jh", "attached_jh_nl"} <= set(doc["variants"])
    assert all(v is not None and v < 1e-12 for v in doc["base_check"]["max_abs_ds_vs_swg1"].values())
