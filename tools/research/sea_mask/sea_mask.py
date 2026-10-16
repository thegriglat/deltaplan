"""Признак «море» по слоям far места и проверка на местах. Запуск: python3 -I sea_mask.py [--cache DIR] [--ti DIR]
Пишет summary.json (контракт S1) и candidates.json (сравнение кандидатов) рядом со скриптом."""
import json, os, sys, time, argparse
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from loadplace import load_place
from sealib import label_runs, edt

HERE = os.path.dirname(os.path.abspath(__file__))
LEVEL_M = 0.25      # медиана высот компоненты воды не выше — море
MIN_CELLS = 100     # компонента меньше (1 км2) не решает
OPEN_CELLS = 0      # эрозия водной маски до разметки (размыкание проток): 5 клеток пробовали, на 15 местах результат тот же, поэтому выключено
UPPER_Q = 99        # верхний квантиль высот компоненты, %
UPPER_MIN_M = -1.0  # море: верхний квантиль >= -1 м (берег на 0 м); озеро ниже моря — нет
NEAR0_M = 0.5       # класс 0 (нет покрова WorldCover) считается водой, если h не выше
FAR_CELLS = 20      # 2 км при шаге 100 м

PLACES = [  # id, ключ кеша (или путь), kind, lat, lon, примечание
    ("florianopolis", "pt_-27.700_-048.800", "sea", -27.7176, -48.7799, "Атлантика, бразильский берег"),
    ("rapa_nui", "pt_-27.100_-109.350", "sea", -27.12, -109.35, "остров в открытом океане"),
    ("training_island", "TI", "sea", 43.2, 34.0, "синтетика feature/training-island, море 0 м, без батиметрии"),
    ("bukhtarma", "pt_+49.600_+083.900", "reservoir", 49.6, 83.9, "водохранилище, уровень ~390 м"),
    ("katun_altai_ongudai", "pt_+50.800_+086.150", "river", 50.79, 86.13, "Катунь, центр на суше, вода — реки и малые озёра"),
    ("ladoga", "pt_+60.800_+031.500", "lake", 60.8, 31.5, "озеро, уровень в слое ~1 м"),
    ("baikal", "pt_+51.850_+104.900", "lake", 51.85, 104.9, "озеро, 449 м"),
    ("caspian_baku", "pt_+40.350_+049.900", "edge", 40.35, 49.9, "море-озеро −28 м, есть батиметрия"),
    ("ijsselmeer", "pt_+52.750_+005.350", "edge", 52.75, 5.35, "бывший залив, ~0 м, рядом Северное море"),
    ("dead_sea", "pt_+31.500_+035.900", "lake", 31.5, 35.9, "озеро −430 м; центр сдвинут на восток, чтобы квадрат не захватил Средиземное море"),
    ("dead_sea_med", "pt_+31.500_+035.500", "edge", 31.5, 35.5, "диагностика: тот же квадрат с полоской Средиземного моря на западном краю (море, не озеро)"),
    ("malaren", "pt_+59.800_+016.000", "lake", 59.8, 16.0, "Мелларен (западная и северная части), ~0,7 м по справочнику; центр сдвинут на северо-запад, чтобы квадрат не захватил Балтику"),
    ("malaren_baltic", "pt_+59.450_+017.000", "edge", 59.45, 17.0, "диагностика: квадрат с Балтикой и Стокгольмом — озеро соединено с морем протоками"),
    ("dead_sea_edge", "pt_+31.400_+036.350", "lake", 31.4, 36.35, "озеро −430 м, режется западным краем far, моря в квадрате нет"),
    ("salton_sea", "pt_+33.300_-114.900", "lake", 33.3, -114.9, "Солтон-Си −69 м, режется краем far, моря в квадрате нет"),
    ("superior", "pt_+47.500_-087.500", "lake", 47.5, -87.5, "Верхнее, 183 м; батиметрии Terrarium нет"),
]


def water_mask(h, s):
    return (s == 6) | ((s == 0) & (h <= NEAR0_M))


def _erode(m, r):
    """Эрозия ромбом радиуса r; за краем квадрата — вода (край не берег)."""
    for _ in range(r):
        p = np.pad(m, 1, constant_values=True)
        m = m & p[:-2, 1:-1] & p[2:, 1:-1] & p[1:-1, :-2] & p[1:-1, 2:]
    return m


