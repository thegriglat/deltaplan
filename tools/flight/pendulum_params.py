#!/usr/bin/env python3
"""Офлайн-расчёт блока `pendulum` (PD-К2 v8) для всех configs/wings/*.json.

Порт балансировки прототипа tools/research/pendulum (params/geometry/trim — импортируются, не
дублируются): для каждого крыла — геометрия полос, ЦМ и инерция крыла, dcm0 (момент паруса под
паспортный трим при подвеске игры), cd_scale (снижение на триме = поляре), ref.*.
v8 (pullin-speed VM-4): для нелинейной Cm(α) (configs/pendulum.json → pitch_nl) — cl_alpha_per_rad,
alpha_zero_lift_deg и ref.static_margin по модели игры (GameSim прототипа: C_L max полос под поляру,
как PendulumWingStrips), dcm0 — с включённой добавкой (её значение на триме вычитается).
Пишет блок в крыло (вставка строк перед "visual": ничего не удаляется и не переформатируется)
и таблицу tools/flight/pendulum_params_table.md. В рантайме игры не используется.

  python tools/flight/pendulum_params.py            # пересчитать и записать
  python tools/flight/pendulum_params.py --check    # пересчитать и сверить с файлами + инварианты PD-К2
Python с numpy: tools/research/heat_ca/.venv/bin/python
"""
from __future__ import annotations

import argparse
import json
import math
import re
import sys
from multiprocessing import Pool
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "research" / "pendulum"))

from pendulum import geometry, trim  # noqa: E402
from pendulum.model import R_from_euler, Sim  # noqa: E402
from pendulum.params import load_params  # noqa: E402
import export_reference as E  # noqa: E402  (GameSim — прототип в конфигурации игры)
import numpy as np  # noqa: E402

CONTRACT = "PD-К2 v8"
WINGS = ROOT / "configs" / "wings"
TABLE = ROOT / "tools" / "flight" / "pendulum_params_table.md"
DOC = ("генерирует tools/flight/pendulum_params.py (порт балансировки tools/research/pendulum), "
       "руками не править; оси киля: x — назад от носа, z — вверх; inertia_kgm2 — оси x вперёд, "
       "y вправо, z вниз, около ЦМ крыла, без присоединённой массы (ixz = элемент тензора, "
       "−Σm·x·z); dcm0 — безразмерная добавка Cm0 паруса (по средней хорде) под паспортный трим "
       "при hang_from_nose_m и эталонной массе (v8 — с включённой pitch_nl); cl_alpha_per_rad — dCL/dα "
       "крыла по полосам на триме (±0,5°), alpha_zero_lift_deg — α киля нулевой подъёмной силы полос; "
       "ref.static_margin — Kn на триме линейной модели игры (C_L max полос под поляру)")
PEND = json.loads((ROOT / "configs" / "pendulum.json").read_text())
PNL = PEND["pitch_nl"]
# Умолчания «Аппарата» по классу крыла (`group` в конфиге): эффективное поперечное V, ° и гибкость
# паруса (множитель перекоса пузыря, configs/pendulum.json → billow_shift_deg). Калибровка —
# tools/research/pendulum/pd21_lateral.py (out/pd24), обоснование — docs/research/pendulum.md, PD-24.
GROUP_DEFAULTS = {
    # PD-24 (полосы без урезания разницы нагрузок, Clβ/Clp/Clr — к Hiway Demon): гибкость — перекладка
    # 45→45 ≈ 4 с и Ochi ≈ 30° за 7 с (laminar); V учебных 6° (верх ползунка), советских 5° — сами выходят из виража 30°
    # за 5–10 с; V мачтовых −1,5°, безмачтовых +0,5° — спираль держится (пилот: у спортивных V бывает
    # отрицательное)
    "trainer": {"dihedral_eff_deg": 6.0, "sail_flex": 0.5},
    "soviet": {"dihedral_eff_deg": 5.0, "sail_flex": 0.45},
    "kingpost": {"dihedral_eff_deg": -1.5, "sail_flex": 0.6},
    "topless": {"dihedral_eff_deg": 0.5, "sail_flex": 0.6},
    # TT-2: крыло буксировщика (iXess 15, мачтовое с жёсткой поперечиной) — умолчания мачтовых; в источниках н/д
    "tug": {"dihedral_eff_deg": -1.5, "sail_flex": 0.6},
}
GP = json.loads((ROOT / "tools/blender/glider_params.json").read_text())
R = lambda x, n=4: round(float(x), n)  # noqa: E731


