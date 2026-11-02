#!/usr/bin/env python3
"""TKF-9: проверка предложения (знак z в CART_CM_MODEL) расчётом: bar_deg_phys из замера (out/speed_bar.json, out/speed_bar_cm.json)
-> bar_deg в осях после правки (-8,74 град) -> зазоры TT-К6 (geometry.py) на концах хода для вариантов хода «на себя».
python3 tools/research/trike-fix/strut/check_proposal.py   (из корня; пишет out/proposal.json)
"""
import json, math, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import geometry as G
T = G.T
OUT = os.path.join(HERE, "out")
sb = json.load(open(os.path.join(OUT, "speed_bar.json")))
cm = json.load(open(os.path.join(OUT, "pitch_cm.json"))) if os.path.exists(os.path.join(OUT, "pitch_cm.json")) else {}

# 1. смещение вида: угол CM тележки от мачты (CART_CM_MODEL): atan(0,13/1,70) в обе стороны
ang = math.degrees(math.atan2(0.13, 1.70))
shift = 2 * ang
print("угол ЦМ %.3f град; смещение вида при смене знака %.3f град" % (ang, shift))

# 2. кривая скорость <-> bar_deg_phys (газ 0, установившееся)
pts = sorted((v["bar_mean"], v["v_mean_kmh"]) for k, v in sb.items() if k.startswith("g0_"))
print("g0: bar_deg_phys -> v, км/ч:", pts)
def v_of(b):
    for (b0, v0), (b1, v1) in zip(pts, pts[1:]):
        if b0 <= b <= b1:
            return v0 + (v1 - v0) * (b - b0) / (b1 - b0)
    (b0, v0), (b1, v1) = pts[-2:]          # экстраполяция по двум крайним точкам (>13,14)
    return v1 + (v1 - v0) * (b - b1) / (b1 - b0)

a_hi = G.limits()[1]                         # касание подкоса, 4,95
phys_touch = a_hi + shift
res = {"shift_deg": shift, "push_contact_view_deg": a_hi, "push_contact_phys_deg": phys_touch,
       "v_at_contact_kmh": v_of(phys_touch), "v_full_push_g0_kmh": sb["g0_p+1.00"]["v_mean_kmh"],
       "bar_full_push_phys": sb["g0_p+1.00"]["bar_mean"], "variants": {}}
# a_stop для PendulumModel: bar_deg = 2,82 - a при неверном знаке (TKF-5); после правки bar_deg = -5,92 - a
res["a_stop_deg_after_fix"] = -5.92 - a_hi
res["a_stop_deg_tkf5"] = 2.82 - a_hi
# 3. варианты хода «на себя»: линейно 31,6 град/м от нейтрали (замер: 0,111 -> 0,58; 0,25 -> -3,82; ввод 0 -> 4,09)
k = (4.09 - (-3.82)) / 0.25
for pull in (0.111, 0.118, 0.178, 0.20, 0.25):
    phys_end = 4.09 - k * pull
    view_end = phys_end - shift
    g = G.gaps(view_end)
    res["variants"][str(pull)] = {"bar_phys_min": phys_end, "bar_view_min": view_end,
        "body_gap_m": T.body_gap(G.rotb(G.TRIM, view_end)), "pass_TTK6_body_0.05": view_end >= G.limits()[0] - 0.05}
# 4. зазоры по всему ходу при ходе 0,118 (границы -8,39 .. +4,95 включительно)
worst = {}
a = G.limits()[0]
while a <= a_hi + 1e-9:
    for kk, vv in G.gaps(a).items():
        worst[kk] = min(worst.get(kk, 9), vv)
    a += 0.5
res["worst_gaps_full_travel_m"] = worst
json.dump(res, open(os.path.join(OUT, "proposal.json"), "w"), indent=1, ensure_ascii=False)
print(json.dumps(res, indent=1, ensure_ascii=False))
