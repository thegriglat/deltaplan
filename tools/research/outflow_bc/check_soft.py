#!/usr/bin/env python3
"""OB1: одна строка по R2 json мягкого выхода (`picard solve --outflow soft`).

    check_soft.py <R2.json>  ->  OBC1: status=<s> flux_rel=<x> iters=<n> backflow=<k>

Выход 1, если в файле нет ключа "outflow" (прогон был hard).
"""
import json
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: check_soft.py <R2.json>", file=sys.stderr)
        return 2
    with open(sys.argv[1]) as f:
        r = json.load(f)
    o = r.get("outflow")
    if o is None:
        print("OBC1: нет ключа outflow (прогон hard?)", file=sys.stderr)
        return 1
    print(
        f"OBC1: status={r['status']} flux_rel={o['flux_net_max_rel']:.3e} "
        f"iters={r['iters']} backflow={o['backflow_faces']}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
