"""Проверка красивых мест по рельефу (SCP-К2, docs/contracts/scenic-places.md).

Запуск: python3 tools/places/check_scenic_places.py <файл>… [--table out.md]
Рельеф: Terrarium z11 (AWS), кэш ~/.cache/dp-places/terrarium/, PNG читается через zlib + numpy.
Итог последней строкой: 'checked N, failed M'; код выхода 0 только при failed 0.
"""
import argparse, json, math, re, struct, sys, time, urllib.request, zlib
from pathlib import Path

import numpy as np

CACHE = Path.home() / ".cache" / "dp-places" / "terrarium"
URL = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png"
Z = 11
R_EARTH = 6371000.0
KINDS = {"mountain", "canyon", "lake", "coast", "volcano", "glacier", "valley", "fjord", "desert", "island"}
FIELDS = ["id", "country", "name_en", "name_ru", "kind", "lat", "lon", "heading_deg", "agl_m",
          "view_lat", "view_lon", "why_en", "why_ru"]
MAX_VIEW_M, MAX_BEARING_DEG = 15000.0, 30.0
PATH_M, PATH_STEP, MARGIN_M, GLIDE = 5000, 100, 50.0, 10.0
RELIEF_R, RELIEF_MIN = 5000.0, 100.0


def dist_bearing(lat1, lon1, lat2, lon2):
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dl = math.radians(lon2 - lon1)
    a = math.sin((p2 - p1) / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    d = 2 * R_EARTH * math.asin(math.sqrt(a))
    y = math.sin(dl) * math.cos(p2)
    x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
    return d, math.degrees(math.atan2(y, x)) % 360.0


def offset(lat, lon, bearing_deg, dist_m):
    """Точка на расстоянии dist_m по пеленгу (сфера)."""
    dd, b = dist_m / R_EARTH, math.radians(bearing_deg)
    p1, l1 = math.radians(lat), math.radians(lon)
    p2 = math.asin(math.sin(p1) * math.cos(dd) + math.cos(p1) * math.sin(dd) * math.cos(b))
    l2 = l1 + math.atan2(math.sin(b) * math.sin(dd) * math.cos(p1), math.cos(dd) - math.sin(p1) * math.sin(p2))
    return math.degrees(p2), (math.degrees(l2) + 540.0) % 360.0 - 180.0


def read_png_rgb(data):
    """Минимальный декодер PNG: 8 бит, RGB/RGBA, без interlace."""
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    pos, idat, w = 8, b"", None
    while pos < len(data):
        ln, typ = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + ln]
        pos += 12 + ln
        if typ == b"IHDR":
            w, h, depth, ctype, _, _, inter = struct.unpack(">IIBBBBB", body)
            assert depth == 8 and ctype in (2, 6) and inter == 0, "формат PNG"
        elif typ == b"IDAT":
            idat += body
        elif typ == b"IEND":
            break
    bpp = 3 if ctype == 2 else 4
    raw = zlib.decompress(idat)
    stride = w * bpp
    out = np.zeros((h, stride), np.uint8)
    prev = np.zeros(stride, np.int32)
    p = 0
    for y in range(h):
        f = raw[p]
        line = np.frombuffer(raw, np.uint8, stride, p + 1).astype(np.int32)
        p += stride + 1
        if f == 0:
            cur = line
        elif f == 2:
            cur = (line + prev) & 255
        elif f == 1:
            cur = line.copy()
            for i in range(bpp, stride):
                cur[i] = (cur[i] + cur[i - bpp]) & 255
        elif f == 3:
            cur = line.copy()
            for i in range(stride):
                a = cur[i - bpp] if i >= bpp else 0
                cur[i] = (cur[i] + ((a + prev[i]) >> 1)) & 255
        elif f == 4:
            cur = line.copy()
            for i in range(stride):
                a = cur[i - bpp] if i >= bpp else 0
                c = prev[i - bpp] if i >= bpp else 0
                b = prev[i]
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                cur[i] = (cur[i] + pr) & 255
        else:
            raise ValueError("фильтр PNG %d" % f)
        out[y] = cur
        prev = cur
    return out.reshape(h, w, bpp)[..., :3]


_tiles = {}


def tile(x, y):
    key = (x, y)
    if key in _tiles:
        return _tiles[key]
    path = CACHE / str(Z) / str(x) / ("%d.png" % y)
    arr = None
    if not path.exists():
        for attempt in range(3):
            try:
                req = urllib.request.Request(URL.format(z=Z, x=x, y=y), headers={"User-Agent": "deltaplan-scenic-check"})
                with urllib.request.urlopen(req, timeout=60) as r:
                    data = r.read()
                path.parent.mkdir(parents=True, exist_ok=True)
                tmp = path.with_suffix(".part")
                tmp.write_bytes(data)
                tmp.replace(path)
                break
            except Exception as ex:  # noqa: BLE001
                print("  terrarium %d/%d/%d: %s" % (Z, x, y, ex), file=sys.stderr)
                time.sleep(2 * (attempt + 1))
    if path.exists():
        a = read_png_rgb(path.read_bytes()).astype(np.float64)
        arr = a[..., 0] * 256 + a[..., 1] + a[..., 2] / 256 - 32768
    _tiles[key] = arr
    return arr


