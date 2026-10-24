#!/usr/bin/env python3
"""Markdown tables for the README from out/ongudai_*_release_t*.json and out/bench/ (AC-R3)."""
import glob, json, os

d = os.path.dirname(os.path.abspath(__file__))
rs = {}
for f in sorted(glob.glob(os.path.join(d, "ongudai_*_release_t*.json")) + glob.glob(os.path.join(d, "bench", "ongudai_*_release_t*.json"))):
    r = json.load(open(f))
    rs[(r["case"].replace("ongudai_d400_", ""), r["threads"])] = r
cases = ["u3_heat", "u3_mech", "u0_heat", "u6_heat"]
main_t = [6, 8, 18]


def full(r):  # whole picard solve wall time, s (process start excluded)
    return r["time"]["total_s"]


print("### Полное время solve, с (итерации Rust/эталон; подготовка + итерации + проверки)\n")
print("| случай | итераций | " + " | ".join(f"{t} потоков" for t in main_t) + " |")
print("|---|---|" + "---|" * len(main_t))
for c in cases:
    r0 = rs[(c, 8)]
    print(f"| {c} | {r0['iters']}/{r0['iters_ref']} | " + " | ".join(f"{full(rs[(c, t)]):.2f}" for t in main_t) + " |")
print("| пара u3 (mech + heat) | 231+191 | " + " | ".join(f"{full(rs[('u3_mech', t)]) + full(rs[('u3_heat', t)]):.2f}" for t in main_t) + " |")

print("\n### Сверка с эталоном f64 (одинакова на всех потоках)\n")
print("| случай | статус | итераций Rust/эталон | u_rel | th_abs, К | p_rel | div_rms Rust/эталон | t_ref, с (CuPy f64) |")
print("|---|---|---|---|---|---|---|---|")
for c in cases:
    r, v = rs[(c, 8)], rs[(c, 8)]["dev"]
    ref = json.load(open(os.path.expanduser(f"~/data/air_cascade/ongudai/ongudai_d400_{c}.json")))["t_ref_s"]
    print(f"| {c} | {r['status']} | {r['iters']}/{r['iters_ref']} | {v['u_rel']:.2e} | {v['th_abs']:.2e} | {v['p_rel']:.2e} | {v['div_rms']:.2e}/{v['div_rms_ref']:.2e} | {ref} |")

print("\n### Скорость и масштабирование (u3_heat, полный solve)\n")
print("| потоков | мс/итерацию | нс/клетку·итерацию | мс/проверку | подготовка, с | всего, с | ускорение от 4 | эффективность от 4 |")
print("|---|---|---|---|---|---|---|---|")
base = rs[("u3_heat", 4)]["time"]["ms_per_iter"]
for t in sorted(k[1] for k in rs if k[0] == "u3_heat"):
    tm = rs[("u3_heat", t)]["time"]
    sp = base / tm["ms_per_iter"]
    print(f"| {t}{' (квота 18 ядер)' if t == 20 else ''} | {tm['ms_per_iter']:.1f} | {tm['ns_per_cell_iter']:.0f} | {tm['check_ms']:.1f} | {tm['setup_s']:.2f} | {full(rs[('u3_heat', t)]):.2f} | {sp:.2f} | {sp / (t / 4):.2f} |")

print("\n### мс/итерацию по случаям\n")
print("| случай | " + " | ".join(f"{t}" for t in main_t) + " |")
print("|---|" + "---|" * len(main_t))
for c in cases:
    print(f"| {c} | " + " | ".join(f"{rs[(c, t)]['time']['ms_per_iter']:.1f}" for t in main_t) + " |")
