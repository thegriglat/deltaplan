#!/usr/bin/env python3
"""CL-2: «до/после» по числам diag_metrics.py (член base).

    python3 -I tools/research/cliff_look/compare.py <before.json> <after.json>

Печатает таблицу по ракурсам и три строки (пороги — в карточке CL-2):
  STRIPES_RATIO x — медиана по ракурсам со скалами after/before амплитуды полос, привязанных к фазе прежних слоёв
                    (A = √(strata26² + strata7²) кадра base; фаза — маска m3, шаги 25,9 и 7 м по высоте). Ракурсы,
                    где A base «до» на уровне фона (меньше 2 × A кадра all_off «до»), исключены и перечислены.
  RIPPLE_RATIO x  — медиана after/before ряби мельче 2 м (ripple кадра base) по ракурсам со скалами.
  LARGE_RATIO x   — медиана after/before СКО яркости на масштабе 5–40 м на скалах (large кадра base).
Ракурс «со скалами» — доля пикселей скал (вес > 0,5, уклон > 40°) не меньше ROCK_MIN в обоих кадрах.
"""
import json
import math
import statistics
import sys

ROCK_MIN = 0.03      # доля кадра со скалами, ниже — ракурс не считается
BG_K = 2.0           # A base «до» < BG_K × A all_off «до» — полосы на уровне фона


def amp(row):
    return math.hypot(row.get("strata26") or 0.0, row.get("strata7") or 0.0)


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(2)
    before = {(r["tag"], r["view"]): r for r in json.load(open(sys.argv[1]))["views"]}
    after = {(r["tag"], r["view"]): r for r in json.load(open(sys.argv[2]))["views"]}
    stripes, ripple, large, excluded, skipped = [], [], [], [], []
    print("ракурс | дальн., м | A до (фон) | A после | рябь до / после | 5–40 м до / после")
    print("--- | --- | --- | --- | --- | ---")
    for key in sorted(before):
        b, a = before[key], after.get(key)
        name = f"{key[0]}/{key[1]}"
        if a is None or "members" not in b or "members" not in a:
            skipped.append(f"{name} (нет кадра)")
            continue
        if b.get("rock_px_share", 0.0) < ROCK_MIN or a.get("rock_px_share", 0.0) < ROCK_MIN:
            skipped.append(f"{name} (скал {b.get('rock_px_share', 0.0):.1%})")
            continue
        bb, ab = b["members"]["base"], a["members"]["base"]
        bg = amp(b["members"]["all_off"]) if "all_off" in b["members"] else 0.0
        ab_amp, bb_amp = amp(ab), amp(bb)
        if bb_amp < BG_K * bg:
            excluded.append(f"{name} (A {bb_amp:.3f}, фон {bg:.3f})")
        else:
            stripes.append(ab_amp / max(bb_amp, 1e-6))
        ripple.append(ab["ripple"] / max(bb["ripple"], 1e-6))
        if bb.get("large") is not None and ab.get("large") is not None:
            large.append(ab["large"] / max(bb["large"], 1e-6))
        lg = (f"{bb['large']:.3f} / {ab['large']:.3f}" if bb.get("large") is not None and ab.get("large") is not None
              else "—")
        print(f"{name} | {b['dist_m']} | {bb_amp:.3f} ({bg:.3f}) | {ab_amp:.3f} | {bb['ripple']:.3f} / {ab['ripple']:.3f} | {lg}")
    print()
    if excluded:
        print("полосы: исключены (A до на уровне фона): " + ", ".join(excluded))
    if skipped:
        print("не считались: " + ", ".join(skipped))
    med = lambda xs: statistics.median(xs) if xs else float("nan")  # noqa: E731
    print(f"ракурсов: полосы {len(stripes)}, рябь {len(ripple)}, крупные {len(large)}")
    print(f"STRIPES_RATIO {med(stripes):.3f}")
    print(f"RIPPLE_RATIO {med(ripple):.3f}")
    print(f"LARGE_RATIO {med(large):.3f}")


if __name__ == "__main__":
    main()
