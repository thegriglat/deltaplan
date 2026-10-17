"""Сравнение способов выбора набора деревьев по (lat, lon): зональные срезы, список прямоугольников,
малое дерево решений — против карты Кёппена–Гейгера (Beck и др. 2018, CC BY 4.0).

    python3 -I compare.py <каталог с Beck_KG_V1_present_*.tif> <hg_takeoffs.json> <out.json>

Нужны numpy, scikit-learn, tifffile, imagecodecs. Данные Кёппена (figshare 6396959, файл 12407516, md5 69594689...)
в репозиторий не кладутся. Высота не используется (карта 1 км уже сглаживает горы в E-классы; в игре
отдельно работают высотные пояса).
"""
import json
import sys

import numpy as np
import tifffile
from sklearn.tree import DecisionTreeClassifier

kg_dir, catalog, out_path = sys.argv[1:4]

# Beck 2018, классы 1..30 -> набор деревьев 0..7
SETS = ["arid", "tropical_wet", "savanna", "mediterranean", "subtropical", "temperate", "boreal", "alpine_ice"]
MAP = {1: 1, 2: 1, 3: 2, 4: 0, 5: 0, 6: 2, 7: 0, 8: 3, 9: 3, 10: 3, 11: 4, 12: 5, 13: 5, 14: 4, 15: 5, 16: 5,
       17: 5, 18: 5, 19: 6, 20: 6, 21: 5, 22: 5, 23: 6, 24: 6, 25: 5, 26: 5, 27: 6, 28: 6, 29: 7, 30: 7}
LUT = np.zeros(31, np.uint8)
for k, v in MAP.items():
    LUT[k] = v


def load(name):
    a = tifffile.imread(f"{kg_dir}/Beck_KG_V1_present_{name}.tif")
    return a


def to_set(a):
    return np.where(a > 0, LUT[np.clip(a, 0, 30)], 255).astype(np.uint8)


def sample(a, lat, lon):
    h, w = a.shape
    iy = np.clip(((90.0 - lat) / 180.0 * h).astype(int), 0, h - 1)
    ix = np.clip(((lon + 180.0) / 360.0 * w).astype(int), 0, w - 1)
    return a[iy, ix]


# ---- истина: 1 км (тест), обучение: 0,5° (центры ячеек) ----
k1 = load("0p0083")
k05 = load("0p5")
rng = np.random.default_rng(1)
n = 600000
lat = np.degrees(np.arcsin(rng.uniform(-1, 1, n)))  # равная площадь
lon = rng.uniform(-180, 180, n)
cls = sample(k1, lat, lon)
land = cls > 0
lat, lon, cls = lat[land], lon[land], cls[land]
truth = LUT[cls]
print("тестовых точек суши:", len(lat))

cat = json.load(open(catalog))["takeoffs"]
clat = np.array([p["lat"] for p in cat])
clon = np.array([p["lon"] for p in cat])
ccls = sample(k1, clat, clon)
cok = ccls > 0
clat, clon, ccls = clat[cok], clon[cok], ccls[cok]
ctruth = LUT[ccls]
print("точек каталога на суше:", len(clat))

# ---- обучение дерева на 0,5° ----
h, w = k05.shape
yy, xx = np.mgrid[0:h, 0:w]
tlat = 90.0 - (yy + 0.5) * 180.0 / h
tlon = -180.0 + (xx + 0.5) * 360.0 / w
m = k05 > 0
Xtr = np.stack([tlat[m], tlon[m]], 1)
ytr = LUT[k05[m]]
wtr = np.cos(np.radians(tlat[m]))  # вес — площадь ячейки


def tree_size_json(t):
    tr = t.tree_
    # узел: [признак, порог, левый, правый] либо [-1, класс]
    nodes = []
    for i in range(tr.node_count):
        if tr.children_left[i] == -1:
            nodes.append([-1, int(np.argmax(tr.value[i]))])
        else:
            nodes.append([int(tr.feature[i]), round(float(tr.threshold[i]), 1),
                          int(tr.children_left[i]), int(tr.children_right[i])])
    return len(json.dumps(nodes, separators=(",", ":")))


MERGE = np.array([0, 1, 2, 3, 4, 5, 5, 5] + [99] * 248)  # умеренный/бореальный/альпийский различает высота — склеиваем


def acc(pred, tru):
    return float((pred == tru).mean())


def acc_m(pred, tru):
    return float((MERGE[pred] == MERGE[tru]).mean())