def trim_v_near(sim: Sim, a0: float, v0: float):
    """Скорость трима (момент около подвески = 0) ближайшего к a0 корня: шаг ±0,5° от a0 до смены знака."""
    mom = lambda a: trim.glide_balance(sim, a, v0)[2]  # noqa: E731
    m0 = mom(a0)
    for k in range(1, 40):
        for sgn in (1, -1):
            a1 = a0 + sgn * k * math.radians(0.5)
            if a1 < sim.p.alpha0 + math.radians(1) or a1 > math.radians(30):
                continue
            m1 = mom(a1)
            if m1 * m0 <= 0:
                lo, hi, mlo = (a0, a1, m0) if sgn > 0 else (a1, a0, m1)
                for _ in range(40):
                    mid = 0.5 * (lo + hi)
                    mm = mom(mid)
                    if mm * mlo > 0:
                        lo, mlo = mid, mm
                    else:
                        hi = mid
                return trim.glide_balance(sim, 0.5 * (lo + hi), v0)[0]
    return None


def wing_cl(s, alpha: float) -> float:
    """CL крыла (полосы) при угле атаки киля alpha, поток вдоль x мира (как vm2_run.wing_cl)."""
    R = R_from_euler(0.0, alpha, 0.0)
    F, _, _ = s.wing_aero(np.zeros(3), np.array([10.0, 0.0, 0.0]), R, np.zeros(3))
    return float(-F[2] / (0.5 * s.p.rho * 100.0 * s.p.area))


def pitch_nl_geom(s, a: float, V: float) -> tuple[float, float, float]:
    """(Kn на триме, dCL/dα, α нулевой подъёмной) — как vm2_run.geom: Kn по модели игры (GameSim)."""
    kn = trim.static_margin(s, a, V)
    da = math.radians(0.5)
    cla = (wing_cl(s, a + da) - wing_cl(s, a - da)) / (2 * da)
    lo, hi = a - math.radians(25), a
    for _ in range(50):
        mid = 0.5 * (lo + hi)
        if wing_cl(s, mid) > 0:
            hi = mid
        else:
            lo = mid
    return kn, cla, 0.5 * (lo + hi)


def pitch_nl_dcm(alpha: float, kn: float, alpha_t: float, cla: float, azl: float) -> float:
    """ΔCm(α) PD-К2 v8 (как PendulumWingStrips.pitch_nl_dcm), углы в рад; 0 — pitch_nl выключена."""
    if not PNL["enabled"]:
        return 0.0
    w = math.radians(PNL["width_deg"])
    r = lambda x: 0.5 * (x + math.sqrt(x * x + w * w))  # noqa: E731
    return (-(1.0 - PNL["sigma"]) * kn * cla * r(alpha_t - alpha)
            + math.degrees(1.0) * PNL["luff_cm_per_deg"] * r(azl + math.radians(PNL["luff_on_deg"]) - alpha))


def balance(p, xh: float):
    """Угол атаки трима и крыло без момента паруса (dcm0 = 0) с калиброванным cd_scale; None, если
    паспортная скорость трима недостижима до срыва полос. При нём сумма полос на паспортной
    массе уравновешивается именно на паспортной скорости (у крыльев с большой круткой CL по
    полосам ниже CL_α·(α − α0), поэтому α — не alpha_for_cl, а решение по скорости). cd_scale
    меняет скорость, dcm0 (линейно) — момент: итерация."""
    s0 = Sim(p.with_(x_hang=xh, dcm0=0.0))
    for _ in range(4):
        # первое (на растущем α) пересечение скорости трима: дальше срыв, V немонотонна
        lo = p.alpha0 + math.radians(1)
        hi = lo
        while trim.glide_balance(s0, hi, p.v_trim_ref)[0] > p.v_trim_ref:
            lo, hi = hi, hi + math.radians(0.25)
            if hi > math.radians(30):
                return None
        for _ in range(40):
            mid = 0.5 * (lo + hi)
            if trim.glide_balance(s0, mid, p.v_trim_ref)[0] > p.v_trim_ref:
                lo = mid
            else:
                hi = mid
        a = 0.5 * (lo + hi)
        trim.calibrate_cd(s0, a)
    return a, s0


