"""PT-11 (1): время поля dp-stand timing до/после. Под lock cpu одним заданием.
  python3 run_timing.py [--only place] [--reps 3]
Результат: out/PT-11/timing/<вар>_<место>_t<потоки>_r<n>.jsonl (строка на момент)."""
import argparse, os, subprocess, sys, time
from pathlib import Path

H = Path.home()
VAR = {
    "base": (H / "worktrees/deltaplan/picard-terrain-PT-11-base", H / ".cache/dp-target/PT-11-base/release/dp-stand"),
    "after": (H / "worktrees/deltaplan/picard-terrain-PT-11", H / ".cache/dp-target/PT-11-after/release/dp-stand"),
}
PLACES = {  # место -> (случай, --place или None)
    "ongudai": ("ongudai_strong", None),
    "synthetic": ("synth_strong", None),
    "training_island": ("synth_strong", "training_island"),
    "volcano_island": ("synth_strong", "volcano_island"),
}
OUT = VAR["after"][0] / "tools/research/picard_terrain/out/PT-11/timing"


def one(var, place, threads, rep):
    root, exe = VAR[var]
    case, pl = PLACES[place]
    f = OUT / f"{var}_{place}_t{threads}_r{rep}.jsonl"
    if f.exists() and f.stat().st_size > 0:
        return
    cmd = [str(exe), "timing", "--case", f"tests/fixtures/wind/cases/{case}.json", "--model", "formula",
           "--timeout", "900", "--threads", str(threads)]
    if pl:
        cmd += ["--place", f"tests/fixtures/wind/places/{pl}.json"]
    t0 = time.time()
    r = subprocess.run(cmd, cwd=root, capture_output=True, text=True)
    print(f"{var} {place} t{threads} r{rep}: rc={r.returncode} {time.time()-t0:.0f}s", flush=True)
    if r.returncode:
        print(r.stderr[-800:], flush=True)
    (f.with_suffix(".err")).write_text(r.stderr)
    f.write_text(r.stdout)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only")
    ap.add_argument("--reps", type=int, default=3)
    a = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    places = [a.only] if a.only else list(PLACES)
    for rep in range(1, a.reps + 1):
        for pl in places:
            for var in ("base", "after"):
                one(var, pl, 8, rep)
    for pl in places:
        for var in ("base", "after"):
            one(var, pl, 2, 1)


main()
