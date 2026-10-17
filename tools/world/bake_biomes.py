"""Запекание configs/biomes.json (RV-К1): регион места по (lat, lon) из карты Кёппена–Гейгера.

    python3 -I tools/world/bake_biomes.py <каталог kg> [--leaves 128]   # запечь configs/biomes.json
    python3 -I tools/world/bake_biomes.py --check <каталог kg>          # печатает world_acc=<доля>

Каталог kg — Beck_KG_V1_present_*.tif (Beck и др. 2018, Sci. Data 5:180214, doi:10.1038/sdata.2018.214, CC BY 4.0;
в репозиторий не кладутся, см. tools/research/regional_veg/README.md). Нужны numpy, scikit-learn, tifffile, imagecodecs.
Дерево: DecisionTreeClassifier по центрам ячеек 0,5°, вес cos(lat), random_state=0 — перезапуск даёт тот же файл.
Высота не используется (пояса пород по высоте — trees.species.*.min_m/max_m).
"""
import json
import sys
from pathlib import Path

import numpy as np
import tifffile
from sklearn.tree import DecisionTreeClassifier

OUT = Path(__file__).resolve().parent.parent.parent / "configs" / "biomes.json"
SOURCE = "Köppen–Geiger, Beck et al. 2018, CC BY 4.0, doi:10.1038/sdata.2018.214"
CLASSES = ["arid", "tropical_wet", "savanna", "mediterranean", "subtropical", "temperate", "boreal", "alpine_ice"]
# Beck 2018, классы 1..30 -> набор 0..7 (как в tools/research/regional_veg/compare.py)
MAP = {1: 1, 2: 1, 3: 2, 4: 0, 5: 0, 6: 2, 7: 0, 8: 3, 9: 3, 10: 3, 11: 4, 12: 5, 13: 5, 14: 4, 15: 5, 16: 5,
       17: 5, 18: 5, 19: 6, 20: 6, 21: 5, 22: 5, 23: 6, 24: 6, 25: 5, 26: 5, 27: 6, 28: 6, 29: 7, 30: 7}
LUT = np.zeros(31, np.uint8)
for _k, _v in MAP.items():
    LUT[_k] = _v

# Исключения: порядок важен, первое совпадение (границы включительно). Каждое — с причиной.
EXCEPTIONS = [
    # дерево по широте/долготе путает Алтай и Урал (горы Кёппен считает E-классом) — старый набор не меняется
    {"name": "siberia_ural", "lat": [49.0, 75.0], "lon": [55.0, 180.0], "profile": "boreal"},
    # остров в океане: карта 1 км и дерево дают море/соседний класс
    {"name": "rapa_nui", "lat": [-27.3, -27.0], "lon": [-109.5, -109.2], "profile": "island"},
    # узкое побережье: дерево 0,5° отдаёт его умеренному поясу
    {"name": "riviera_liguria", "lat": [43.2, 44.4], "lon": [5.0, 10.0], "profile": "mediterranean"},
    # мыс Доброй Надежды: средиземноморский клин меньше ячейки дерева
    {"name": "cape_town", "lat": [-34.5, -33.0], "lon": [17.8, 19.5], "profile": "mediterranean"},
    # предгорья Гималаев (Покхара ~ 800 м): карта 1 км субтропики, дерево — высокогорье/умеренный
    {"name": "nepal_foothills", "lat": [26.5, 29.5], "lon": [80.0, 88.5], "profile": "subtropical"},
    # влажные тропики Квинсленда (Кернс): узкая полоса между морем и саванной
    {"name": "queensland_coast", "lat": [-19.0, -15.0], "lon": [145.0, 146.5], "profile": "tropical_wet"},
    # Большой Кавказ (Казбеги): дерево 0,5° тянет сухой пояс Ирана/Закавказья на север
    {"name": "caucasus", "lat": [41.5, 43.8], "lon": [42.0, 47.0], "profile": "temperate"},
]

OLD = ["pine", "cedar", "larch", "birch", "spruce"]


def _pal(walls, roofs):
    return {"village": {"wall_colors": walls, "roof_colors": roofs}}