def apparatus_defaults(wing_id: str) -> dict:
    group = json.loads((WINGS / f"{wing_id}.json").read_text())["group"]
    return dict(GROUP_DEFAULTS[group])


def compute(wing_id: str) -> dict:
    """Крутка из glider_params.json (геометрия) у части крыльев (≥ 12°) так разгружает концы, что
    полосы срываются раньше паспортной скорости трима или Kn выходит за инвариант PD-К2; тогда
    крутка уменьшается шагом 1° до самосогласованного трима (значение пишется в washout_deg)."""
    d = apparatus_defaults(wing_id)
    p0 = load_params(wing_id).with_(dihedral=math.radians(d["dihedral_eff_deg"]), sail_flex=d["sail_flex"])
    w_deg = math.degrees(p0.washout)
    while w_deg >= 0:
        b = _compute(wing_id, p0.with_(washout=math.radians(w_deg)))
        if b is not None:
            return b
        w_deg -= 1.0
    raise RuntimeError(f"{wing_id}: трим недостижим")


def _compute(wing_id: str, p):
    xh = p.x_hang_game
    res = balance(p, xh)
    if res is None:
        return None
    a, s0 = res
    V, gam, M, st0 = trim.glide_balance(s0, a, p.v_trim_ref)
    d = -M / (0.5 * p.rho * V * V * p.area * p.chord_mean)
    p = p.with_(x_hang=xh, dcm0=d)
    s = Sim(p)
    s.cd_scale = s0.cd_scale
    V, gam, M1, st = trim.glide_balance(s, a, p.v_trim_ref)
    kn = trim.static_margin(s, st["alpha"], st["V"])
    if st["gamma"] > math.radians(12) or not 0.02 < kn < 0.38:  # срыв полос или вне инварианта
        return None
    # v8: Kn, dCL/dα, α нулевой подъёмной — по модели игры (GameSim); у части крыльев трим близок к
    # C_L max полос, и подбор C_L max под поляру уменьшает Kn против Sim прототипа (atlas 0,17 против 0,27)
    gs = E.GameSim(p, yaw_mode="free")
    gs.cd_scale = s.cd_scale
    kn_g, cla, azl = pitch_nl_geom(gs, st["alpha"], st["V"])
    kn_g, cla, azl_deg = R(kn_g, 4), R(cla, 4), R(math.degrees(azl), 3)
    a_t = R(math.degrees(st["alpha"]), 2)
    # dcm0 с добавкой: ΔCm(α_t) (≈ −(1 − σ)·Kn·a·w/2) уходит в dcm0, трим прежний
    d_nl = d - pitch_nl_dcm(math.radians(a_t), kn_g, math.radians(a_t), cla, math.radians(azl_deg))
    # проверка: прототип с включённой добавкой (Params.pitch_nl) на том же α — момент около подвески ≈ 0
    p_nl = p.with_(dcm0=R(d_nl, 5), pitch_nl=PNL["enabled"], pnl_sigma=PNL["sigma"], pnl_width_deg=PNL["width_deg"],
                   pnl_luff_per_deg=PNL["luff_cm_per_deg"], pnl_luff_on_deg=PNL["luff_on_deg"], pnl_kn_trim=kn_g,
                   pnl_alpha_trim=math.radians(a_t), pnl_cl_alpha=cla, pnl_alpha_zl=math.radians(azl_deg))
    s_nl = Sim(p_nl)
    s_nl.cd_scale = s.cd_scale
    V2, _, M2, _ = trim.glide_balance(s_nl, a, p.v_trim_ref)
    cm_res = M2 / (0.5 * p.rho * V2 * V2 * p.area * p.chord_mean)
    if abs(cm_res) > 2e-4:
        raise RuntimeError(f"{wing_id}: момент на триме с pitch_nl {cm_res:.2e}")
    x_np = trim.neutral_point(p.with_(dcm0=d))
    # чувствительность трима к подвеске: км/ч на 1 см сдвига вперёд (dcm0 прежний, cd_scale крыла). v8 — модель
    # игры с добавкой (GameSim, pitch_nl): вперёд трим уходит ниже α_t, где Cm(α) мягче, — только сдвиг вперёд
    dx = 0.01
    gv = []
    for sh in (0.0, dx):
        s2 = E.GameSim(p_nl.with_(x_hang=xh - sh), yaw_mode="free")
        s2.cd_scale = s.cd_scale
        gv.append(trim_v_near(s2, a, p.v_trim_ref))
    if gv[0] is None or gv[1] is None:
        raise RuntimeError(f"{wing_id}: трим со сдвигом подвески не найден")
    kmh_cm = (gv[1] - gv[0]) * 3.6 / (dx * 100)
    mm = s.mm
    zb = 0.06 + p.upright_len * math.cos(p.upright_tilt)
    xb = xh - p.upright_len * math.sin(p.upright_tilt)
    I = mm.inertia_b
    return {
        "contract": CONTRACT,
        "_doc": DOC,
        "sweep_deg": R(math.degrees(p.sweep), 3),
        "root_chord_m": R(p.root_chord, 3),
        "tip_chord_m": R(p.tip_chord, 3),
        "washout_deg": R(math.degrees(p.washout), 3),
        "keel_len_m": R(p.keel_len, 3),
        "crossbar_from_nose_m": R(p.crossbar_from_nose, 3),
        "hang_from_nose_m": R(xh, 4),
        "bar_x_from_nose_m": R(xb, 4),
        "bar_z_m": R(-zb, 4),
        "cg_x_from_nose_m": R(mm.cg_n[0], 4),
        "cg_z_m": R(-mm.cg_n[2], 4),
        "inertia_kgm2": {"ixx": R(I[0, 0], 3), "iyy": R(I[1, 1], 3), "izz": R(I[2, 2], 3),
                         "ixz": R(I[0, 2], 3)},
        "dcm0": R(d_nl, 5),
        "cl_alpha_per_rad": cla,
        "alpha_zero_lift_deg": azl_deg,
        "cd_scale": R(s.cd_scale, 5),
        "apparatus_defaults": apparatus_defaults(wing_id),
        "ref": {
            "trim_kmh": R(st["V"] * 3.6, 2),
            "sink_ms": R(st["V"] * math.sin(st["gamma"]), 3),
            "alpha_trim_deg": R(math.degrees(st["alpha"]), 2),
            "neutral_point_from_nose_m": R(x_np, 4),
            "static_margin": kn_g,
            "kmh_per_cm_hang": R(kmh_cm, 3),
        },
    }


