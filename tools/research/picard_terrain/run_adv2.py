#!/usr/bin/env python3
"""PT-3: прогоны picard_rs со вторым порядком переноса (ван Лир = 1, minmod = 3) на случаях PT1.

Каждый случай × ограничитель: `picard solve <case> --adv2 <имя> --threads 8 --max-iters 4000 --out
out/PT-3/r2/<case>_l<L>.json --save-state D/states/<case>_adv2_l<L>.json`, затем строка PT4 в
out/PT-3/rows.jsonl (sample.py PT-1 → пробы S, dS) и итог out/PT-3/table.md (база — out/PT-1/rows.jsonl).
Только solve (8 слотов замка cpu); время замеряет отдельная задача через bench, здесь locked=false:

    python3 tools/research/picard_terrain/run_adv2.py      # каждый solve — под `dpcli lock cpu` (8 слотов)
    python3 tools/research/picard_terrain/run_adv2.py --table-only        # только пересобрать table.md

Статус: ok (критерий достигнут), diverged, max (предел итераций), stalled — предел, и невязка импульса не
упала вдвое за последние 50 % итераций (PT4); для stalled в note — уровень невязки импульса.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
D = Path(os.environ.get("PICARD_TERRAIN_DATA", Path.home() / "data/picard_terrain"))
BIN = ROOT / "rust/picard_rs/target/release/picard"
OUT = HERE / "out/PT-3"
CASES = ["askervein_d50", "askervein_d100", "kayancha_d50", "kayancha_d100", "perdigao_ne_d30", "perdigao_sw_d30"]
LIMS = {1: "vanleer", 3: "minmod"}
THREADS = 8
MAX_ITERS = 4000


def stalled(hist: list[dict], iters: int):
    """Невязка импульса за последние 50 % итераций упала меньше чем вдвое → (True, уровень), иначе (False, None)."""
    if len(hist) < 4:
        return False, None
    last = hist[-1]
    half = [h for h in hist if h["it"] <= iters / 2]
    if not half:
        return False, None
    if last["mom_rms"] > 0.5 * half[-1]["mom_rms"]:
        return True, last["mom_rms"]
    return False, None


def get_probes(case: str, st: Path):
    cj = D / "cases" / f"{case}.json"
    try:
        sys.path.insert(0, str(HERE))
        import sample  # PT-1 (numpy, h5py: интерпретатор sw_charges_3d/py)
    except ImportError as e:
        return [], f"; sample.py не импортируется ({e}) — пробы пусты"
    probes = sample.probe_values(str(cj), str(st))
    pair = {p["name"]: p["pair"] for p in json.loads(cj.read_text())["pt"]["probes"]}
    sv = {p["name"]: p["S"] for p in probes}
    for p in probes:
        if "dS" not in p:
            q = pair.get(p["name"])
            p["dS"] = (p["S"] / sv[q] - 1.0) if q else None
    return [{k: p.get(k) for k in ("name", "z_agl", "S", "dS")} for p in probes], ""


def resample():
    rows = load_rows(OUT / "rows.jsonl")
    for r in rows:
        r["probes"], extra = get_probes(r["case"], D / r["state"])
        r["note"] = r["note"].split("; sample.py")[0] + extra
    with open(OUT / "rows.jsonl", "w") as fh:
        for r in rows:
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")


def run_one(case: str, lim: int, locked: bool) -> dict:
    name = f"{case}_l{lim}"
    r2p = OUT / "r2" / f"{name}.json"
    st = D / "states" / f"{case}_adv2_l{lim}.json"
    cj = D / "cases" / f"{case}.json"
    cmd = [str(ROOT / ".dpcli/dpcli"), "lock", "cpu", "PT-3", "--no-tmux", "--", str(BIN), "solve", str(cj), "--adv2", LIMS[lim], "--threads", str(THREADS), "--max-iters", str(MAX_ITERS),
           "--out", str(r2p), "--save-state", str(st)]
    print("$", " ".join(cmd), flush=True)
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL)
    r2 = json.loads(r2p.read_text())
    res = r2.get("residuals") or r2["history"][-1]
    hist = r2["history"]
    status = {"ok": "ok", "diverged": "diverged"}.get(r2["status"], "max")
    note = f"adv2 {LIMS[lim]} (limiter {lim}), {THREADS} потоков"
    if status == "max":
        s, lvl = stalled(hist, r2["iters"])
        if s:
            status = "stalled"
            note += f"; невязка импульса стоит на {lvl:.2e} м/с²"
    probes, extra = get_probes(case, st)
    note += extra
    t = r2["time"]
    return {
        "format": "pt-row", "version": 1, "task": "PT-3", "case": case, "site": case.rsplit("_d", 1)[0],
        "dx": json.loads(cj.read_text())["dx"], "solver": "picard_rs", "dtype": "f32",
        "cut_cells": bool(r2["variant"]["cut_cells"]), "adv2": True, "limiter": lim,
        "status": status, "iters": r2["iters"], "max_iters": MAX_ITERS,
        "final": {"mom_rms": res["mom_rms"], "th_rms": res["th_rms"], "div_rms": res["div_rms"]},
        "time": {"total_s": t["total_s"], "ms_per_iter": t["ms_per_iter"], "threads": THREADS, "locked": locked},
        "r2": str(r2p.relative_to(ROOT)), "state": f"states/{case}_adv2_l{lim}.json", "probes": probes, "rotor": None, "masts_rmse": None,
        "note": note,
    }


def load_rows(p: Path):
    return [json.loads(x) for x in p.read_text().splitlines() if x.strip()] if p.exists() else []


def table():
    rows = load_rows(OUT / "rows.jsonl")
    pt1 = load_rows(HERE / "out/PT-1/rows.jsonl")
    base = {r["case"]: r for r in pt1 if r["solver"] == "picard_rs" and not r["adv2"] and not r["cut_cells"]}
    ref = {r["case"]: r for r in pt1 if r["solver"] == "air3d" and r["adv2"]}
    lname = {1: "ван Лир", 3: "minmod"}

    def pv(r, name, key):
        for p in r["probes"]:
            if p["name"] == name:
                return p[key]
        return None

    def f(x, fmt):
        return "—" if x is None else format(x, fmt)

    def line(label, r, names, key, fmt, tail=""):
        return f"| {label} | " + " | ".join(f(pv(r, n, key), fmt) for n in names) + f" |{tail}"

    L = ["# PT-3: ограниченный 2-й порядок переноса в picard_rs", "",
         "picard_rs f32, `solve` 8 слотов замка (locked = false), до 4000 итераций, критерий случая. Выборка — sample.py PT-1 "
         "(на d50/d100 «10 м» = значение нижней клетки воздуха, она выше 10 м). **мс/итер. здесь не для сравнения** "
         "(соседние задачи на машине; время — отдельный замер bench). Итер. — проверка (раз в 10), на которой сработал критерий.", ""]
    ask = ["HT_10", "HT_30", "HT_60", "HT_100"]
    L += ["## Askervein: ΔS = S(HT)/S(RS) − 1 на той же высоте над землёй", "",
          "| вариант | 10 м | 30 м | 60 м | 100 м | итер. | статус | невязка имп. |", "|---|---|---|---|---|---|---|---|"]
    for c in ("askervein_d100", "askervein_d50"):
        d = c.split("_")[1]
        if c in base:
            b = base[c]
            L.append(line(f"{d} 1-й порядок (база)", b, ask, "dS", "+.2f", f" {b['iters']} | {b['status']} | {b['final']['mom_rms']:.1e} |"))
        for r in sorted((r for r in rows if r["case"] == c), key=lambda r: r["limiter"]):
            L.append(line(f"{d} 2-й, {lname[r['limiter']]}", r, ask, "dS", "+.2f", f" {r['iters']} | {r['status']} | {r['final']['mom_rms']:.1e} |"))
    for c in ("askervein_d25", "askervein_d12p5"):
        if c in ref:
            r = ref[c]
            L.append(line(f"{c.split('_')[1]} air3d f64, 2-й (эталон)", r, ask, "dS", "+.2f", f" {r['iters']} | {r['status']} | |"))
    st = ["START_20", "START_30", "START_50", "START_100"]
    L += ["", "## Каянча: S над стартом, м/с", "", "| вариант | 20 м | 30 м | 50 м | 100 м | итер. | статус | невязка имп. |", "|---|---|---|---|---|---|---|---|"]
    for c in ("kayancha_d100", "kayancha_d50"):
        d = c.split("_")[1]
        if c in base:
            b = base[c]
            L.append(line(f"{d} 1-й порядок (база)", b, st, "S", ".2f", f" {b['iters']} | {b['status']} | {b['final']['mom_rms']:.1e} |"))
        for r in sorted((r for r in rows if r["case"] == c), key=lambda r: r["limiter"]):
            L.append(line(f"{d} 2-й, {lname[r['limiter']]}", r, st, "S", ".2f", f" {r['iters']} | {r['status']} | {r['final']['mom_rms']:.1e} |"))
    if "kayancha_d25" in ref:
        r = ref["kayancha_d25"]
        L.append(line("d25 air3d f64, 2-й (эталон)", r, st, "S", ".2f", f" {r['iters']} | {r['status']} | |"))
    L += ["", "## Сходимость на крутом (Perdigão 30 м), итерации и невязка импульса", "",
          "| случай | вариант | статус | итер. | невязка имп. | мс/итер. (справочно) |", "|---|---|---|---|---|---|"]
    for c in ("perdigao_ne_d30", "perdigao_sw_d30"):
        if c in base:
            b = base[c]
            L.append(f"| {c} | 1-й (база) | {b['status']} | {b['iters']} | {b['final']['mom_rms']:.1e} | {b['time']['ms_per_iter']:.0f} |")
        for r in sorted((r for r in rows if r["case"] == c), key=lambda r: r["limiter"]):
            L.append(f"| {c} | 2-й, {lname[r['limiter']]} | {r['status']} | {r['iters']} | {r['final']['mom_rms']:.1e} | {r['time']['ms_per_iter']:.0f} |")
    (OUT / "table.md").write_text("\n".join(L) + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--locked", action="store_true", help="запуск под замком cpu (пишется в time.locked)")
    ap.add_argument("--table-only", action="store_true")
    ap.add_argument("--resample", action="store_true", help="пересчитать пробы строк по сохранённым состояниям")
    ap.add_argument("--cases", nargs="*", default=CASES)
    ap.add_argument("--lims", nargs="*", type=int, default=[1, 3])
    a = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    if a.resample:
        resample()
    elif not a.table_only:
        subprocess.run(["cargo", "build", "-q", "--release", "--manifest-path", str(ROOT / "rust/picard_rs/Cargo.toml")], check=True)
        rows = {(r["case"], r["limiter"]): r for r in load_rows(OUT / "rows.jsonl")}
        for case in a.cases:
            for lim in a.lims:
                rows[(case, lim)] = run_one(case, lim, a.locked)
                with open(OUT / "rows.jsonl", "w") as fh:
                    for k in sorted(rows):
                        fh.write(json.dumps(rows[k], ensure_ascii=False) + "\n")
    table()


if __name__ == "__main__":
    main()
