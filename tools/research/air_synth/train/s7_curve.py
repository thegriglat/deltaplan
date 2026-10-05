"""Кривая ошибки по эпохам: оценка S7 на отложенных и местах игры по всем снимкам ckpt/ep*.pt (+ best.pt) -> out/eval_curve.{json,md}.
  s7_curve.py --ckpt-dir <run>/val/ckpt --train-cache C --holdout-cache C --game-cache G --out out [--device cuda]"""
import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import s7_data as D  # noqa: E402
import s7_eval as E  # noqa: E402


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--ckpt-dir", required=True)
    ap.add_argument("--train-cache", nargs="+", required=True)
    ap.add_argument("--holdout-cache", nargs="+", required=True)
    ap.add_argument("--game-cache", nargs="+", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--device", default="cpu")
    ap.add_argument("--history", default=None, help="history.json обучения (train/val по эпохам)")
    a = ap.parse_args()
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    tc = D.Cache(a.train_cache)
    thr = E.thresholds({k: v[tc.select(0)] for k, v in tc.meta.items()})
    ho, gm = D.Cache(a.holdout_cache), D.Cache(a.game_cache)
    hi, gi = ho.select(1), gm.select(2)
    hist = {}
    if a.history and Path(a.history).exists():
        hist = {h["epoch"] + 1: h for h in json.loads(Path(a.history).read_text())}
    snaps = sorted(Path(a.ckpt_dir).glob("ep*.pt")) + [Path(a.ckpt_dir) / "best.pt"]
    rows = []
    for p in snaps:
        model, ck = E.load_model(p, a.device)
        ep = int(ck["epoch"]) + 1 if p.name != "best.pt" else int(ck["epoch"]) + 1
        r = dict(file=p.name, epoch=ep)
        if ep in hist:
            r["train_loss"], r["val_loss"] = hist[ep]["train"], hist[ep].get("val")
        for name, c, idx in (("holdout", ho, hi), ("game", gm, gi)):
            res = E.evaluate(model, c, idx, thr, a.device)
            r[name] = {sl: {k: v for k, v in s["heat"].items() if k in ("n_cases", "median_60m", "p90_60m", "rel_median_60m")} for sl, s in res["slices"].items()}
        rows.append(r)
        print(p.name, r["holdout"]["all"], r["game"]["all"], flush=True)
    (out / "eval_curve.json").write_text(json.dumps(rows, indent=1, ensure_ascii=False))
    md = ["# Кривая ошибки по эпохам (S7, 60 м, поле с нагревом)", "",
          "| снимок | эпоха | train loss | val loss | holdout медиана | p90 | отн. | игра медиана | отн. |", "|---|---|---|---|---|---|---|---|---|"]
    for r in rows:
        h, g = r["holdout"]["all"], r["game"]["all"]
        f = lambda v: "" if v is None else f"{v:.4f}"  # noqa: E731
        md.append(f"| {r['file']} | {r['epoch']} | {f(r.get('train_loss'))} | {f(r.get('val_loss'))} | {h['median_60m']:.3f} | {h['p90_60m']:.3f} | "
                  f"{h['rel_median_60m']:.3f} | {g.get('median_60m', float('nan')):.3f} | {g.get('rel_median_60m', float('nan')):.3f} |")
    (out / "eval_curve.md").write_text("\n".join(md) + "\n")


if __name__ == "__main__":
    main()
