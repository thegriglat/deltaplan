"""Рисунок сравнения масок на Аушкуле + IoU предлагаемого канала A (WorldCover 10 м ∪ реки OSM) с текущим.
Запуск: python -I figure_iou.py"""
import json, os
import numpy as np
from PIL import Image
HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.normpath(os.path.join(HERE, "../../../data/terrain"))
res = {}
for p in ["aushkul", "altai", "ongudai", "askarovo"]:
    m = np.load(f"{HERE}/cache/m_{p}.npz")
    wc, lake, A = m["wc"], m["lake"], m["A"]
    a_riv = A & ~lake                       # то, что в A не озёра (реки/каналы OSM)
    prop = wc | a_riv                       # A := WC10 ∪ реки OSM
    res[p] = {
        "iou_proposedA_vs_currentA": round(float((prop & A).sum() / (prop | A).sum()), 4),
        "iou_WC_vs_currentA": round(float((wc & A).sum() / (wc | A).sum()), 4),
        "iou_WC_vs_osm_lake_polygons": round(float((wc & lake).sum() / (wc | lake).sum()), 4),
        "area_km2_proposedA": round(float(prop.sum()) * 1e-4, 3),
        "area_km2_currentA": round(float(A.sum()) * 1e-4, 3),
    }
    if p == "aushkul":
        # окно 8x6 км вокруг озера Аушкуль: центр — центр масс его воды WC в круге 4 км от центра места? берём ручные границы по полигону
        o = json.load(open(f"{DATA}/{p}/osm.json"))
        L = [l for l in o["water"]["lakes"] if l.get("n") == "Аушкуль"][0]["p"]
        cx = (min(L[0::2]) + max(L[0::2])) / 2; cz = (min(L[1::2]) + max(L[1::2])) / 2
        ci, cj = int((cx + 20000) / 10), int((cz + 20000) / 10)
        sl = (slice(cj - 300, cj + 300), slice(ci - 400, ci + 400))
        img = np.zeros(wc[sl].shape + (3,), np.uint8) + 30
        w, l, a = wc[sl], lake[sl], A[sl]
        img[w & ~a] = (230, 80, 60)            # только WorldCover
        img[a & ~w] = (60, 120, 240)           # только OSM (канал A)
        img[a & w] = (240, 240, 240)           # оба
        Image.fromarray(img).save(f"{HERE}/results/aushkul_masks.jpg", quality=80)
        res[p]["figure"] = {"window_km": [8.0, 6.0], "legend": "белый — оба; красный — только WorldCover; синий — только OSM (канал A); тёмный — нет воды"}
json.dump(res, open(f"{HERE}/results/proposal_iou.json", "w"), ensure_ascii=False, indent=1)
print(json.dumps(res, ensure_ascii=False, indent=1))
