"""PT-2: прогоны picard_rs --cut-cells на случаях <site>_d<dx>_cut, строки PT4 и таблица против базы и эталона.

  cargo build --release --manifest-path rust/picard_rs/Cargo.toml
  PY=tools/research/sw_charges_3d/py
  $PY tools/research/picard_terrain/run_cut.py              # 4 случая, каждый под .dpcli/dpcli lock cpu PT-2 (8 потоков)
  $PY tools/research/picard_terrain/run_cut.py --table      # только таблица из rows.jsonl (без прогонов)
  $PY tools/research/picard_terrain/run_cut.py --no-lock …  # отладка: без замка (time.locked = false)

Выход: out/PT-2/r2/<case>.json (R2), D/states/<case>.json (R4), out/PT-2/rows.jsonl (PT4), out/PT-2/table.md.
База и эталон для таблицы — out/PT-1/rows.jsonl (picard_rs, 1-й порядок, те же dx; air3d d25/d12p5, 2-й порядок).
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
sys.path.insert(0, str(HERE))
import sample as SM  # noqa: E402

D = Path(os.environ.get("PICARD_TERRAIN_DATA", "~/data/picard_terrain")).expanduser()
OUT = HERE / "out" / "PT-2"
BIN = ROOT / "rust/target/release/picard"
CASES = ["askervein_d50_cut", "askervein_d100_cut", "kayancha_d50_cut", "kayancha_d100_cut"]
THREADS = 8
MAX_ITERS = 4000
# reference.md §4 (Askervein, 30 м, сетка 50 м): потенциальное без ступенек 0,34 -> со ступенями 0,28 (-18 %)
POT_SMOOTH, POT_STEPS = 0.34, 0.28


def rel(p):
    try:
        return str(Path(p).resolve().relative_to(ROOT))
    except ValueError:
        return str(p)


def status_of(r2):
    """PT4: ok | max | diverged | stalled (критерий не достигнут, невязка за последние 50 % итераций убыла < 2 раз)."""
    st = r2["status"]
    if st != "max":
        return st
    h = [x for x in r2["history"] if x.get("mom_rms") is not None]
    if len(h) >= 2:
        it_end = h[-1]["it"]
        mid = [x for x in h if x["it"] <= it_end / 2]
        if mid:
            a, b = mid[-1], h[-1]
            worst = max(b[k] / max(a[k], 1e-300) for k in ("mom_rms", "div_rms") if a[k])
            if worst > 0.5:
                return "stalled"
    return "max"


def run_case(name, lock=True):
    case_json = D / "cases" / f"{name}.json"
    r2p = OUT / "r2" / f"{name}.json"
    stp = D / "states" / f"{name}.json"
    r2p.parent.mkdir(parents=True, exist_ok=True)
    stp.parent.mkdir(parents=True, exist_ok=True)
    cmd = [str(BIN), "solve", str(case_json), "--cut-cells", "--threads", str(THREADS), "--max-iters", str(MAX_ITERS),
           "--out", str(r2p), "--save-state", str(stp)]
    if lock:
        cmd = [str(ROOT / ".dpcli/dpcli"), "lock", "cpu", "PT-2", "--no-tmux", "--"] + cmd
    print(" ".join(cmd), flush=True)
    subprocess.run(cmd, check=True, cwd=ROOT)
    r2 = json.loads(r2p.read_text())
    meta = json.loads(case_json.read_text())
    vals = SM.probe_values(str(case_json), str(stp))
    dS = SM.dS(str(case_json), vals)
    res = r2["residuals"]
    note = (f"picard_rs f32, срезанные клетки PT2 (vf_min {meta['pt']['cut']['vf_min']}, "
            f"{meta['pt']['cut']['samples_per_edge']} точек на ребро), 1-й порядок; "
            f"{'замок cpu' if lock else 'без замка'}, {THREADS} потоков")
    return dict(format="pt-row", version=1, task="PT-2", case=name, site=meta["pt"]["site"], dx=float(meta["dx"]),
                solver="picard_rs", dtype="f32", cut_cells=True, adv2=False, limiter=None, status=status_of(r2),
                iters=int(r2["iters"]), max_iters=MAX_ITERS,
                final=dict(mom_rms=res["mom_rms"], th_rms=res["th_rms"], div_rms=res["div_rms"]),
                time=dict(total_s=r2["time"]["total_s"], ms_per_iter=r2["time"]["ms_per_iter"], threads=THREADS,
                          locked=bool(lock)),
                r2=rel(r2p), state=f"states/{name}.json",
                probes=[dict(name=v["name"], z_agl=v["z_agl"], S=v["S"], dS=dS[v["name"]]) for v in vals],
                rotor=None, masts_rmse=None, note=note)


def load_rows(p):
    return [json.loads(x) for x in Path(p).read_text().splitlines() if x.strip()] if Path(p).exists() else []


def pick(rows, case, **kw):
    c = [r for r in rows if r["case"] == case and all(r.get(k) == v for k, v in kw.items())]
    c.sort(key=lambda r: (not r["time"]["locked"],))
    return c[0] if c else None


def pv(row, name, key):
    if row is None:
        return None
    for p in row["probes"]:
        if p["name"] == name:
            return p[key]
    return None


def f(x, fmt="{:+.3f}"):
    return "—" if x is None else fmt.format(x)


def table(rows):
    base_rows = load_rows(HERE / "out" / "PT-1" / "rows.jsonl")
    L = ["# PT-2: срезанные клетки (FAVOR) — разгон против базы и эталона", "",
         "Строки — `rows.jsonl` (PT4); база — `out/PT-1/rows.jsonl` (picard_rs, 1-й порядок, ступени), "
         "эталон — air3d 2-й порядок (ван Лир) d25 / d12p5. Выборка — PT5 (`sample.py`).", ""]

    def base_of(name):
        b = name[:-4]
        return pick(base_rows, b, solver="picard_rs", cut_cells=False, adv2=False)

    L += ["## Askervein: ΔS = S_HT / S_RS − 1 на той же высоте", "",
          "| вариант | 10 м | 30 м | 60 м | 100 м | итераций | мс/итер. | статус |", "|---|---|---|---|---|---|---|---|"]
    refs = [("эталон 25 м, 2-й пор.", pick(base_rows, "askervein_d25", adv2=True)),
            ("эталон 12,5 м, 2-й пор.", pick(base_rows, "askervein_d12p5", adv2=True))]
    for dx in (100, 50):
        nm = f"askervein_d{dx}_cut"
        for lab, r in ((f"{dx} м база (ступени)", base_of(nm)), (f"{dx} м срезанные клетки", pick(rows, nm))):
            L.append(f"| {lab} | " + " | ".join(f(pv(r, f'HT_{z}', 'dS')) for z in (10, 30, 60, 100))
                     + f" | {r['iters'] if r else '—'} | {f(r['time']['ms_per_iter'] if r else None, '{:.1f}')}"
                       f" | {r['status'] if r else '—'} |")
    for lab, r in refs:
        L.append(f"| {lab} | " + " | ".join(f(pv(r, f'HT_{z}', 'dS')) for z in (10, 30, 60, 100))
                 + f" | {r['iters'] if r else '—'} | — | {r['status'] if r else '—'} |")
    L += ["", "Возвращённое на 30 м: Δ = ΔS(срезанные) − ΔS(база); «из −18 %» — Δ / (0,34 − 0,28) "
          "(потенциальное без ступенек и со ступенями 50 м, reference.md §4); «до эталона» — Δ / (ΔS(12,5 м) − ΔS(база)).", "",
          "| сетка | Δ на 30 м | из −18 % (0,06) | до эталона 12,5 м |", "|---|---|---|---|"]
    r125 = pv(refs[1][1], "HT_30", "dS")
    for dx in (100, 50):
        nm = f"askervein_d{dx}_cut"
        b, c = pv(base_of(nm), "HT_30", "dS"), pv(pick(rows, nm), "HT_30", "dS")
        d = None if b is None or c is None else c - b
        L.append(f"| {dx} м | {f(d)} | {f(None if d is None else d / (POT_SMOOTH - POT_STEPS), '{:.0%}')} | "
                 f"{f(None if d is None or r125 is None else d / (r125 - b), '{:.0%}')} |")
    L += ["", "## Каянча: S над стартом, м/с (и к эталону 25 м)", "",
          "| вариант | 20 м | 30 м | 50 м | 100 м | итераций | мс/итер. | статус |", "|---|---|---|---|---|---|---|---|"]
    kref = pick(base_rows, "kayancha_d25", adv2=True)
    for dx in (100, 50):
        nm = f"kayancha_d{dx}_cut"
        for lab, r in ((f"{dx} м база (ступени)", base_of(nm)), (f"{dx} м срезанные клетки", pick(rows, nm))):
            cells = []
            for z in (20, 30, 50, 100):
                s, s0 = pv(r, f"START_{z}", "S"), pv(kref, f"START_{z}", "S")
                cells.append("—" if s is None else (f"{s:.2f}" + ("" if s0 is None else f" ({s / s0:.2f})")))
            L.append(f"| {lab} | " + " | ".join(cells) + f" | {r['iters'] if r else '—'} | "
                     f"{f(r['time']['ms_per_iter'] if r else None, '{:.1f}')} | {r['status'] if r else '—'} |")
    L.append(f"| эталон 25 м, 2-й пор. | " + " | ".join(f(pv(kref, f'START_{z}', 'S'), '{:.2f}') for z in (20, 30, 50, 100))
             + f" | {kref['iters'] if kref else '—'} | — | {kref['status'] if kref else '—'} |")
    L += ["", "## Время: срезанные клетки против базы (замок cpu, 8 потоков)", "",
          "| случай | итераций база / срез. | мс/итер. база / срез. | всего, с база / срез. |", "|---|---|---|---|"]
    for nm in CASES:
        b, c = base_of(nm), pick(rows, nm)
        g = lambda r, k: None if r is None else r["time"][k]
        L.append(f"| {nm[:-4]} | {b['iters'] if b else '—'} / {c['iters'] if c else '—'} | "
                 f"{f(g(b, 'ms_per_iter'), '{:.1f}')} / {f(g(c, 'ms_per_iter'), '{:.1f}')} | "
                 f"{f(g(b, 'total_s'), '{:.1f}')} / {f(g(c, 'total_s'), '{:.1f}')} |")
    (OUT / "table.md").write_text("\n".join(L) + "\n")
    print("\n".join(L))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("names", nargs="*")
    ap.add_argument("--table", action="store_true")
    ap.add_argument("--no-lock", action="store_true")
    a = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    rp = OUT / "rows.jsonl"
    if not a.table:
        rows = {r["case"]: r for r in load_rows(rp)}
        for nm in (a.names or CASES):
            rows[nm] = run_case(nm, lock=not a.no_lock)
            rp.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows.values()))
    table(load_rows(rp))


if __name__ == "__main__":
    main()
