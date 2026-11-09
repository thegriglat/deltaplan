"""Гребни Онгудая для разрезов LTS: выбор по рельефу, файл ridges.json.

Ветер всех случаев Онгудая (ongudai_*) — с 151° (cases/*.json → extra.field_conditions.wdir).
Гребень — локальный максимум высоты вдоль линии по ветру (±300 м), H — превышение над минимумом
рельефа за гребнем в пределах 1500 м по ветру (подножие), как у Menke 2019. Линия разреза: от −2H до
+12H от гребня по ветру, высоты MSL — от минимума рельефа на линии до гребня + 2H (шаг 10 м).
Окна поля вокруг старта kayancha_south (7224.8, 324.7): 50 м — x∈[5625,8825], z∈[−1275,1925];
100 м — x∈[4025,10425], z∈[−2875,3525]; ниже — область 400 м (подтверждено stderr `dp-stand lee`).
"""
import json, math, os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
from terrain import ground, wind_dir

WDIR = 151.0
# (имя, x, z приблизительно, ожидаемая зона) — выбраны просмотром рельефа (см. README)
CAND = [
    ("a50_focus", 7201, 281, 50),
    ("a50_west", 6606, 239, 50),
    ("b100_north", 4747, 1012, 100),
    ("b100_south", 4555, -882, 100),
    ("c400_a", 3705, -354, 400),
    ("c400_b", 3571, -79, 400),
]


def build():
    d = np.array(wind_dir(WDIR))
    out = []
    for name, x0, z0, zone in CAND:
        s = np.arange(-300, 300.1, 5.0)
        x, z = x0 + s * d[0], z0 + s * d[1]
        h = ground(x, z)
        k = int(np.argmax(h))
        cx, cz, hc = float(x[k]), float(z[k]), float(h[k])
        sf = np.arange(0, 1500.1, 10.0)
        foot = float(ground(cx + sf * d[0], cz + sf * d[1]).min())
        H = hc - foot
        sl = np.arange(-2 * H, 12 * H + 0.1, 5.0)
        hl = ground(cx + sl * d[0], cz + sl * d[1])
        y0 = math.floor(float(hl.min()) / 10) * 10
        y1 = math.ceil((hc + 2 * H) / 10) * 10
        out.append(dict(
            name=name, zone=zone, crest_x=round(cx, 1), crest_z=round(cz, 1), crest_msl=round(hc, 1),
            H=round(H, 1), foot_msl=round(foot, 1),
            frm=[round(cx - 2 * H * d[0], 1), round(cz - 2 * H * d[1], 1)],
            to=[round(cx + 12 * H * d[0], 1), round(cz + 12 * H * d[1], 1)],
            ys=[y0, y1], dir=[round(float(d[0]), 5), round(float(d[1]), 5)],
        ))
    return out


if __name__ == "__main__":
    r = build()
    json.dump(r, open(os.path.join(os.path.dirname(__file__), "ridges.json"), "w"), indent=1, ensure_ascii=False)
    for q in r:
        print(q["name"], q["zone"], q["crest_x"], q["crest_z"], q["crest_msl"], "H", q["H"], q["frm"], q["to"], q["ys"])
