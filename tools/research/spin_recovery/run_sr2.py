#!/usr/bin/env python3
"""SR-2: пачка прогонов стенда spin_run.gd (SR-К1) → out/sr-2/raw/*.json; затем summary.py.
Из корня копии: python3 tools/research/spin_recovery/run_sr2.py [-j 8]. Этап 1: game/pnl_off/rel_off × 3 крыла × 2 режима ×
3 шага; wash*/lam_* — sport, 2 режима, 1/120. Этап 2: вариант, давший выход (любой режим), — ещё 1/60 и 1/30."""
import json, os, subprocess, sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
RAW = ROOT / "tools/research/spin_recovery/out/sr-2/raw"
DTS = {"120": 1 / 120, "60": 1 / 60, "30": 1 / 30}
WINGS = ["sport", "laminar", "training"]
MODES = ["release", "standard", "pull_release"]
BASE = ["game", "pnl_off", "rel_off"]
SCAN = ["sweep_25_5", "sweep_26_25", "sweep_27", "sweep_28"]
HYP = ["wash12", "wash14", "lam_tipchord", "lam_dihedral", "lam_washout", "lam_sweep", "lam_all"]
env = dict(os.environ, XDG_DATA_HOME=os.path.expanduser("~/.cache/dp-xdg/" + ROOT.name))


def name(w, v, m, d):
    return f"{w}__{v}__{m}__{d}"


def one(job):
    w, v, m, d = job
    out = RAW / (name(w, v, m, d) + ".json")
    if out.exists():
        return
    r = subprocess.run(["godot", "--headless", "--path", str(ROOT), "res://tools/research/spin_recovery/spin_run.tscn", "--",
                        f"--wing={w}", f"--variant={v}", f"--mode={m}", f"--dt={DTS[d]!r}", f"--out={out}"],
                       env=env, capture_output=True, text=True, timeout=300)
    if not out.exists():
        print("FAIL", job, r.stdout[-500:], r.stderr[-500:], flush=True)


def batch(jobs, j):
    with ThreadPoolExecutor(j) as ex:
        list(ex.map(one, jobs))


def main():
    j = int(sys.argv[sys.argv.index("-j") + 1]) if "-j" in sys.argv else 8
    RAW.mkdir(parents=True, exist_ok=True)
    s1 = [(w, v, m, d) for v in BASE for w in WINGS for m in MODES for d in DTS]
    s1 += [("sport", v, m, "120") for v in HYP + SCAN for m in MODES]
    batch(s1, j)
    s2 = []
    for v in HYP + SCAN:
        if any(json.loads((RAW / (name("sport", v, m, "120") + ".json")).read_text())["recovered"] for m in MODES):
            s2 += [("sport", v, m, d) for m in MODES for d in ("60", "30")]
    batch(s2, j)
    print("raw:", len(list(RAW.glob("*.json"))))


main()