res = {"sets": SETS, "n_test": int(len(lat)), "n_catalog": int(len(clat)), "methods": {}}
cat_sets = np.bincount(ctruth, minlength=8).tolist()
res["catalog_truth_counts"] = dict(zip(SETS, cat_sets))

# ---- (а) зональные срезы по широте: 5 срезов, класс — большинство по обучающим ----
for name, cuts in [("cuts_lat_5", [-35, -10, 10, 35, 55]), ("cuts_lat_9", [-50, -35, -23, -10, 10, 23, 35, 45, 55, 66])]:
    def band(x):
        return np.searchsorted(cuts, x)
    b = band(Xtr[:, 0])
    lab = {}
    for k in np.unique(b):
        lab[k] = int(np.bincount(ytr[b == k], weights=wtr[b == k], minlength=8).argmax())
    p = np.array([lab[k] for k in band(lat)])
    pc = np.array([lab.get(k, 5) for k in band(clat)])
    res["methods"][name] = {"world_acc": acc(p, truth), "catalog_acc": acc(pc, ctruth), "catalog_acc_merged": acc_m(pc, ctruth), "world_acc_merged": acc_m(p, truth), "json_bytes": 60}

# ---- (б) прямоугольники руками (приоритет — по порядку; остальное — по широте) ----
BOXES = [
    # lat0, lat1, lon0, lon1, набор
    (-12, 6, -80, -45, 1),       # Амазония
    (-35, -22, -58, -38, 4),     # юг Бразилии
    (-24, -2, -58, -34, 2),      # Серрадо, северо-восток
    (-40, -25, -65, -57, 4),     # пампа
    (-40, -30, -75, -70, 3),     # Чили, средиземноморье
    (-56, -40, -76, -62, 5),     # Патагония
    (-30, -15, -72, -65, 0),     # Анды сухие
    (5, 20, -92, -60, 1),        # Центральная Америка, Карибы
    (14, 28, -110, -92, 2),      # Мексика
    (50, 72, -170, -55, 6),      # Аляска, Канада
    (42, 50, -125, -120, 5),     # Тихоокеанский СЗ
    (32, 42, -125, -117, 3),     # Калифорния
    (25, 42, -117, -100, 0),     # юго-запад США
    (25, 36, -100, -75, 4),      # юго-восток США
    (36, 50, -100, -60, 5),      # северо-восток США, юг Канады
    (60, 72, 5, 40, 6),          # Скандинавия
    (35, 44, -10, 36, 3),        # Средиземноморье
    (44, 60, -10, 40, 5),        # умеренная Европа
    (55, 72, 40, 180, 6),        # Россия, Сибирь
    (30, 42, 26, 45, 3),         # Турция, Левант
    (24, 38, 44, 62, 0),         # Иран
    (12, 32, 35, 60, 0),         # Аравия
    (15, 35, -17, 35, 0),        # Сахара
    (-5, 5, 10, 30, 1),          # Конго
    (0, 15, -17, 42, 2),         # Сахель, саванна
    (-35, -33, 17, 22, 3),       # мыс Доброй Надежды
    (-26, -5, 12, 40, 2),        # юг Африки
    (-35, -26, 16, 33, 2),       # ЮАР
    (36, 52, 50, 90, 0),         # Центральная Азия
    (28, 36, 80, 100, 7),        # Тибет
    (26, 30, 80, 89, 5),         # Непал
    (8, 28, 68, 90, 2),          # Индия
    (-10, 22, 92, 141, 1),       # Юго-Восточная Азия
    (22, 34, 105, 122, 4),       # Восточный Китай
    (34, 45, 110, 145, 5),       # Северный Китай, Корея, Япония
    (42, 52, 90, 120, 0),        # Монголия
    (48, 54, 83, 92, 6),         # Алтай
    (-20, -11, 125, 150, 2),     # Австралия север
    (-32, -20, 115, 142, 0),     # Австралия центр
    (-38, -24, 146, 154, 4),     # Австралия восток
    (-36, -30, 114, 120, 3),     # Австралия юго-запад
    (-44, -36, 140, 148, 5),     # Виктория, Тасмания
    (-47, -35, 166, 179, 5),     # Новая Зеландия
]