# Профили региона (RV-К1, RV-9): trees (set, веса species), terrain_look (тон полога), scene_look (evergreen),
# buildings (форма и модели домов, палитры, потолок этажей). boreal/alpine_ice — ровно {trees:{set}}: Алтай/Урал не меняются.
# Пояса пород по высоте — общие, configs/world.json -> trees.species (palm ≈ 0–450 м, tropical ≈ 0–1700 м, oak ≈ 0–1200 м).
# Тон полога (terrain_look.forest_color/birch_color, линейный RGB; по умолчанию 0.06,0.12,0.05 / 0.13,0.20,0.07):
# тропики темнее и насыщеннее (глубокая листва, много влаги), саванна и средиземноморье суше и светлее.
PROFILES = {
    "arid": {
        "trees": {"set": ["pine", "cedar", "spruce", "birch"]},
        "buildings": {
            "village_roof": "flat_parapet", "city_roof": "flat_parapet",
            "style": _pal([[0.74, 0.62, 0.45], [0.68, 0.55, 0.4], [0.78, 0.68, 0.52], [0.7, 0.58, 0.46]],
                          [[0.4, 0.3, 0.22], [0.36, 0.28, 0.22], [0.42, 0.34, 0.26]]),
        },
    },
    "tropical_wet": {
        "trees": {"set": ["tropical", "palm"], "species": {"palm": {"weight": 0.4}}},
        "terrain_look": {"forest_color": [0.035, 0.1, 0.035], "birch_color": [0.07, 0.17, 0.05]},
        "scene_look": {"evergreen": 1.0},
        "buildings": {
            "village_models": [{"name": "stilt_house", "weight": 0.6}, {"name": "tin_house", "weight": 0.4}],
            "village_model_share": 0.6,
            "style": _pal([[0.72, 0.66, 0.5], [0.6, 0.7, 0.62], [0.78, 0.74, 0.62], [0.7, 0.55, 0.42]],
                          [[0.5, 0.25, 0.2], [0.3, 0.38, 0.3], [0.36, 0.4, 0.46]]),
        },
    },
    "savanna": {
        "trees": {"set": ["tropical", "palm", "pine"], "species": {"palm": {"weight": 0.3}, "tropical": {"weight": 0.7}}},
        "terrain_look": {"forest_color": [0.085, 0.125, 0.05], "birch_color": [0.15, 0.19, 0.07]},
        "scene_look": {"evergreen": 0.6},
        "buildings": {
            "village_models": [{"name": "rondavel", "weight": 0.6}, {"name": "tin_house", "weight": 0.4}],
            "village_model_share": 0.7,
            "style": _pal([[0.72, 0.58, 0.42], [0.66, 0.52, 0.38], [0.76, 0.66, 0.5], [0.7, 0.6, 0.48]],
                          [[0.4, 0.3, 0.2], [0.45, 0.22, 0.18], [0.34, 0.38, 0.42]]),
        },
    },
    "mediterranean": {
        "trees": {"set": ["pine", "oak", "palm", "cedar", "spruce"], "species": {"pine": {"weight": 1.0}, "palm": {"weight": 0.2}}},
        "terrain_look": {"forest_color": [0.07, 0.11, 0.05], "birch_color": [0.12, 0.16, 0.07]},
        "scene_look": {"evergreen": 0.5},
        "buildings": {
            "village_roof": "hip", "max_levels": 4,
            "style": _pal([[0.85, 0.8, 0.7], [0.88, 0.84, 0.76], [0.8, 0.74, 0.62], [0.84, 0.72, 0.58]],
                          [[0.58, 0.28, 0.18], [0.52, 0.25, 0.17], [0.62, 0.32, 0.2]]),
        },
    },
    "subtropical": {
        "trees": {"set": ["tropical", "palm", "oak", "pine", "cedar", "spruce"],
                  "species": {"palm": {"weight": 0.4}, "oak": {"weight": 0.6}}},
        "terrain_look": {"forest_color": [0.045, 0.105, 0.04], "birch_color": [0.09, 0.18, 0.055]},
        "scene_look": {"evergreen": 0.8},
        "buildings": {
            "village_roof": "hip",
            "village_models": [{"name": "tin_house", "weight": 1.0}], "village_model_share": 0.3,
            "style": _pal([[0.8, 0.76, 0.66], [0.72, 0.7, 0.6], [0.76, 0.66, 0.54], [0.66, 0.72, 0.64]],
                          [[0.5, 0.25, 0.2], [0.34, 0.4, 0.34], [0.38, 0.38, 0.42]]),
        },
    },
    "temperate": {"trees": {"set": ["spruce", "larch", "cedar", "pine", "oak", "birch"]}},
    "boreal": {"trees": {"set": OLD}},
    "alpine_ice": {"trees": {"set": OLD}},
    # Остров Пасхи / Ханга-Роа: пальма и тропический лес (вечнозелёные), один этаж, жестяные крыши
    "island": {
        "trees": {"set": ["palm", "tropical"], "species": {"palm": {"weight": 0.6}}},
        "terrain_look": {"forest_color": [0.04, 0.105, 0.04], "birch_color": [0.08, 0.17, 0.05]},
        "scene_look": {"evergreen": 1.0},
        "buildings": {
            "max_levels": 1,
            "village_models": [{"name": "tin_house", "weight": 1.0}], "village_model_share": 0.7,
            "style": {**_pal([[0.86, 0.84, 0.78], [0.8, 0.82, 0.74], [0.84, 0.76, 0.66], [0.78, 0.84, 0.86]],
                              [[0.5, 0.25, 0.2], [0.3, 0.4, 0.5], [0.28, 0.42, 0.32]]),
                      "city": {"wall_colors": [[0.86, 0.84, 0.78], [0.8, 0.82, 0.74], [0.84, 0.76, 0.66]],
                               "roof_colors": [[0.5, 0.25, 0.2], [0.3, 0.4, 0.5]]}},
        },
    },
}


def load(kg_dir, name):
    return tifffile.imread(f"{kg_dir}/Beck_KG_V1_present_{name}.tif")


