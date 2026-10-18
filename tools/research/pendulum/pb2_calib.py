#!/usr/bin/env python3
"""PB-2: калибровка VG_WASHOUT_DEG по сдвигу трима (T2C: VG 0 → ¾ хода ×1,28, 34 → 40–47 км/ч) и
чувствительность Vmax к каждому рычагу VG по отдельности. Не подгонка под Vmax: Vmax здесь только наблюдается.

  $PY tools/research/pendulum/pb2_calib.py [--jobs 12]  → out/pb2/calib.jsonl, out/pb2/calib.md
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from concurrent.futures import ProcessPoolExecutor
from dataclasses import replace
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import export_reference as E  # noqa: E402
from pendulum import trim, vg as VG  # noqa: E402
from pendulum.model import Control  # noqa: E402
from pendulum.scenarios import run  # noqa: E402

OUT = HERE / "out" / "pb2"
RAD = math.radians


def make(wing: str, vg: float, levers: tuple[str, ...], washout_deg: float | None = None):
    """Крыло с VG, применённым выборочно: levers ⊆ {washout, nose, flex, cd}."""
    blk = E.wing_cfg(wing)["pendulum"]
    p0 = E.params(wing).with_(x_hang=blk["hang_from_nose_m"], dcm0=blk["dcm0"])
    if washout_deg is not None:
        VG.VG_WASHOUT_DEG = washout_deg
    pv = VG.apply_vg(p0, vg)
    kw = {}
    if "washout" in levers:
        kw["washout"] = pv.washout
    if "nose" in levers:
        kw["sweep"], kw["span"] = pv.sweep, pv.span
    if "flex" in levers:
        kw["sail_flex"] = pv.sail_flex
    p = replace(p0, **kw)
    s = E.GameSim(p, yaw_mode="free")
    s.cd_scale = blk["cd_scale"] * (pv.extra.get("vg_cd_factor", 1.0) if "cd" in levers else 1.0)
    a, st = trim.solve_trim(s)
    s.reset_air(st)
    s.trim_state = st
    return s


def one(a):
    wing, name, vg, levers, wdeg = a
    s = make(wing, vg, levers, wdeg)
    st = s.trim_state
    kn = trim.static_margin(s, st["alpha"], st["V"])
    r = run(s, lambda t, o: Control(pitch=-1.0), 25.0)
    m = r["t"] > 15
    return {"wing": wing, "var": name, "vg": vg, "levers": list(levers), "washout_deg": wdeg,
            "trim_kmh": st["V"] * 3.6, "sink_ms": st["V"] * math.sin(st["gamma"]), "Kn": kn,
            "alpha_trim_deg": math.degrees(st["alpha"]), "ld_trim": 1 / math.tan(st["gamma"]),
            "V_pull_kmh": float(r["V"][m].mean() * 3.6), "fx_N": float(r["fh_x"][m].mean()),
            "rel_x": float(r["rel_x"][m].mean()), "sink_pull": float(-r["vz"][m].mean())}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--jobs", type=int, default=12)
    ap.add_argument("--wings", default="laminar,sport")
    args = ap.parse_args()
    plan = []
    for wing in args.wings.split(","):
        plan.append((wing, "base", 0.0, (), None))
        for w in (2.0, 4.0, 6.0, 8.0, 10.0):
            plan.append((wing, f"washout{w:.0f}_vg075", 0.75, ("washout",), w))
            plan.append((wing, f"washout{w:.0f}_vg1", 1.0, ("washout",), w))
        plan.append((wing, "nose_vg1", 1.0, ("nose",), None))
        plan.append((wing, "flex_vg1", 1.0, ("flex",), None))
        plan.append((wing, "cd_vg1", 1.0, ("cd",), None))
    OUT.mkdir(parents=True, exist_ok=True)
    rows = []
    with ProcessPoolExecutor(args.jobs) as ex:
        for r in ex.map(one, plan):
            rows.append(r)
            print(f"{r['wing']:8} {r['var']:18} trim {r['trim_kmh']:5.1f} Kn {r['Kn']:6.3f} L/D {r['ld_trim']:5.2f} "
                  f"Vpull {r['V_pull_kmh']:5.1f} fx {r['fx_N']:4.0f}", flush=True)
    (OUT / "calib.jsonl").write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n", encoding="utf-8")
    lines = ["| крыло | вариант | трим, км/ч | трим/база | Kn | L/D трим | Vmax «на себя», км/ч | усилие рук, Н |",
             "|---|---|---|---|---|---|---|---|"]
    base = {r["wing"]: r for r in rows if r["var"] == "base"}
    for r in rows:
        b = base[r["wing"]]
        lines.append(f"| {r['wing']} | {r['var']} | {r['trim_kmh']:.1f} | {r['trim_kmh'] / b['trim_kmh']:.2f} | {r['Kn']:.3f} | "
                     f"{r['ld_trim']:.2f} | {r['V_pull_kmh']:.1f} | {r['fx_N']:.0f} |")
    (OUT / "calib.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
