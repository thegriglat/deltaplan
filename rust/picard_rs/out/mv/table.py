#!/usr/bin/env python3
"""Markdown tables for the README: out/mv/ (AC-R4, multiversion) against out/ (AC-R3)."""
import glob, json, os

d = os.path.dirname(os.path.abspath(__file__))
base_d = os.path.dirname(d)


def load(dirname):
    rs = {}
    for f in sorted(glob.glob(os.path.join(dirname, "ongudai_d400_*_release_t*.json")) +
                    glob.glob(os.path.join(dirname, "bench", "ongudai_d400_*_release_t*.json"))):
        r = json.load(open(f))
        rs[(r["case"].replace("ongudai_d400_", ""), r["threads"])] = r
    return rs


old, new = load(base_d), load(d)
cases = ["u3_heat", "u3_mech", "u0_heat", "u6_heat"]
tt = [6, 8, 18]
tot = lambda r: r["time"]["total_s"]

print("### Полное время solve, с (AC-R3 / AC-R4 / ускорение)\n")
print("| случай | итераций | " + " | ".join(f"{t} потоков" for t in tt) + " |")
print("|---|---|" + "---|" * len(tt))
for c in cases:
    print(f"| {c} | {new[(c, 8)]['iters']}/{new[(c, 8)]['iters_ref']} | " + " | ".join(
        f"{tot(old[(c, t)]):.2f} / {tot(new[(c, t)]):.2f} / ×{tot(old[(c, t)]) / tot(new[(c, t)]):.2f}" for t in tt) + " |")
print("| пара u3 (mech + heat) | 231+191 | " + " | ".join(
    f"{tot(old[('u3_mech', t)]) + tot(old[('u3_heat', t)]):.2f} / {tot(new[('u3_mech', t)]) + tot(new[('u3_heat', t)]):.2f} / ×"
    f"{(tot(old[('u3_mech', t)]) + tot(old[('u3_heat', t)])) / (tot(new[('u3_mech', t)]) + tot(new[('u3_heat', t)])):.2f}" for t in tt) + " |")

print("\n### мс/итерацию, u3_heat (AC-R3 / AC-R4 / ускорение)\n")
print("| потоков | AC-R3 | AC-R4 | ускорение | подготовка AC-R3 / AC-R4, с | мс/проверку AC-R3 / AC-R4 |")
print("|---|---|---|---|---|---|")
for t in [4, 6, 8, 16, 18, 20]:
    if ("u3_heat", t) not in new:
        continue
    a, b = old[("u3_heat", t)]["time"], new[("u3_heat", t)]["time"]
    print(f"| {t}{' (квота 18 ядер)' if t == 20 else ''} | {a['ms_per_iter']:.1f} | {b['ms_per_iter']:.1f} | ×{a['ms_per_iter'] / b['ms_per_iter']:.2f} | "
          f"{a['setup_s']:.2f} / {b['setup_s']:.2f} | {a['check_ms']:.1f} / {b['check_ms']:.1f} |")

print("\n### мс/итерацию по случаям (AC-R3 / AC-R4)\n")
print("| случай | " + " | ".join(str(t) for t in tt) + " |")
print("|---|" + "---|" * len(tt))
for c in cases:
    print(f"| {c} | " + " | ".join(f"{old[(c, t)]['time']['ms_per_iter']:.1f} / {new[(c, t)]['time']['ms_per_iter']:.1f}" for t in tt) + " |")

print("\n### Сверка с эталоном f64, 8 потоков (AC-R3 / AC-R4)\n")
print("| случай | итераций (эталон) AC-R3 / AC-R4 | u_rel AC-R3 / AC-R4 | th_abs, К AC-R3 / AC-R4 | p_rel AC-R3 / AC-R4 | div_rms AC-R3 / AC-R4 / эталон |")
print("|---|---|---|---|---|---|")
for c in cases:
    a, b = old[(c, 8)], new[(c, 8)]
    A, B = a["dev"], b["dev"]
    print(f"| {c} | {a['iters']} / {b['iters']} ({b['iters_ref']}) | {A['u_rel']:.2e} / {B['u_rel']:.2e} | {A['th_abs']:.2e} / {B['th_abs']:.2e} | "
          f"{A['p_rel']:.2e} / {B['p_rel']:.2e} | {A['div_rms']:.2e} / {B['div_rms']:.2e} / {B['div_rms_ref']:.2e} |")

print("\nЧисло итераций и отклонения по всем потокам AC-R4:")
for (c, t), r in sorted(new.items()):
    v = r["dev"]
    print(f"  {c} t{t}: iters {r['iters']}, u_rel {v['u_rel']:.2e}, th_abs {v['th_abs']:.2e}, status {r['status']}")
