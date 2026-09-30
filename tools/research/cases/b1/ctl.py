"""Б1, этап 1: пробные и контрольные прогоны у номинала (λ/h 0,031, lam 40, α 0,235, z0 случая) — одним списком.

Наборы (аргумент): probe — номинал обоих случаев (время, правило U10); ctl — контроль схемы и постановки:
  nom      — общая схема (2-й порядок), dx номинала            (калибровочная постановка; строка C10 без scheme_ctl)
  adv1     — 1-й порядок переноса (схема игры), dx номинала      (scheme_ctl)
  fine     — 2-й порядок, dx·2/3 (Askervein 13,33 м, Perdigão 20 м) (scheme_ctl)
  half     — 2-й порядок, dx/2 (Askervein 10 м, Perdigão 15 м)    (scheme_ctl)
  dom      — область ×1,5 и запас над рельефом ×1,5              (scheme_ctl)
  stab     — Perdigão: поток тепла по z/L данных (NE +20 Вт/м², SW −18 Вт/м²) (scheme_ctl)
  lamlo/lamhi — λ = 15 / 150 м (время и сходимость на краях сетки калибровки; строки C10)
Строка на прогон → out/ctl_runs.jsonl, продолжение с места (готовые tag пропускаются). Поля номинала и 1-го порядка
сохраняются в out/fields_<tag>.npz (разрез Perdigão вдоль ветра, карта разгона Askervein на 10 м).

  python ctl.py probe|ctl [tag …]
"""
from __future__ import annotations

import json
import math
import sys
import time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import askervein as AK     # noqa: E402
import perdigao as PD      # noqa: E402

OUT = HERE / "out"
MOD = dict(ask=AK, pd=PD)
SUBS = [("ask", "tu03b"), ("pd", "ne"), ("pd", "sw")]
FINE = dict(ask=40.0 / 3.0, pd=20.0)
HALF = dict(ask=10.0, pd=15.0)
STAB = dict(ne=20.0, sw=-18.0)       # Вт/м²: |L| ≈ 430 м (NE z/L −0,23 на 100 м), SW Ri 0,075 → z/L ≈ +0,12 на 55 м


def plan(which):
    out = []
    for case, sub in SUBS:
        m = MOD[case]
        out.append((f"{case}_{sub}_nom", case, sub, {}, m.DX_NOM, None))
        if which == "ctl":
            out.append((f"{case}_{sub}_adv1", case, sub, {}, m.DX_NOM, {"adv2": False}))
            out.append((f"{case}_{sub}_lamlo", case, sub, {"lam_frac": 0.0, "lam": 15.0}, m.DX_NOM, None))
            out.append((f"{case}_{sub}_lamhi", case, sub, {"lam_frac": 0.0, "lam": 150.0}, m.DX_NOM, None))
            out.append((f"{case}_{sub}_fine", case, sub, {}, FINE[case], {"adv2": True}))
            out.append((f"{case}_{sub}_dom", case, sub, {}, m.DX_NOM, {"dom_mul": 1.5, "top_mul": 1.5}))
            if case == "pd":
                out.append((f"{case}_{sub}_stab", case, sub, {}, m.DX_NOM, {"heat_wm2": STAB[sub]}))
    if which == "ctl":
        for case, sub in SUBS:                       # самые дорогие — в конце
            out.append((f"{case}_{sub}_half", case, sub, {}, HALF[case], {"adv2": True}))
    return out


def save_fields(tag, case, sub, row):
    S = row.pop("_S")
    u, v, w, th = S.centers()
    g = S.g
    if case == "ask":
        import synth as SY
        sp = np.sqrt(u ** 2 + v ** 2 + w ** 2)
        s10 = SY.agl(S, sp, 10.0)
        np.savez_compressed(OUT / f"fields_{tag}.npz", s10=s10.astype(np.float32), hc=S.hc.astype(np.float32),
                            x=g.x, y=g.y, rs10=row["inputs"]["rs10_model"])
    else:
        inp = PD.case_inputs(sub)
        ang = math.radians(inp["wdir"])
        ex, ey = -math.sin(ang), -math.cos(ang)
        s = np.arange(-1500.0, 1500.0 + 1e-9, 10.0)
        px, py = s * ex, s * ey
        hs = PD.surface_at(S, px, py)
        zl = np.arange(hs.min() - 5, hs.max() + 700.0, 10.0)
        U = np.full((len(zl), len(s)), np.nan)
        W = np.full_like(U, np.nan)
        for k, z in enumerate(zl):
            ok = z >= hs
            if ok.any():
                U[k, ok] = PD.sample(S, u, px[ok], py[ok], z) * ex + PD.sample(S, v, px[ok], py[ok], z) * ey
                W[k, ok] = PD.sample(S, w, px[ok], py[ok], z)
        np.savez_compressed(OUT / f"fields_{tag}.npz", s=s, z=zl + PD.BASE, hs=hs + PD.BASE, upar=U.astype(np.float32),
                            w=W.astype(np.float32), sref=row["inputs"]["sref_model"])
    import model as M
    M.free(S)


def main():
    which = sys.argv[1] if len(sys.argv) > 1 else "probe"
    only = set(sys.argv[2:])
    OUT.mkdir(exist_ok=True)
    f = OUT / "ctl_runs.jsonl"
    done = set()
    if f.exists():
        done = {json.loads(line)["tag"] for line in f.read_text().splitlines() if line.strip()}
    t0 = time.perf_counter()
    for tag, case, sub, over, dx, ctl in plan(which):
        if tag in done or (only and tag not in only):
            continue
        keep = tag.endswith(("_nom", "_adv1"))
        t1 = time.perf_counter()
        r = MOD[case].run_one(over, sub, dx, ctl=ctl, keep=keep)
        r["tag"] = tag
        r["wall_total"] = round(time.perf_counter() - t1, 1)
        if keep and "_S" in r:
            save_fields(tag, case, sub, r)
        with open(f, "a") as fh:
            fh.write(json.dumps(r) + "\n")
        print(f"{tag}: dx={dx:g} {r['status']} {r['iters']} it, решатель {r['t']:.1f} с, всего {r['wall_total']} с, "
              f"замок {r.get('t_lock_wait', 0)} с, клеток {r.get('geo', {}).get('n_cells')} ({time.perf_counter() - t0:.0f} с)",
              flush=True)


if __name__ == "__main__":
    main()