def _grow_within(m, limit, r):
    """Геодезическое расширение m внутри limit на r клеток (ромб)."""
    for _ in range(r):
        p = np.pad(m, 1)
        m = (m | p[:-2, 1:-1] | p[2:, 1:-1] | p[1:-1, :-2] | p[1:-1, 2:]) & limit
    return m


def sea_mask(h, s, open_cells=OPEN_CELLS):
    """Главный признак (v2). Вода (класс 6, или класс 0 при h <= 0,5) сначала размыкается: эрозия на open_cells клеток
    разрывает проливы и протоки уже ≈ 1 км шириной (озеро, соединённое с морем каналом, — не одна компонента).
    Компонента эродированной воды (8-связность) размером >= MIN_CELLS — море, если одновременно
    (1) медиана высот far <= LEVEL_M, (2) она касается края far-квадрата и (3) 99-й процентиль высот >= -1 м (у моря берег на 0 м). Условия независимы: озеро выше порога
    отвергается уровнем, озеро любого уровня, целиком лежащее в квадрате, — краем. Помечаются клетки воды в пределах
    open_cells от ядра компоненты. Возвращает (маска моря, вода, метки ядер, медианы, касание края)."""
    w = water_mask(h, s)
    core = _erode(w, open_cells) if open_cells else w
    lab, n = label_runs(core)
    if n == 0:
        return np.zeros_like(w), w, lab, np.zeros(1), np.zeros(1, bool), np.zeros(1)
    flat = lab.ravel()
    order = np.argsort(flat, kind="stable")
    hs = h.ravel()[order]
    cnt = np.bincount(flat, minlength=n + 1)
    start = np.concatenate(([0], np.cumsum(cnt)))
    med = np.zeros(n + 1)
    edge = np.zeros(n + 1, bool)
    edge[np.unique(np.concatenate((lab[0], lab[-1], lab[:, 0], lab[:, -1])))] = True
    edge[0] = False
    sea_ids = np.zeros(n + 1, bool)
    up = np.zeros(n + 1)
    for L in range(1, n + 1):
        if cnt[L] >= MIN_CELLS:
            med[L] = np.median(hs[start[L]:start[L + 1]])
            up[L] = np.percentile(hs[start[L]:start[L + 1]], UPPER_Q)
            sea_ids[L] = med[L] <= LEVEL_M and edge[L] and up[L] >= UPPER_MIN_M
    seacore = sea_ids[lab]
    sea = _grow_within(seacore, w & ~(core & ~seacore), open_cells + 1) if open_cells else seacore
    return sea, w, lab, med, edge, up


def cand_cell_h(h, s):      # (a) покомпонентно не смотрим: вода и h <= 0,5
    return water_mask(h, s) & (h <= 0.5)


def cand_cls6_abs1(h, s):   # (b) класс 6 и |h| <= 1
    return (s == 6) & (np.abs(h) <= 1.0)


def cand_edge_connected(h, s):  # (b') (b), оставить только связное с краем far-квадрата
    m = cand_cell_h(h, s) & (np.abs(h) <= 1.0) | cand_cls6_abs1(h, s)
    lab, n = label_runs(m)
    ids = set(np.unique(np.concatenate((lab[0], lab[-1], lab[:, 0], lab[:, -1]))).tolist()) - {0}
    return np.isin(lab, list(ids)) if ids else np.zeros_like(m)


