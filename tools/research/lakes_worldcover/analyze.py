"""Сравнение воды: сырой WorldCover 10 м / класс 25 м / канал A (OSM) / вода в H (снимок узлов 25 м).
Запуск: python -I analyze.py  (нужны cache/wc_<place>.npz из wc_fetch.py). Пишет results/*.json."""
import json, os, sys
import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.normpath(os.path.join(HERE, "../../../data/terrain"))
PLACES = ["aushkul", "altai", "ongudai", "askarovo"]
S, O, N = 10.0, -20000.0, 4001
RAD = 10000.0


def bilinear(a, fy, fx):
    y0 = np.clip(np.floor(fy).astype(int), 0, a.shape[0] - 2)
    x0 = np.clip(np.floor(fx).astype(int), 0, a.shape[1] - 2)
    ty, tx = (fy - y0)[:, None], (fx - x0)[None, :]
    a = a.astype(np.float32)
    top = a[np.ix_(y0, x0)] * (1 - tx) + a[np.ix_(y0, x0 + 1)] * tx
    bot = a[np.ix_(y0 + 1, x0)] * (1 - tx) + a[np.ix_(y0 + 1, x0 + 1)] * tx
    return top * (1 - ty) + bot * ty


def raster_lakes(lakes):
    """карта id озёр (int32) на сетке 10 м; id = индекс+1 в порядке убывания площади."""
    def ring(p):
        return [((p[k] - O) / S, (p[k + 1] - O) / S) for k in range(0, len(p) - 1, 2)]
    def area(p):
        r = ring(p)
        return 0.5 * abs(sum(r[i][0] * r[(i + 1) % len(r)][1] - r[(i + 1) % len(r)][0] * r[i][1] for i in range(len(r)))) * S * S
    order = sorted(range(len(lakes)), key=lambda i: -area(lakes[i]["p"]) if len(lakes[i]["p"]) >= 6 else 0)
    im = Image.new("I", (N, N), 0)
    d = ImageDraw.Draw(im)
    areas = {}
    for i in order:
        l = lakes[i]
        if len(l["p"]) < 6:
            continue
        areas[i] = area(l["p"])
        d.polygon(ring(l["p"]), fill=i + 1)
        for h in l.get("h", []):
            if len(h) >= 6:
                d.polygon(ring(h), fill=0)
    return np.array(im, np.int32), areas