def boxes_pred(la, lo):
    out = np.full(len(la), 255, np.uint8)
    for a0, a1, o0, o1, s in BOXES:
        sel = (out == 255) & (la >= a0) & (la <= a1) & (lo >= o0) & (lo <= o1)
        out[sel] = s
    z = np.select([np.abs(la) < 10, np.abs(la) < 23, np.abs(la) < 35, np.abs(la) < 55, np.abs(la) < 72],
                  [1, 2, 4, 5, 6], 7).astype(np.uint8)
    return np.where(out == 255, z, out)


res["methods"]["boxes_hand_%d" % len(BOXES)] = {
    "world_acc": acc(boxes_pred(lat, lon), truth), "catalog_acc": acc(boxes_pred(clat, clon), ctruth), "catalog_acc_merged": acc_m(boxes_pred(clat, clon), ctruth), "world_acc_merged": acc_m(boxes_pred(lat, lon), truth),
    "json_bytes": len(json.dumps(BOXES, separators=(",", ":")))}

# ---- (в) дерево решений по (lat, lon) ----
for leaves in [16, 32, 64, 128, 256, 512, 1024]:
    t = DecisionTreeClassifier(max_leaf_nodes=leaves, random_state=0).fit(Xtr, ytr, sample_weight=wtr)
    p = t.predict(np.stack([lat, lon], 1))
    pc = t.predict(np.stack([clat, clon], 1))
    res["methods"]["tree_%d" % leaves] = {"world_acc": acc(p, truth), "catalog_acc": acc(pc, ctruth), "catalog_acc_merged": acc_m(pc, ctruth), "world_acc_merged": acc_m(p, truth),
                                          "json_bytes": tree_size_json(t)}

# сетка 1° байтами (для сравнения) — точность по тесту
la1 = 90 - (np.arange(180) + 0.5)
lo1 = -180 + (np.arange(360) + 0.5)
LA, LO = np.meshgrid(la1, lo1, indexing="ij")
g = to_set(sample(k1, LA.ravel(), LO.ravel())).reshape(180, 360)
gi = lambda la, lo: g[np.clip((90 - la).astype(int), 0, 179), np.clip((lo + 180).astype(int), 0, 359)]
pg = gi(lat, lon)
pcg = gi(clat, clon)
# точки 1° без суши в центре ячейки -> ближайшее допустимое: считаем как ошибку
res["methods"]["grid_1deg_centre"] = {"world_acc": acc(pg, truth), "catalog_acc": acc(pcg, ctruth), "catalog_acc_merged": acc_m(pcg, ctruth), "world_acc_merged": acc_m(pg, truth),
                                      "json_bytes": 360 * 180}
json.dump(res, open(out_path, "w"), ensure_ascii=False, indent=1)
for k, v in res["methods"].items():
    print(f"{k:22s} world {v['world_acc']:.3f}  catalog {v['catalog_acc']:.3f}  | merged world {v['world_acc_merged']:.3f} catalog {v['catalog_acc_merged']:.3f}  bytes {v['json_bytes']}")
print(res["catalog_truth_counts"])

# ---- контрольные места: истина / ящики / дерево 128 / сетка 1° ----
SPOT = {"Бразилия Флорианополис": (-27.72, -48.78), "Рапа-Нуи": (-27.12, -109.35), "Покхара, Непал": (28.21, 83.99),
        "Кейптаун": (-33.95, 18.42), "Кернс, Австралия": (-16.9, 145.75), "Бир, Индия": (32.05, 76.72),
        "Анси, Альпы": (45.9, 6.15), "Алтай, Манжерок": (51.8, 85.75), "Алматы": (43.2, 76.9), "Ницца": (43.7, 7.26),
        "Кения, Накуру": (-0.3, 36.1), "Манаус": (-3.1, -60.0)}
t128 = DecisionTreeClassifier(max_leaf_nodes=128, random_state=0).fit(Xtr, ytr, sample_weight=wtr)
sl = np.array([v[0] for v in SPOT.values()])
so = np.array([v[1] for v in SPOT.values()])
st = LUT[sample(k1, sl, so)]
sb = boxes_pred(sl, so)
sd = t128.predict(np.stack([sl, so], 1))
sg = gi(sl, so)
res["spot"] = {}
for i, name in enumerate(SPOT):
    row = {"truth": SETS[st[i]], "boxes": SETS[sb[i]], "tree128": SETS[sd[i]], "grid1": SETS[sg[i]] if sg[i] < 8 else "море"}
    res["spot"][name] = row
    print(name, row)
json.dump(res, open(out_path, "w"), ensure_ascii=False, indent=1)