CANDS = {"a_water_h<=0.5": cand_cell_h, "b_cls6_abs(h)<=1": cand_cls6_abs1, "b2_b_connected_to_edge": cand_edge_connected}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cache", default=os.path.expanduser("~/.cache/dp-xdg/deltaplan-sea-ships-SEA-1/Deltaplan/locations"))
    ap.add_argument("--ti", default="/home/greg/projects/.tmp/ti/data/locations/training_island")
    a = ap.parse_args()
    rows, cand_rows, fp_total, tps = [], [], 0, []
    costs = []
    for pid, key, kind, lat, lon, note in PLACES:
        d = a.ti if key == "TI" else os.path.join(a.cache, key)
        if not os.path.exists(os.path.join(d, "meta.json")):
            rows.append(dict(id=pid, lat=lat, lon=lon, kind=kind, water_cells=0, sea_cells=0, sea_far_cells=0,
                             sea_far_marked=0, notes="нет данных места: " + d))
            continue
        _, o = load_place(d)
        h, s = o["far"]["h"], o["far"]["surface"]
        t = time.perf_counter()
        sea, w, lab, med, edge, up = sea_mask(h, s)
        dt = (time.perf_counter() - t) * 1000
        costs.append(dt)
        cnts = np.bincount(lab.ravel())[1:]
        big = int(np.argmax(cnts)) + 1 if len(cnts) else 0
        med_big = float(np.median(h[lab == big])) if big else 0.0
        touch_big = bool(edge[big]) if big else False
        up_big = float(up[big]) if big else 0.0
        dl = edt(~w)                    # до ближайшей не-воды (края квадрата не берег)
        far = w & (dl > FAR_CELLS)
        nfar, nmark = int(far.sum()), int((far & sea).sum())
        rows.append(dict(id=pid, lat=lat, lon=lon, kind=kind, water_cells=int(w.sum()), sea_cells=int(sea.sum()),
                         sea_far_cells=nfar, sea_far_marked=nmark, level_m=round(med_big, 3), touches_edge=touch_big, upper_q_m=round(up_big, 3),
                         notes=f"{note}; класс 6: {int((s == 6).sum())}, класс 0 и h<=0,5: {int(((s == 0) & (h <= NEAR0_M)).sum())}; "
                               f"медиана h крупнейшей компоненты воды {med_big:.2f} м; помечено с h>5 м: {int((sea & (h > 5)).sum())}; расчёт {dt:.0f} мс"))
        if kind == "sea":
            tps.append(nmark / nfar if nfar else 0.0)
        elif kind != "edge":
            fp_total += int(sea.sum())
        cr = dict(id=pid, kind=kind, water_cells=int(w.sum()), far_cells=nfar)
        for name, fn in CANDS.items():
            m = fn(h, s)
            cr[name] = dict(marked=int(m.sum()), far_marked=int((far & m).sum()))
        cand_rows.append(cr)
    missing = [r["id"] for r in rows if r["water_cells"] == 0 and r["kind"] != "edge"]
    tp_min = min(tps) if tps else 0.0
    works = (not missing) and fp_total == 0 and tp_min >= 0.8
    # запас по уровню: внутренние водоёмы, отвергнутые только уровнем (касаются края, но выше порога)
    lvl = [r["level_m"] for r in rows if r["kind"] not in ("sea", "edge") and r.get("touches_edge") and r["level_m"] > LEVEL_M]
    margin = min(lvl) if lvl else 0.0
    summary = dict(level_margin_m=float(margin),
        criterion=("Вода far = класс покрова 6 (far_surface.webp) или класс 0 (нет данных WorldCover: открытый океан) с h <= 0,5 м. "
                   "Компоненты воды (8-связность, far 1601x1601, шаг 100 м). Море — компонента размером >= 100 клеток (1 км2), у которой "
                   "одновременно медиана высот far.webp <= 0,25 м, она касается края far-квадрата и её 99-й процентиль высот >= -1 м (берег моря на 0 м; озеро ниже моря — нет); все её клетки помечены морем. Высоты: Copernicus над морем ровно 0 м, "
                   "Terrarium в океане даёт отрицательную батиметрию (доживает до far.webp), озёра выше — медиана выше порога."),
        works=bool(works), fp_inland_cells=int(fp_total), tp_sea_min=float(tp_min),
        where="", cost_ms=float(np.mean(costs)) if costs else 0.0, places=rows)
    # where заполняется из README-решения
    summary["where"] = ("build: новая стадия сборки после smooth (нужны итоговые far.webp и far_surface.webp), файл sea_mask в папке места; "
                        "счёт ~1 с на место и зависит от числа компонент, при загрузке он повторялся бы каждый раз")
    json.dump(summary, open(os.path.join(HERE, "summary.json"), "w"), ensure_ascii=False, indent=1)
    json.dump(cand_rows, open(os.path.join(HERE, "candidates.json"), "w"), ensure_ascii=False, indent=1)
    for r in rows:
        print(r["id"], r["kind"], r["water_cells"], r["sea_cells"], r["sea_far_cells"], r["sea_far_marked"], r["notes"][-60:])
    print("works", works, "fp", fp_total, "tp_min", tp_min, "cost_ms", summary["cost_ms"])
    for c in cand_rows:
        print(c)


if __name__ == "__main__":
    main()