def export_tree(t, digits=2):
    tr = t.tree_
    nodes = []
    for i in range(tr.node_count):
        if tr.children_left[i] == -1:
            nodes.append([-1, int(np.argmax(tr.value[i]))])
        else:
            nodes.append([int(tr.feature[i]), round(float(tr.threshold[i]), digits),
                          int(tr.children_left[i]), int(tr.children_right[i])])
    return nodes


def classify(tree, lat, lon):
    """Векторное дерево: влево при x <= thr. Возвращает индексы классов."""
    x = (lat, lon)
    node = np.zeros(len(lat), np.int64)
    arr = [(n[0], n[1], n[2], n[3]) if n[0] != -1 else (-1, n[1], 0, 0) for n in tree]
    feat = np.array([a[0] for a in arr])
    thr = np.array([a[1] for a in arr], float)
    left = np.array([a[2] for a in arr])
    right = np.array([a[3] for a in arr])
    for _ in range(40):
        f = feat[node]
        active = f >= 0
        if not active.any():
            break
        xv = np.where(f == 0, x[0], x[1])
        nxt = np.where(xv <= thr[node], left[node], right[node])
        node = np.where(active, nxt, node)
    return thr_class(tree, node)


def thr_class(tree, node):
    cls = np.array([n[1] if n[0] == -1 else -1 for n in tree])
    return cls[node]


def biome_class(data, lat, lon):
    """Логика Biome.at: исключения -> дерево. Класс 0..7, либо 255 для профиля вне classes (island)."""
    out = classify(data["tree"], lat, lon).astype(np.int64)
    done = np.zeros(len(lat), bool)
    for ex in data["exceptions"]:
        m = (~done) & (lat >= ex["lat"][0]) & (lat <= ex["lat"][1]) & (lon >= ex["lon"][0]) & (lon <= ex["lon"][1])
        out[m] = CLASSES.index(ex["profile"]) if ex["profile"] in CLASSES else 255
        done |= m
    return out


def sample(a, lat, lon):
    h, w = a.shape
    iy = np.clip(((90.0 - lat) / 180.0 * h).astype(int), 0, h - 1)
    ix = np.clip(((lon + 180.0) / 360.0 * w).astype(int), 0, w - 1)
    return a[iy, ix]


def bake(kg_dir, leaves):
    k05 = load(kg_dir, "0p5")
    h, w = k05.shape
    yy, _xx = np.mgrid[0:h, 0:w]
    tlat = 90.0 - (yy + 0.5) * 180.0 / h
    tlon = -180.0 + (_xx + 0.5) * 360.0 / w
    m = k05 > 0
    X = np.stack([tlat[m], tlon[m]], 1)
    y = LUT[k05[m]]
    t = DecisionTreeClassifier(max_leaf_nodes=leaves, random_state=0).fit(X, y, sample_weight=np.cos(np.radians(tlat[m])))
    return {
        "version": 1,
        "source": SOURCE,
        "classes": CLASSES,
        "tree": export_tree(t),
        "exceptions": EXCEPTIONS,
        "profiles": PROFILES,
    }


def dump(data):
    lines = ['{']
    keys = list(data)
    for i, k in enumerate(keys):
        if k == "tree":
            body = "[\n" + ",\n".join(json.dumps(n, separators=(",", ":")) for n in data[k]) + "\n]"
        elif k in ("exceptions",):
            body = "[\n" + ",\n".join(json.dumps(n, ensure_ascii=False, separators=(",", ":")) for n in data[k]) + "\n]"
        elif k == "profiles":
            body = "{\n" + ",\n".join(f'{json.dumps(p)}:{json.dumps(v, separators=(",", ":"))}' for p, v in data[k].items()) + "\n}"
        else:
            body = json.dumps(data[k], ensure_ascii=False, separators=(",", ":"))
        lines.append(f'{json.dumps(k)}:{body}' + ("," if i < len(keys) - 1 else ""))
    lines.append('}')
    return "\n".join(lines) + "\n"


def check(kg_dir):
    data = json.loads(OUT.read_text(encoding="utf-8"))
    k1 = load(kg_dir, "0p0083")
    rng = np.random.default_rng(1)
    n = 600000
    lat = np.degrees(np.arcsin(rng.uniform(-1, 1, n)))  # равная площадь
    lon = rng.uniform(-180, 180, n)
    cls = sample(k1, lat, lon)
    land = cls > 0
    lat, lon, cls = lat[land], lon[land], cls[land]
    acc = float((biome_class(data, lat, lon) == LUT[cls]).mean())
    print(f"точек суши: {len(lat)}, размер файла: {OUT.stat().st_size}")
    print(f"world_acc={acc:.4f}")


def main():
    args = sys.argv[1:]
    leaves = 128
    if "--leaves" in args:
        i = args.index("--leaves")
        leaves = int(args[i + 1])
        del args[i:i + 2]
    if args and args[0] == "--check":
        check(args[1])
        return
    OUT.write_text(dump(bake(args[0], leaves)), encoding="utf-8")
    print("записано", OUT, OUT.stat().st_size, "байт")


if __name__ == "__main__":
    main()
