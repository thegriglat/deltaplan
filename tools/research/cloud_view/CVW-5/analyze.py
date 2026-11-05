"""CVW-5: граница записи, CPU и кадр. Читает after.json (строки edge_*_rows: смещение, visible_density, luma),
пишет edge_*_onset_*, edge_offset_measured_m (макс. |смещение видимого начала яркости - начало visible_density > 0,02|),
edge_blur_m (ширина спада visible_density 0,9 -> 0,02 по CPU)."""
import json, sys
p = sys.argv[1] if len(sys.argv) > 1 else "after.json"
d = json.load(open(p))
offs = []
for k, outward in (("out", 1), ("in", -1)):
    rows = d.get("edge_%s_rows" % k)
    if not rows:
        continue
    rows = sorted(rows)
    if outward < 0:
        rows = rows[::-1]  # порядок: от облака наружу
    plateau = sum(r[2] for r in rows[-4:]) / 4.0  # яркость вне облака
    cpu = next((r[0] for r in rows if r[1] < 0.02), None)
    vis = next((r[0] for r in rows if all(abs(q[2] - plateau) < 0.01 for q in rows[rows.index(r):])), None)
    hi = next((r[0] for r in rows if r[1] < 0.9), None)
    d["edge_%s_cpu_onset_m" % k] = cpu
    d["edge_%s_vis_onset_m" % k] = vis
    if cpu is not None and vis is not None:
        d["edge_%s_onset_diff_m" % k] = abs(vis - cpu)
        offs.append(abs(vis - cpu))
    if cpu is not None and hi is not None:
        d["edge_%s_blur_m" % k] = abs(cpu - hi)
if offs:
    d["edge_offset_measured_m"] = max(offs)
json.dump(d, open(p, "w"), indent="\t", sort_keys=True)
open(p, "a").write("\n")
print({k: v for k, v in d.items() if k.startswith("edge_") and not k.endswith("rows")})
