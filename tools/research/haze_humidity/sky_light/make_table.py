#!/usr/bin/env python3
"""Таблица sky_k(el) для configs/atmosphere.json → clouds.sun_transmission.sky_k (HH-15).

    python3 make_table.py            # печатает таблицу и JSON-узлы

sky_k = DHI(el)/DHI(35°) — однократное рассеяние в атмосфере игры (single_scatter.py); ESRA (sky_light.py, TL = 3) и
Bird — сверка, расхождение ESRA — оценка погрешности.
"""
import json

import sky_light as sl
import single_scatter as ss

NODES = [0.0, 0.5, 1.0, 2.0, 3.0, 4.0, 6.0, 8.0, 12.0, 18.0, 26.0, 35.0]
TL = 3.0


def main():
    e35, b35 = sl.esra_diffuse(35.0, TL)
    ref = ss.dhi(35.0, 6.5e-5, 2000.0, 0.9, 0.7)
    out = []
    print("el    ESRA    1-рассеяние  таблица  ESRA/табл.")
    for el in NODES:
        e = sl.esra_diffuse(el, TL)[0] / e35
        s = ss.dhi(el, 6.5e-5, 2000.0, 0.9, 0.7) / ref
        m = s
        out.append((el, m))
        print("%4.1f  %.3f   %.3f        %.3f    %.2f" % (el, e, s, m, e / m))
    print("r = DHI/BHI(35°): ESRA %.3f" % (e35 / b35))
    print(json.dumps({"elevation_deg": [o[0] for o in out], "k": [round(o[1], 3) for o in out]}))


if __name__ == "__main__":
    main()
