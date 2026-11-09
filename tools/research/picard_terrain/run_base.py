"""PT-1: база picard_rs (1-й порядок, без срезанных клеток), строки PT4 и таблица `out/PT-1/table.md`.

  PY=tools/research/sw_charges_3d/py
  $PY tools/research/picard_terrain/run_base.py solve [case ...]   # picard solve каждого случая под замком cpu -> r2/, D/states/
  $PY tools/research/picard_terrain/run_base.py rows               # rows.jsonl из r2/, air3d_runs/ и снимков
  $PY tools/research/picard_terrain/run_base.py table              # table.md

Каждый `picard solve` - отдельный запуск `.dpcli/dpcli lock cpu PT-1 --no-tmux -- …` (вес замка по команде - вся машина,
время сравнимо: time.locked = true, threads 8). Функции row_picard/row_air3d используют и другие задачи модуля.
"""
from __future__ import annotations

import json
import math
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(HERE))
import sample as SM  # noqa: E402

D = SM.data_dir()
OUT = HERE / "out" / "PT-1"
BIN = ROOT / "rust/picard_rs/target/release/picard"
THREADS = 8
MAX_ITERS = 4000
BASE = ["askervein_d100", "askervein_d50", "kayancha_d100", "kayancha_d50", "perdigao_ne_d30", "perdigao_sw_d30"]
REFS = ["askervein_d25", "askervein_d12p5", "kayancha_d25"]
AIR3D_ALL = ["askervein_d100", "askervein_d50", "askervein_d25", "askervein_d12p5",
             "kayancha_d100", "kayancha_d50", "kayancha_d25", "perdigao_ne_d30", "perdigao_sw_d30"]


def run_solve(case, variant="base", extra=(), out_dir=OUT / "r2", threads=THREADS):
    """picard solve под замком cpu; -> (путь R2, путь R4)."""
    out_dir.mkdir(parents=True, exist_ok=True)
    r2 = out_dir / f"{case}_{variant}.json"
    st = D / "states" / f"{case}_{variant}.json"
    cmd = [str(ROOT / ".dpcli/dpcli"), "lock", "cpu", "PT-1", "--no-tmux", "--", str(BIN.relative_to(ROOT)), "solve",
           str(D / "cases" / f"{case}.json"), "--threads", str(threads), "--max-iters", str(MAX_ITERS),
           "--out", str(r2.relative_to(ROOT)), "--save-state", str(st), *extra]
    subprocess.run(cmd, cwd=ROOT, check=True)
    return r2, st


def stalled(hist, crit, status):
    """PT4: критерий не достигнут и невязка не убывает (меньше чем в 2 раза за последние 50 % итераций).
    Мера - max(mom_rms/tol_mom, div_rms/tol_div) в проверке; сравниваются проверки на it/2 и it."""
    if status == "ok" or len(hist) < 4:
        return False
    def m(h):
        return max(h["mom_rms"] / crit["tol_mom_rms"], h["div_rms"] / crit["tol_div_rms"])
    last = hist[-1]
    half = min(hist, key=lambda h: abs(h["it"] - last["it"] / 2))
    return m(last) > 0.5 * m(half)


def probes_rows(case_json, state_json):
    vals = SM.probe_values(case_json, state_json)
    d = SM.dS(case_json, vals)
    return [dict(name=v["name"], z_agl=v["z_agl"], S=v["S"], dS=d[v["name"]]) for v in vals]


def row_picard(task, case, r2_path, state_path, cut_cells=False, adv2=False, limiter=None, note="", locked=True):
    """Строка PT4 из R2 (picard_rs) и снимка R4."""
    r2 = json.loads(Path(r2_path).read_text())
    cj = D / "cases" / f"{case}.json"
    meta = json.loads(cj.read_text())
    hist = r2["history"]
    last = hist[-1]
    status = r2["status"]
    if status == "max" and stalled(hist, meta["criterion"], status):
        status = "stalled"
    f = lambda k: last.get(k)
    return dict(format="pt-row", version=1, task=task, case=case, site=meta["pt"]["site"], dx=meta["dx"], solver="picard_rs",
                dtype="f32", cut_cells=cut_cells, adv2=adv2, limiter=limiter, status=status, iters=r2["iters"],
                max_iters=MAX_ITERS, final=dict(mom_rms=f("mom_rms"), th_rms=f("th_rms"), div_rms=f("div_rms")),
                time=dict(total_s=r2["time"]["total_s"], ms_per_iter=r2["time"]["ms_per_iter"], threads=r2["threads"], locked=locked),
                r2=str(Path(r2_path).relative_to(ROOT)), state=str(Path(state_path).relative_to(D)),
                probes=probes_rows(cj, state_path), rotor=None, masts_rmse=None,
                note=note or (f"u_rel против air3d f64 1-й порядок: {r2['dev']['u_rel']:.2e}" if r2["dev"]["u_rel"] is not None else ""))


