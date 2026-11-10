"""Склейка out/raw/flights_*.csv -> out/flights.csv и out/raw/frame_*.csv -> out/frame_time.csv."""
import csv, glob, os, sys

out = sys.argv[1]
rows, head = [], None
for f in sorted(glob.glob(os.path.join(out, "raw", "flights_*.csv"))):
    with open(f, encoding="utf-8") as fh:
        r = list(csv.DictReader(fh))
    if r:
        head = list(r[0].keys())
        rows += r
order = {"old": 0, "new": 1}
rows.sort(key=lambda r: (order.get(r["code"], 9), float(r["height_rel_crest_m"]), float(r["x_over_h"]), int(r["seed"])))
if head:
    with open(os.path.join(out, "flights.csv"), "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=head)
        w.writeheader()
        w.writerows(rows)
fr, fh_ = [], None
for f in sorted(glob.glob(os.path.join(out, "raw", "frame_*.csv"))):
    with open(f, encoding="utf-8") as fh:
        r = list(csv.DictReader(fh))
    if r:
        fh_ = list(r[0].keys())
        fr += r
if fh_:
    with open(os.path.join(out, "frame_time.csv"), "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=fh_)
        w.writeheader()
        w.writerows(fr)
print("flights", len(rows), "frame", len(fr))