def wing_ids() -> list[str]:
    return sorted(f.stem for f in WINGS.glob("*.json"))


def _fmt_block(block: dict) -> list[str]:
    lines = json.dumps({"pendulum": block}, indent=2, ensure_ascii=False).splitlines()[1:-1]
    lines[-1] += ","
    return lines


def write_block(wing_id: str, block: dict) -> None:
    path = WINGS / f"{wing_id}.json"
    lines = path.read_text().splitlines()
    # убрать прежний блок (от `  "pendulum": {` до `  },`)
    out, skip = [], False
    for ln in lines:
        if ln.startswith('  "pendulum": {'):
            skip = True
            continue
        if skip:
            if ln.startswith("  },"):
                skip = False
            continue
        out.append(ln)
    idx = next(i for i, ln in enumerate(out) if ln.startswith('  "visual": {'))
    out[idx:idx] = _fmt_block(block)
    path.write_text("\n".join(out) + "\n")


def table(res: dict[str, dict]) -> str:
    L = ["# Параметры маятника по крыльям (PD-К2 v8)", "",
         "Генерирует `tools/flight/pendulum_params.py`; руками не править.", "",
         "| Крыло | трим км/ч (паспорт) | снижение м/с | α трима ° | Kn | НТ от носа, м | подвеска от носа, м | ЦМ x, м | dcm0 | cd_scale | км/ч на см | крутка ° (glider_params) | класс | V ° | гибкость |",
         "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for wid, b in res.items():
        w = json.loads((WINGS / f"{wid}.json").read_text())
        r = b["ref"]
        L.append(f"| {wid} | {r['trim_kmh']:.1f} ({w['trim_speed_kmh']}) | {r['sink_ms']:.3f} | "
                 f"{r['alpha_trim_deg']:.1f} | {r['static_margin']:.3f} | {r['neutral_point_from_nose_m']:.3f} | "
                 f"{b['hang_from_nose_m']:.3f} | {b['cg_x_from_nose_m']:.3f} | {b['dcm0']:.4f} | "
                 f"{b['cd_scale']:.3f} | {r['kmh_per_cm_hang']:.2f} | {b['washout_deg']:.0f} ({GP['wings'][wid]['washout_deg']:.0f}) | "
                 f"{w['group']} | {b['apparatus_defaults']['dihedral_eff_deg']:g} | {b['apparatus_defaults']['sail_flex']:g} |")
    return "\n".join(L) + "\n"


def polar_sink_ref(wing_id: str, v_ms: float) -> float:
    return trim.polar_sink(load_params(wing_id), v_ms)


def check_invariants(wid: str, b: dict) -> list[str]:
    err = []
    w = json.loads((WINGS / f"{wid}.json").read_text())
    r = b["ref"]
    if not b["root_chord_m"] > b["tip_chord_m"] > 0:
        err.append("хорды")
    if not 0 < r["static_margin"] < 0.4:
        err.append(f"static_margin {r['static_margin']}")
    if abs(r["trim_kmh"] - w["trim_speed_kmh"]) > 0.3:
        err.append(f"трим {r['trim_kmh']} vs {w['trim_speed_kmh']}")
    ps = polar_sink_ref(wid, r["trim_kmh"] / 3.6)
    if abs(r["sink_ms"] - ps) > 0.02:
        err.append(f"снижение {r['sink_ms']} vs поляра {ps:.3f}")
    I = b["inertia_kgm2"]
    if not all(I[k] > 0 for k in ("ixx", "iyy", "izz")):
        err.append("инерция")
    ad = b["apparatus_defaults"]
    if not -2.0 <= ad["dihedral_eff_deg"] <= 6.0:
        err.append(f"V {ad['dihedral_eff_deg']} вне −2…+6 (PD-К3)")
    if not 0.1 <= ad["sail_flex"] <= 1.0:
        err.append(f"flex {ad['sail_flex']} вне 0,1…1 (PD-К3)")
    return err


def _all_finite(o) -> bool:
    if isinstance(o, dict):
        return all(_all_finite(v) for v in o.values())
    if isinstance(o, float):
        return math.isfinite(o)
    return True


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    ids = wing_ids()
    with Pool(4) as pool:
        blocks = pool.map(compute, ids)
    res = dict(zip(ids, blocks))
    bad = 0
    for wid, b in res.items():
        errs = check_invariants(wid, b)
        if not _all_finite(b):
            errs.append("не конечные числа")
        if a.check:
            stored = json.loads((WINGS / f"{wid}.json").read_text()).get("pendulum")
            if stored != b:
                errs.append("блок в файле != пересчёту")
        if errs:
            bad += 1
            print(f"FAIL {wid}: {'; '.join(errs)}")
    if a.check:
        if TABLE.read_text() != table(res):
            print("FAIL таблица устарела")
            bad += 1
        print(f"проверено {len(ids)} крыльев, нарушений: {bad}")
        return 1 if bad else 0
    for wid, b in res.items():
        write_block(wid, b)
    TABLE.write_text(table(res))
    print(f"записано {len(ids)} крыльев; нарушений инвариантов: {bad}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