def run(place):
    osm = json.load(open(f"{DATA}/{place}/osm.json"))
    lakes = osm["water"]["lakes"]
    z = np.load(f"{HERE}/cache/wc_{place}.npz")
    wc_frac = z["water_cnt"].astype(np.float32) / 9.0
    code = z["code"]
    wc = wc_frac >= 0.5
    d10 = np.array(Image.open(f"{DATA}/{place}/detail_detail10.png"))
    A = d10[..., 1].astype(np.float32) / 255.0
    cls = np.array(Image.open(f"{DATA}/{place}/detail_surface.png"))
    riv = np.array(Image.open(f"{DATA}/{place}/detail_water.png")) > 127
    ids, areas = raster_lakes(lakes)
    lake_m = ids > 0
    px = S * S  # м² на клетку 10 м
    out = {"place": place, "extent_km2": 1600.0}
    # --- общая площадь воды, км²
    out["area_km2"] = {
        "worldcover_raw_frac_sum": round(float(wc_frac.sum()) * px / 1e6, 3),
        "worldcover_raw_mask05": round(float(wc.sum()) * px / 1e6, 3),
        "class25_water": round(float((cls == 6).sum()) * 625 / 1e6, 3),
        "osm_channel_A": round(float(A.sum()) * px / 1e6, 3),
        "osm_lakes_polygons_raster": round(float(lake_m.sum()) * px / 1e6, 3),
        "osm_lakes_polygons_exact": round(sum(areas.values()) / 1e6, 3),
        "rivers_mask_25m": round(float(riv.sum()) * 625 / 1e6, 3),
    }
    inter = (wc & lake_m).sum(); uni = (wc | lake_m).sum()
    out["iou_wc_vs_osm_lakes_whole"] = round(float(inter / uni), 4)
    a_m = A >= 0.5
    out["iou_wc_vs_A05_whole"] = round(float((wc & a_m).sum() / (wc | a_m).sum()), 4)
    # --- снимок узлов 25 м и доля воды в круге 10 км (как measure.gd)
    n25 = 1601
    f10 = np.arange(n25) * 2.5
    Ab = bilinear(A * 255.0, f10, f10) >= 127.5
    Wb = bilinear(wc_frac * 255.0, f10, f10) >= 127.5   # вода WorldCover вместо A
    # OSM только реки: A без озёр
    A_riv = np.where(lake_m, 0, A)
    Rb = bilinear(A_riv * 255.0, f10, f10) >= 127.5
    c6 = cls == 6
    xs = O + 25.0 * np.arange(n25)
    disk = (xs[None, :] ** 2 + xs[:, None] ** 2) <= RAD ** 2
    def frac(m):
        return round(float(m[disk].mean()), 4)
    out["H_water_frac_disk10km"] = {
        "H0_rivers_mask_only(before SH-4)": frac(riv),
        "H1_rivers+class25(no OSM)": frac(riv | c6),
        "H2_rivers+class25+A(now)": frac(riv | c6 | Ab),
        "H3_rivers+class25+A_without_OSM_lakes": frac(riv | c6 | Rb),
        "H4_rivers+WC10m(proposed:A:=WC)": frac(riv | Wb),
        "H5_rivers+class25+WC10m+OSM_rivers_in_A": frac(riv | c6 | Wb | Rb),
        "class25_only": frac(c6),
        "A_only": frac(Ab),
        "WC10m_only": frac(Wb),
    }
    # --- по озёрам: крупнейшие 4 с именем или без, в пределах круга/слоя
    lid = sorted(areas, key=lambda i: -areas[i])
    big = []
    for i in lid:
        if len(big) >= 4:
            break
        big.append(i)
    rows = []
    def lake_row(i, pad=30):
        m = ids == i + 1
        jj, ii = np.where(m)
        if jj.size == 0:
            return None
        j0, j1, i0, i1 = max(jj.min() - pad, 0), min(jj.max() + pad + 1, N), max(ii.min() - pad, 0), min(ii.max() + pad + 1, N)
        sl = (slice(j0, j1), slice(i0, i1))
        mm = m[sl]
        w = wc[sl]
        cov = float((w & mm).sum() / mm.sum())
        # окно H-узлов 25 м
        a0, a1, b0, b1 = int(j0 * S / 25), int(j1 * S / 25) + 1, int(i0 * S / 25), int(i1 * S / 25) + 1
        s25 = (slice(a0, a1), slice(b0, b1))
        codes, cn = np.unique(code[sl][mm], return_counts=True)
        top = {int(c): round(float(n / mm.sum()), 3) for c, n in sorted(zip(codes, cn), key=lambda t: -t[1])[:3]}
        return {
            "name": lakes[i].get("n", ""), "osm_polygon_km2": round(areas[i] / 1e6, 4),
            "wc_raw_km2_in_window": round(float(wc_frac[sl].sum()) * px / 1e6, 4),
            "wc_covers_osm_polygon": round(cov, 3),
            "iou_wc_osm": round(float((w & mm).sum() / (w | mm).sum()), 3),
            "class25_km2": round(float(c6[s25].sum()) * 625 / 1e6, 4),
            "A_km2": round(float(A[sl].sum()) * px / 1e6, 4),
            "H_nodes_class25_only_km2": round(float((riv | c6)[s25].sum()) * 625 / 1e6, 4),
            "H_nodes_now_km2": round(float((riv | c6 | Ab)[s25].sum()) * 625 / 1e6, 4),
            "wc_codes_inside_polygon": top,
        }
    out["biggest_lakes"] = [r for r in (lake_row(i) for i in big) if r]
    # --- классы размера: обнаружение WC
    bins = [(0, 0.5e4), (0.5e4, 2e4), (2e4, 1e5), (1e5, 1e6), (1e6, 1e9)]
    names = ["<0.5 га", "0.5–2 га", "2–10 га", "10–100 га", ">100 га"]
    tab = []
    cover = np.zeros(len(lakes), np.float32)
    flat_ids = ids.ravel(); flat_wc = wc.ravel()
    cnt_all = np.bincount(flat_ids, minlength=len(lakes) + 1)
    cnt_wc = np.bincount(flat_ids[flat_wc], minlength=len(lakes) + 1)
    for (a, b), nm in zip(bins, names):
        sel = [i for i in areas if a <= areas[i] < b]
        det = [i for i in sel if cnt_all[i + 1] > 0 and cnt_wc[i + 1] / cnt_all[i + 1] >= 0.5]
        tot = sum(areas[i] for i in sel)
        cw = sum(cnt_wc[i + 1] * px for i in sel)
        tab.append({"class": nm, "n_osm": len(sel), "n_detected_ge50pct": len(det),
                    "osm_area_km2": round(tot / 1e6, 4), "wc_inside_osm_km2": round(float(cw) / 1e6, 4)})
    out["size_classes"] = tab
    # --- WC-вода вне озёр OSM и вне рек A (что видит WC сверх OSM)
    extra = wc & ~(A >= 0.5) & ~lake_m
    out["wc_water_not_in_osm_km2"] = round(float(extra.sum()) * px / 1e6, 3)
    # --- самые крупные озёра OSM, которых WC не видит (<20% покрытия), площадь ≥ 1 га
    miss = []
    for i in lid:
        if areas[i] < 1e4 or cnt_all[i + 1] == 0:
            continue
        c = cnt_wc[i + 1] / cnt_all[i + 1]
        if c < 0.2:
            r = lake_row(i, 5)
            miss.append({"name": lakes[i].get("n", ""), "osm_km2": round(areas[i] / 1e6, 4), "wc_cover": round(float(c), 3),
                         "wc_codes_inside": r["wc_codes_inside_polygon"] if r else None})
        if len(miss) >= 6:
            break
    out["largest_osm_lakes_missed_by_wc"] = miss
    os.makedirs(f"{HERE}/results", exist_ok=True)
    json.dump(out, open(f"{HERE}/results/{place}.json", "w"), ensure_ascii=False, indent=1)
    np.savez_compressed(f"{HERE}/cache/m_{place}.npz", wc=wc, lake=lake_m, A=A >= 0.5)
    print(json.dumps(out, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    for p in (sys.argv[1:] or PLACES):
        run(p)
