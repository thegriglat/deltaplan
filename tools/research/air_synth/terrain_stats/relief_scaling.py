"""Масштабирование перепада: медиана (max-min) в квадратных окнах ширины w (шаг 100 м, detail 40x40 км и far 160x160 км) -> показатель
h ~ w^H_rel по МНК на w=2,5..20 км -> out/relief_scaling.json"""
import json, os, numpy as np
from scipy.ndimage import maximum_filter, minimum_filter
import dem
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
W = [1.25, 2.5, 5, 10, 20]
res = {}
for place in dem.PLACES:
    h = dem.load(place, "far")[0][:1600, :1600]          # 100 м, 160 км
    rel = []
    for w in W:
        k = int(w * 1000 / 100)
        r = (maximum_filter(h, k, mode="nearest") - minimum_filter(h, k, mode="nearest"))[k:-k:k // 2 or 1, k:-k:k // 2 or 1]
        rel.append(float(np.median(r)))
    H = float(np.polyfit(np.log(W[1:]), np.log(rel[1:]), 1)[0])
    res[place] = dict(w_km=W, median_relief_m=rel, H_exponent_2p5_20km=H)
    print(place, [round(x) for x in rel], round(H, 2))
json.dump(res, open(os.path.join(OUT, "relief_scaling.json"), "w"), indent=1)