def elevation(lat, lon):
    """Высота, м (билинейно по пикселям Terrarium z11); nan, если тайла нет."""
    n = 2 ** Z
    fx = (lon + 180.0) / 360.0 * n
    lr = math.radians(max(-85.0511, min(85.0511, lat)))
    fy = (1.0 - math.asinh(math.tan(lr)) / math.pi) / 2.0 * n
    px, py = fx * 256 - 0.5, fy * 256 - 0.5
    x0, y0 = math.floor(px), math.floor(py)
    tx, ty = px - x0, py - y0
    v = 0.0
    for dx, wx in ((0, 1 - tx), (1, tx)):
        for dy, wy in ((0, 1 - ty), (1, ty)):
            gx, gy = x0 + dx, y0 + dy
            t = tile((gx // 256) % n, min(max(gy // 256, 0), n - 1))
            if t is None:
                return float("nan")
            v += wx * wy * t[min(max(gy, 0), n * 256 - 1) % 256, gx % 256]
    return v


def check_place(p, elev=elevation):
    """→ (ok, текст, числа). Пункты 1–4 SCP-К2; elev(lat, lon) подменяется в тестах."""
    why, st = [], {}
    d, brg = dist_bearing(p["lat"], p["lon"], p["view_lat"], p["view_lon"])
    dh = abs((brg - p["heading_deg"] + 180.0) % 360.0 - 180.0)
    st.update(dist_m=d, bearing=brg, dh=dh)
    if d > MAX_VIEW_M:
        why.append("вид дальше %.0f м" % d)
    if dh > MAX_BEARING_DEG:
        why.append("пеленг %.0f° vs курс %.0f°" % (brg, p["heading_deg"]))
    h0 = elev(p["lat"], p["lon"])
    hv = elev(p["view_lat"], p["view_lon"])
    st["h0"] = h0
    if not (math.isfinite(h0) and math.isfinite(hv)):
        why.append("нет данных рельефа")
        return False, "FAIL " + "; ".join(why), st
    worst, gmax = float("inf"), -1e9
    for dd in range(0, PATH_M + 1, PATH_STEP):
        la, lo = offset(p["lat"], p["lon"], p["heading_deg"], dd)
        g = elev(la, lo)
        if not math.isfinite(g):
            why.append("нет данных на пути")
            break
        gmax = max(gmax, g)
        worst = min(worst, h0 + p["agl_m"] - dd / GLIDE - (g + MARGIN_M))
    st.update(path_max=gmax, margin=worst)
    if math.isfinite(worst) and worst < 0:
        why.append("запас высоты %.0f м < 0" % worst)
    vals = []
    step = 250.0
    k = int(RELIEF_R // step)
    for i in range(-k, k + 1):
        for j in range(-k, k + 1):
            if math.hypot(i, j) * step <= RELIEF_R:
                la, lo = offset(p["view_lat"], p["view_lon"], 0.0, j * step)
                la2, lo2 = offset(la, lo, 90.0, i * step)
                v = elev(la2, lo2)
                if math.isfinite(v):
                    vals.append(v)
    relief = (max(vals) - min(vals)) if vals else 0.0
    st["relief"] = relief
    if relief < RELIEF_MIN:
        why.append("перепад у вида %.0f м < %.0f" % (relief, RELIEF_MIN))
    ok = not why
    txt = ("OK" if ok else "FAIL " + "; ".join(why)) + \
        " | h0 %.0f, max ground %.0f, запас %.0f, перепад %.0f, дист %.0f м, пеленг %.0f° (курс %.0f°)" % (
            h0, gmax, worst, relief, d, brg, p["heading_deg"])
    return ok, txt, st


def check_format(p):
    errs = []
    if list(p.keys()) != FIELDS and set(p) != set(FIELDS):
        errs.append("поля")
        return errs
    if not re.match(r"^[a-z]{2}/[a-z0-9-]+$", p["id"]):
        errs.append("id")
    if p["kind"] not in KINDS:
        errs.append("kind")
    return errs


def table(places, countries):
    lines = ["| Страна | Место | Тип | Чем красиво | Старт (lat, lon) | Курс | Высота, м | Карта |",
             "|---|---|---|---|---|---|---|---|"]
    for p in sorted(places, key=lambda q: (countries.get(q["country"], {}).get("ru", q["country"]), q["name_ru"])):
        la, lo = p["lat"], p["lon"]
        url = "https://www.openstreetmap.org/?mlat=%s&mlon=%s#map=12/%s/%s" % (la, lo, la, lo)
        lines.append("| %s | %s | %s | %s | %.4f, %.4f | %.0f° | %d | [карта](%s) |" % (
            countries.get(p["country"], {}).get("ru", p["country"]), p["name_ru"], p["kind"], p["why_ru"],
            la, lo, p["heading_deg"], p["agl_m"], url))
    return "\n".join(lines) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    ap.add_argument("--table")
    a = ap.parse_args(argv)
    places, countries, seen = [], {}, set()
    failed = 0
    per_country = {}
    for f in a.files:
        d = json.loads(Path(f).read_text(encoding="utf-8"))
        countries.update(d.get("countries", {}))
        places.extend(d.get("places", []))
    for p in places:
        errs = check_format(p)
        if p.get("id") in seen:
            errs.append("id повторяется")
        seen.add(p.get("id"))
        if errs:
            print("%s FAIL формат: %s" % (p.get("id"), ", ".join(errs)))
            failed += 1
            continue
        per_country[p["country"]] = per_country.get(p["country"], 0) + 1
        ok, txt, _ = check_place(p)
        print("%s %s" % (p["id"], txt))
        failed += 0 if ok else 1
    for c, n in sorted(per_country.items()):
        if not 5 <= n <= 10:
            print("%s FAIL стран: %d мест (нужно 5–10)" % (c, n))
            failed += 1
    if a.table:
        Path(a.table).write_text(table(places, countries), encoding="utf-8")
    print("checked %d, failed %d" % (len(places), failed))
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
