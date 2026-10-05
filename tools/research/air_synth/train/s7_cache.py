"""Кеш подготовки наборов S5 v4 -> $AIR_SYNTH_DATA/train/<имя>/cache/<набор>/ (готовые части пропускаются; можно запускать повторно по мере счёта).
  s7_cache.py --name hgw24_p2 [--workers 8]"""
import argparse
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import s7_data as D  # noqa: E402

SETS = ("game2__hgw24__s0-939a467", "hg_v2__hgw24__s0-939a467")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--name", default="hgw24_p2")
    ap.add_argument("--workers", type=int, default=6)
    ap.add_argument("--sets", nargs="*", default=list(SETS))
    a = ap.parse_args()
    root = Path(D.cio.data_root())
    for s in a.sets:
        sd = root / "solve" / s
        D.build_cache(sd, root / "train" / a.name / "cache" / s, workers=a.workers)


if __name__ == "__main__":
    main()