def row_air3d(task, case):
    """Строка PT4 из справки make_cases (out/PT-1/air3d_runs/<case>.json) и снимка D/states/<case>_air3d."""
    a = json.loads((OUT / "air3d_runs" / f"{case}.json").read_text())
    cj = D / "cases" / f"{case}.json"
    return dict(format="pt-row", version=1, task=task, case=case, site=a["site"], dx=a["dx"], solver="air3d", dtype=a.get("dtype", "f64"),
                cut_cells=False, adv2=a["adv2"], limiter=a["limiter"], status=a["status"], iters=a["iters"],
                max_iters=a["max_iters"], final=a["final"],
                time=dict(total_s=a["t_solve_s"], ms_per_iter=a["ms_per_iter"], threads=None, locked=False),
                r2=None, state=a["state"], probes=probes_rows(cj, D / a["state"]), rotor=None, masts_rmse=None,
                note=f"GPU RTX 4070 SUPER, CuPy {a.get('dtype', 'f64')}, без замка; время справочно" + ("; эталон 2-й порядок (ван Лир)" if a["adv2"] else "; 1-й порядок"))


def cmd_solve(names):
    for c in names or BASE:
        r2, st = run_solve(c)
        print("done", c, r2, flush=True)


def cmd_rows():
    rows = []
    for c in BASE:
        r2 = OUT / "r2" / f"{c}_base.json"
        if r2.exists():
            rows.append(row_picard("PT-1", c, r2, D / "states" / f"{c}_base.json"))
    for c in AIR3D_ALL:
        if (OUT / "air3d_runs" / f"{c}.json").exists():
            rows.append(row_air3d("PT-1", c))
    (OUT / "rows.jsonl").write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows))
    print(f"rows: {len(rows)}")


# ----------------------------------------------------------------------------------------------------- таблица
PRIMER_ASK = {"измерено HT (к RS на той же высоте; 24–34 м: 0,60–0,44)": [0.82, None, None, None],
              "primer 8.2: модель 50 м, 1-й порядок (8 км)": [0.28, 0.19, 0.20, 0.19],
              "primer 8.2: модель 12,5 м, 2-й порядок (4 км)": [0.61, 0.55, 0.39, 0.28]}
PRIMER_KAY = [0.80, 0.83, 0.84, 0.92]


def _fmt(x, p=2):
    return "—" if x is None else f"{x:.{p}f}".replace(".", ",")


def _row(rows, case, solver):
    for r in rows:
        if r["case"] == case and r["solver"] == solver and not r["cut_cells"]:
            if solver == "picard_rs" and r["adv2"]:
                continue
            if solver == "air3d" and r["adv2"] != (r["dx"] <= 25):
                continue
            return r
    return None


def _p(r, name):
    return next((p for p in r["probes"] if p["name"] == name), None)


