#!/usr/bin/env python3
"""Контрактный тест R5 v1 (docs/contracts/picard-rs.md): случаи T+15 мин для тёплого старта.

    python3 check_r5.py ~/data/air_cascade/ongudai/ongudai_d400_u3_heat_h1215.json [...]

Проверяет (дополнительно к R1 — его гоняет check_contract.py --ref):
  * имя `ongudai_d400_u<U10>_<heat|mech>_h<ЧЧММ>`, source.hour = ЧЧ + ММ/60;
  * source.warm_from — существующий случай на T (…_h1200 или фикстурный 12:00), там сетка/область/params/criterion
    те же, а hour меньше на 0,25 ч (recompute_game_min = 15);
  * source.changed — список {name, max_abs, rms, source «файл:функция»}; он ровно совпадает с реальной разницей
    входных массивов (R1_CONST) между случаем и warm_from в .bin (max|Δ| ±1e-6 отн.), а не перечисленные массивы
    побитно равны; для heat список не пуст; для mech пуст — если вход действительно не меняется (список
    source.unchanged непуст) — иначе ошибка;
  * source.changed_game_inputs (H, gam, z_i, profile, wind) — есть; wind.changed булево;
  * эталон: solution.status ok, iters = последний it истории, sol_* есть и конечны, float64-эталон air.py.
Выход 0 — контракт держится, 1 — нарушения (stderr).
"""
from __future__ import annotations

import json
import math
import re
import sys
from pathlib import Path

import numpy as np

CONST = ["hc", "cell", "tu", "tv", "tw", "nu_bg", "Q", "gam", "cplz", "sp_u", "sp_w", "spc", "ubg", "vbg",
         "lam", "Kx", "Ky", "Kz", "fixed_u", "fixed_v", "b_u", "b_v"]
SOL = ["sol_u", "sol_v", "sol_w", "sol_th", "sol_thd", "sol_p"]
SAME = ["dims", "halo", "dx", "dz", "z_bot", "x0", "y0", "nx", "ny", "nz", "params", "criterion", "mg_levels_xyz"]
NAME = re.compile(r"^ongudai_d400_u(\d+)_(heat|mech)_h(\d{2})(\d{2})$")
STEP_H = 0.25
errors: list[str] = []


def err(m):
    errors.append(m)


def load(path: Path):
    d = json.loads(path.read_text())
    raw = np.fromfile(path.with_suffix(".bin"), "<f4")
    return d, raw


def arr(d, raw, k):
    o, n = d["arrays"][k]
    return raw[o:o + n]


def warm_path(path: Path, name: str) -> Path:
    return path.with_name(f"{name}.json")


def check(path: Path) -> None:
    w = path.name
    if not path.exists() or not path.with_suffix(".bin").exists():
        return err(f"{w}: нет .json/.bin")
    d, raw = load(path)
    m = NAME.match(path.stem)
    if not m:
        return err(f"{w}: имя не ongudai_d400_u<U10>_<heat|mech>_h<ЧЧММ>")
    heat = m.group(2) == "heat"
    hh = int(m.group(3)) + int(m.group(4)) / 60.0
    if d.get("format") != "ref-case" or d.get("version") != 1:
        err(f"{w}: format/version")
    s = d.get("source", {})
    for k in ("hour", "warm_from", "changed"):
        if k not in s:
            return err(f"{w}: source.{k} нет")
    if abs(s["hour"] - hh) > 1e-9:
        err(f"{w}: source.hour {s['hour']} ≠ {hh} из имени")
    if d["case"] != path.stem:
        err(f"{w}: case {d['case']} ≠ имени")
    if s.get("dtype") != "float64":
        err(f"{w}: эталон не float64")
    if s.get("heat") != heat:
        err(f"{w}: source.heat ≠ имени")
    sol = d["solution"]
    if sol.get("status") != "ok":
        err(f"{w}: solution.status {sol.get('status')}")
    if not d["history"] or d["history"][-1]["it"] != sol["iters"]:
        err(f"{w}: iters ≠ последний it истории")
    for k in SOL:
        a = arr(d, raw, k)
        if not np.all(np.isfinite(a)):
            err(f"{w}: {k} не конечен")
    # --- случай на T
    wp = warm_path(path, s["warm_from"])
    if not wp.exists():
        return err(f"{w}: warm_from {s['warm_from']} нет в {path.parent}")
    d0, raw0 = load(wp)
    s0 = d0.get("source", {})
    h0 = s0.get("hour", 12.0)
    if abs((s["hour"] - h0) - STEP_H) > 1e-9:
        err(f"{w}: hour − hour(warm_from) = {s['hour'] - h0} ≠ {STEP_H} (recompute_game_min 15)")
    for k in SAME:
        if d[k] != d0[k]:
            err(f"{w}: {k} ≠ warm_from")
    if s0.get("heat") != heat or s0.get("U10") != s.get("U10"):
        err(f"{w}: heat/U10 ≠ warm_from")
    if d["case_params"]["wdir"] != d0["case_params"]["wdir"]:
        err(f"{w}: wdir ≠ warm_from (ветер за 15 мин не меняется)")
    # --- changed против бин-разницы
    listed = {}
    for c in s["changed"]:
        for k in ("name", "max_abs", "rms", "source"):
            if k not in c:
                err(f"{w}: changed[{c.get('name')}] нет '{k}'")
        if not re.search(r"\.gd:\w+", str(c.get("source", ""))) and "air.py" not in str(c.get("source", "")):
            err(f"{w}: changed[{c.get('name')}].source не «файл:функция»")
        listed[c["name"]] = c
    for k in CONST:
        a, a0 = arr(d, raw, k).astype(np.float64), arr(d0, raw0, k).astype(np.float64)
        if a.shape != a0.shape:
            err(f"{w}: {k} размер ≠ warm_from")
            continue
        dd = a - a0
        mx = float(np.max(np.abs(dd))) if dd.size else 0.0
        if k in listed:
            c = listed[k]
            if mx == 0.0:
                err(f"{w}: {k} в changed, но равен warm_from")
            elif abs(c["max_abs"] - mx) > 1e-6 * max(mx, 1e-30):
                err(f"{w}: changed[{k}].max_abs {c['max_abs']:.6e} ≠ {mx:.6e}")
        elif mx != 0.0:
            err(f"{w}: {k} отличается от warm_from (max|Δ| {mx:.3e}), но нет в changed")
    if heat and not listed:
        err(f"{w}: heat — changed пуст (нагрев по часу меняется)")
    if "Q" in listed and not heat:
        err(f"{w}: mech, но Q изменился")
    if not heat and not listed and not s.get("unchanged"):
        err(f"{w}: mech без изменений, но нет source.unchanged")
    g = s.get("changed_game_inputs")
    if not g:
        err(f"{w}: source.changed_game_inputs нет")
    else:
        for k in ("H", "gam", "z_i", "profile", "wind"):
            if k not in g:
                err(f"{w}: changed_game_inputs.{k} нет")
        if not isinstance(g.get("wind", {}).get("changed"), bool):
            err(f"{w}: changed_game_inputs.wind.changed не bool")
        if g.get("wind", {}).get("changed") and "wdir" in listed:
            pass
    print(f"{w}: hour {s['hour']}, warm_from {s['warm_from']}, iters {sol['iters']}, changed {sorted(listed)}",
          flush=True)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    for a in sys.argv[1:]:
        check(Path(a).expanduser())
    for e in errors:
        print("ОШИБКА:", e, file=sys.stderr)
    print("R5 OK" if not errors else f"R5 FAIL ({len(errors)})")
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
