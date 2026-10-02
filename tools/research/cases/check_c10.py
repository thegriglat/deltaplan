"""Контрактный тест C10 v2 (docs/contracts/air-model.md): модуль случая калибровки → совместная калибровка.

Проверяет форму на стыке без GPU: observations() модуля и строки прогонов run_one из файла(ов) jsonl.
Сам решатель не запускает (import модуля может тянуть CuPy — запускать venv калибровки).

  python check_c10.py <модуль> [runs.jsonl …]      (модуль — имя файла в этом каталоге без .py)

Код выхода 0 — форма в порядке, 1 — нарушения (печатаются).
"""
from __future__ import annotations

import importlib
import json
import math
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import scheme as SC  # noqa: E402

OBS_FIELDS = {"name": str, "grp": str, "data": float, "sig": float, "sig_grid": float, "grid_corr": float,
              "unit": str, "subcase": str, "src": str}
ROW_FIELDS = {"case": str, "subcase": str, "dx": float, "params": dict, "status": str, "iters": int, "t": float,
              "obs": dict}
STATUS = {"ok", "max", "diverged", "error"}


def _num(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool)


def check_module(mod):
    err = []
    for attr in ("NAME", "SUBCASES", "SETUP", "observations", "run_one"):
        if not hasattr(mod, attr):
            err.append(f"нет атрибута {attr}")
    if err:
        return err, []
    if not isinstance(mod.NAME, str) or not mod.NAME:
        err.append("NAME — непустая строка")
    subs = list(mod.SUBCASES)
    if not subs or not all(isinstance(s, str) and s for s in subs):
        err.append("SUBCASES — непустой список строк")
    setup = mod.SETUP
    for sub in subs:
        s = setup.get(sub, setup) if isinstance(setup, dict) else {}
        miss = [k for k in SC.SETUP_KEYS if k not in s]
        if miss:
            err.append(f"SETUP[{sub}]: нет {miss}")
    obs = mod.observations()
    if not isinstance(obs, list) or not obs:
        return err + ["observations() — непустой список"], []
    names = set()
    for i, o in enumerate(obs):
        for k, t in OBS_FIELDS.items():
            if k not in o:
                err.append(f"obs[{i}]: нет поля {k}")
            elif t is float and not _num(o[k]):
                err.append(f"obs[{i}].{k}: не число")
            elif t is str and not isinstance(o[k], str):
                err.append(f"obs[{i}].{k}: не строка")
        n = o.get("name")
        if n in names:
            err.append(f"obs: имя {n} повторяется")
        names.add(n)
        if isinstance(n, str) and not n.startswith(mod.NAME + "_"):
            err.append(f"obs {n}: имя без префикса случая «{mod.NAME}_»")
        if _num(o.get("sig")) and not (o["sig"] > 0 and math.isfinite(o["sig"])):
            err.append(f"obs {n}: sig > 0 и конечна")
        if _num(o.get("sig_grid")) and not o["sig_grid"] >= 0:
            err.append(f"obs {n}: sig_grid ≥ 0")
        if _num(o.get("data")) and not math.isfinite(o["data"]):
            err.append(f"obs {n}: data конечна")
        if o.get("subcase") not in subs:
            err.append(f"obs {n}: subcase {o.get('subcase')} не из SUBCASES")
    return err, obs


def check_row(row, obs, name, where):
    err = []
    for k, t in ROW_FIELDS.items():
        if k not in row:
            err.append(f"{where}: нет поля {k}")
            continue
        v = row[k]
        ok = (_num(v) if t is float else isinstance(v, int) and not isinstance(v, bool) if t is int
              else isinstance(v, t))
        if not ok:
            err.append(f"{where}.{k}: тип {type(v).__name__}, нужен {t.__name__}")
    if err:
        return err
    if row["case"] != name:
        err.append(f"{where}: case {row['case']} ≠ {name}")
    if row["status"] not in STATUS:
        err.append(f"{where}: status {row['status']} не из {sorted(STATUS)}")
    for key in ("lam_frac", "lam", "alpha", "z0", "pr_t", "local_k", "closure", "heat_mode"):
        if key not in row["params"]:
            err.append(f"{where}: params без {key} (нужны все поля Params как применены)")
    if not row.get("scheme_ctl", False):
        for k, v in SC.SCHEME.items():
            if row["params"].get(k) != v:
                err.append(f"{where}: params.{k} = {row['params'].get(k)!r} ≠ общей схеме {v!r} (scheme.py; контроль — scheme_ctl)")
    if row["status"] == "ok":
        want = {o["name"] for o in obs if o["subcase"] == row["subcase"]}
        miss = want - set(row["obs"])
        if miss:
            err.append(f"{where}: obs без {sorted(miss)[:5]}{' …' if len(miss) > 5 else ''}")
        for k, v in row["obs"].items():
            if not (_num(v) or v is None):
                err.append(f"{where}: obs.{k} не число (NaN пишется как null или NaN)")
    return err


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    mod = importlib.import_module(argv[1])
    err, obs = check_module(mod)
    nrow = 0
    for f in argv[2:]:
        for i, line in enumerate(Path(f).read_text().splitlines()):
            if not line.strip():
                continue
            nrow += 1
            err += check_row(json.loads(line), obs, mod.NAME, f"{Path(f).name}:{i + 1}")
    for e in err:
        print("C10:", e)
    print(f"C10 {argv[1]}: наблюдаемых {len(obs)}, строк {nrow}, нарушений {len(err)}")
    return 1 if err else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