def cmd_table():
    rows = [json.loads(l) for l in (OUT / "rows.jsonl").read_text().splitlines() if l.strip()]
    L = ["# PT-1: база picard_rs и эталон air3d", "",
         "Случаи: `D/cases/*` (PT1), выборка PT5 (`sample.py`: растр подсетки 30 м, z_agl над растром), строки — `rows.jsonl`. "
         "picard_rs — 1-й порядок, без срезанных клеток, f32, 8 потоков под замком cpu; air3d — CuPy f64 на GPU: "
         "dx 25 и 12,5 м — 2-й порядок (ван Лир), 100/50 м — 1-й порядок (справочно). Область 4 км, верх 1000 м; "
         "число итераций — проверка, на которой сработал критерий (раз в 10).", ""]
    L += ["## Askervein: разгон ΔS на вершине HT к RS на той же высоте над землёй", "",
          "| случай / решатель | 10 м | 30 м | 60 м | 100 м | итер. | мс/итер. | статус |", "|---|---|---|---|---|---|---|---|"]
    for c, s, lab in (("askervein_d100", "picard_rs", "d100 picard_rs 1-й"), ("askervein_d50", "picard_rs", "d50 picard_rs 1-й"),
                      ("askervein_d100", "air3d", "d100 air3d 1-й (f64)"), ("askervein_d50", "air3d", "d50 air3d 1-й (f64)"),
                      ("askervein_d25", "air3d", "d25 air3d 2-й (ван Лир)"), ("askervein_d12p5", "air3d", "d12p5 air3d 2-й (ван Лир)")):
        r = _row(rows, c, s)
        if r:
            L.append(f"| {lab} | " + " | ".join(_fmt(_p(r, f'HT_{z}')["dS"]) for z in (10, 30, 60, 100)) +
                     f" | {r['iters']} | {_fmt(r['time']['ms_per_iter'], 1)} | {r['status']} |")
    for k, v in PRIMER_ASK.items():
        L.append(f"| {k} | " + " | ".join(_fmt(x) for x in v) + " | | | |")
    # старое правило (земля модели) для сверки с primer
    L += ["", "Справочно, старое правило выборки (над землёй модели, а не растром подсетки) — только для сверки с primer, в `rows` не входит:", "",
          "| случай / решатель | 10 м | 30 м | 60 м | 100 м |", "|---|---|---|---|---|"]
    for c, s, lab, stp in (("askervein_d100", "picard_rs", "d100 picard_rs 1-й", "base"), ("askervein_d50", "picard_rs", "d50 picard_rs 1-й", "base"),
                           ("askervein_d25", "air3d", "d25 air3d 2-й", "air3d"), ("askervein_d12p5", "air3d", "d12p5 air3d 2-й", "air3d")):
        cj, st = D / "cases" / f"{c}.json", D / "states" / f"{c}_{stp}.json"
        if st.exists():
            d = SM.dS(cj, SM.probe_values(cj, st, ground="model"))
            L.append(f"| {lab} | " + " | ".join(_fmt(d[f'HT_{z}']) for z in (10, 30, 60, 100)) + " |")
    # Каянча
    L += ["", "## Каянча: скорость S над стартом (м/с) и отношение к d25 (air3d, 2-й порядок, ван Лир)", "",
          "| случай / решатель | 20 м | 30 м | 50 м | 100 м | итер. | мс/итер. | статус |", "|---|---|---|---|---|---|---|---|"]
    ref = _row(rows, "kayancha_d25", "air3d")
    for c, s, lab in (("kayancha_d100", "picard_rs", "d100 picard_rs 1-й"), ("kayancha_d50", "picard_rs", "d50 picard_rs 1-й"),
                      ("kayancha_d25", "air3d", "d25 air3d 2-й")):
        r = _row(rows, c, s)
        if r:
            L.append(f"| {lab} S | " + " | ".join(_fmt(_p(r, f'START_{z}')["S"]) for z in (20, 30, 50, 100)) +
                     f" | {r['iters']} | {_fmt(r['time']['ms_per_iter'], 1)} | {r['status']} |")
            if ref and r is not ref:
                L.append(f"| {lab} / d25 | " + " | ".join(_fmt(_p(r, f'START_{z}')["S"] / _p(ref, f'START_{z}')["S"]) for z in (20, 30, 50, 100)) + " | | | |")
    L.append("| primer 8.2: d50, 1-й / d25, 2-й | " + " | ".join(_fmt(x) for x in PRIMER_KAY) + " | | | |")
    # Perdigão
    L += ["", "## Perdigão (база; ротор — PT-4)", "", "| случай | статус | итер. | мс/итер. | всего, с | u_rel против air3d f64 |", "|---|---|---|---|---|---|"]
    for c in ("perdigao_ne_d30", "perdigao_sw_d30"):
        r = _row(rows, c, "picard_rs")
        if r:
            dev = json.loads((ROOT / r["r2"]).read_text())["dev"]["u_rel"]
            L.append(f"| {c} | {r['status']} | {r['iters']} | {_fmt(r['time']['ms_per_iter'], 1)} | {_fmt(r['time']['total_s'], 1)} | {dev:.2e} |")
    # Все прогоны
    L += ["", "## Все прогоны picard_rs: невязки и сверка порта с air3d f64 (1-й порядок)", "",
          "| случай | статус | итер. (air3d) | mom_rms | div_rms | мс/итер. | всего, с | u_rel | th_abs |", "|---|---|---|---|---|---|---|---|---|"]
    for c in BASE:
        r = _row(rows, c, "picard_rs")
        if r:
            r2 = json.loads((ROOT / r["r2"]).read_text())
            L.append(f"| {c} | {r['status']} | {r['iters']} ({r2['iters_ref']}) | {r['final']['mom_rms']:.2e} | {r['final']['div_rms']:.2e} | "
                     f"{_fmt(r['time']['ms_per_iter'], 1)} | {_fmt(r['time']['total_s'], 1)} | {r2['dev']['u_rel']:.2e} | {r2['dev']['th_abs']:.2e} |")
    (OUT / "table.md").write_text("\n".join(L) + "\n")
    print("table.md written")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    {"solve": lambda: cmd_solve(sys.argv[2:]), "rows": cmd_rows, "table": cmd_table}.get(cmd, lambda: sys.exit(__doc__))()
