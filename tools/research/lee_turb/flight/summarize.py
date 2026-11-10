"""out/flights.csv, out/frame_time.csv -> out/summary.md: по ячейкам (h, x/H) старое/новое, среднее по сидам и повторам."""
import csv, os, sys
from collections import defaultdict

out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
rows = list(csv.DictReader(open(os.path.join(out, "flights.csv"), encoding="utf-8")))
cols = ["sigma_u_ms", "sigma_v_ms", "sigma_w_ms", "az_sigma_ms2", "az_max_abs_ms2", "roll_sigma_deg", "pitch_sigma_deg", "frac_dw_gt2", "sigma_turb_term_mean_ms", "mean_agl_m", "mean_wind_ms"]
g = defaultdict(list)
for r in rows:
    if r["sigma_w_ms"] != "" and int(r["n"]) >= 120:
        g[(float(r["height_rel_crest_m"]), float(r["x_over_h"]), r["code"])].append(r)
    else:
        g[(float(r["height_rel_crest_m"]), float(r["x_over_h"]), r["code"] + "_empty")].append(r)


def mean(rs, c):
    v = [float(r[c]) for r in rs if r[c] != ""]
    return sum(v) / len(v) if v else float("nan")


lines = ["# Полёт за гребнем: старое / новое (среднее по сидам и повторам)", ""]
lines.append("| h над гребнем, м | x/H | код | проходов | n отсч. | AGL, м | ветер, м/с | σu | σv | σw | σ(a_z), м/с² | max\\|a_z\\| | σ крена, ° | σ тангажа, ° | доля \\|Δw\\|>2 | σ слоя turb |")
lines.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
for key in sorted({(h, x) for (h, x, c) in g}, key=lambda k: (k[1], -k[0])):
    for code in ("old", "new"):
        rs = g.get((key[0], key[1], code), [])
        if not rs:
            e = g.get((key[0], key[1], code + "_empty"), [])
            lines.append(f"| {key[0]:+.0f} | {key[1]} | {code} | 0 из {len(e)} | — | | | | | | | | | | | |")
            continue
        n = sum(int(r["n"]) for r in rs)
        lines.append(
            f"| {key[0]:+.0f} | {key[1]} | {code} | {len(rs)} | {n} | {mean(rs,'mean_agl_m'):.0f} | {mean(rs,'mean_wind_ms'):.1f} | "
            f"{mean(rs,'sigma_u_ms'):.2f} | {mean(rs,'sigma_v_ms'):.2f} | {mean(rs,'sigma_w_ms'):.2f} | {mean(rs,'az_sigma_ms2'):.2f} | "
            f"{mean(rs,'az_max_abs_ms2'):.1f} | {mean(rs,'roll_sigma_deg'):.1f} | {mean(rs,'pitch_sigma_deg'):.1f} | {mean(rs,'frac_dw_gt2'):.3f} | {mean(rs,'sigma_turb_term_mean_ms'):.2f} |"
        )
fp = os.path.join(out, "frame_time.csv")
if os.path.exists(fp):
    lines += ["", "## Время кадра", "", "| код | медиана, мс | p95, мс | n | среднее, мс | max, мс | кадров > 50 мс |", "|---|---|---|---|---|---|---|"]
    for r in csv.DictReader(open(fp, encoding="utf-8")):
        lines.append(f"| {r['code']} | {r['median_ms']} | {r['p95_ms']} | {r['n']} | {r['mean_ms']} | {r['max_ms']} | {r['hitch_50ms']} |")
open(os.path.join(out, "summary.md"), "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("\n".join(lines))
