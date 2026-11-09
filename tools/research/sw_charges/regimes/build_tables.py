"""Сборка out/regimes/A1,A2 (.json+.csv) и summary.json из RAW/rows_*.jsonl."""
import csv, glob, json, os, subprocess, datetime, collections
import core
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "out", "regimes")
KEYS = ["case", "run", "shape", "s", "H", "h0", "b0", "U0", "F0", "M", "Fr_game", "N", "z_i", "rule_b0", "regime_sw",
        "regime_theory", "match", "Fr_crest", "h_up", "bore_speed", "lee_jump", "x_jump", "q_ratio", "dry_cells", "status", "wall_s"]


def main():
    os.makedirs(OUT, exist_ok=True)
    rows = []
    for f in sorted(glob.glob(os.path.join(core.RAW, "rows_*.jsonl"))):
        rows += [json.loads(l) for l in open(f)]
    git = subprocess.run(["git", "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip()
    summ = {}
    for ser in ("A1", "A2"):
        R = [r for r in rows if r["case"].startswith(ser)]
        R.sort(key=lambda r: r["case"])
        d = {"format": "sw-regimes", "version": 1, "series": ser, "theory": "literature.md §2",
             "thresholds": dict(core.THR, note="скачок: ΔH(2 клетки) > 0,05 h0 и охват 8 клеток ≤ 2× охвата 2 клеток; R6 — сухие клетки в старте; Fr_crest — среднее двух клеток у x = 0"),
             "git": git, "created": datetime.datetime.now().replace(microsecond=0).isoformat(),
             "rows": [{k: r[k] for k in KEYS} | {"diag": r["diag"]} for r in R]}
        json.dump(d, open(os.path.join(OUT, ser + ".json"), "w"), ensure_ascii=False, indent=1)
        with open(os.path.join(OUT, ser + ".csv"), "w", newline="") as f:
            w = csv.writer(f); w.writerow(KEYS)
            for r in R: w.writerow([r[k] for k in KEYS])
        summ[ser] = {"n": len(R), "wall_s_total": sum(r["wall_s"] for r in R)}
    json.dump(summ, open(os.path.join(OUT, "summary.json"), "w"), indent=1)
    print(summ)


if __name__ == "__main__":
    main()
