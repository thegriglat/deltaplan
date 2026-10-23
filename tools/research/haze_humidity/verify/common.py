"""Общее для HH-9: места, чтение сеток HH1/HH2, климат на дату (как HH7), поправка Td к высоте."""
import calendar, csv, datetime as dt, os, struct, sys
import numpy as np
import brotli

H = os.path.dirname(os.path.abspath(__file__))
RAW = os.path.expanduser("~/data/haze_humidity/verify")           # сырые данные вне репозитория
REPO = os.path.abspath(H + "/../../../..")
TD_BIN = REPO + "/data/climate/dew_point_1deg.bin"               # HH1 v1 (в feature/haze-humidity)
UA_BIN = RAW + "/upper_air_1deg.bin"                              # HH2 v2 из ветки haze-humidity/HH-1g
SD_UA = RAW + "/t700_sd.npz"                                      # σ T700 (HH-1g) — пока NaN

# 7 мест игры (upper_air/sites.py) + 31 точка суши
GAME = {
    "altai": (51.87, 85.87), "ongudai": (50.79, 86.13), "askarovo": (53.26, 58.54), "aushkul": (54.72, 59.69),
    "crimea": (44.95, 35.12), "dry_darab": (28.75, 54.55), "wet_cairns": (-16.92, 145.77),
}
EXTRA = {  # имя: (lat, lon, климат)
    "tamanrasset": (22.79, 5.53, "пустыня, высокогорье Сахары"), "riyadh": (24.71, 46.68, "пустыня"),
    "alice_springs": (-23.70, 133.88, "пустыня Австралии"), "phoenix": (33.45, -112.07, "пустыня США"),
    "cairo": (30.04, 31.24, "пустыня, дельта Нила"), "delhi": (28.61, 77.21, "муссон"),
    "mumbai": (19.08, 72.88, "муссон, побережье"), "bangkok": (13.76, 100.50, "муссон"),
    "manaus": (-3.12, -60.02, "влажные тропики"), "nairobi": (-1.29, 36.82, "высокогорье тропиков 1650 м"),
    "johannesburg": (-26.20, 28.05, "субтропики, плато 1700 м"), "lagos": (6.52, 3.38, "побережье тропиков"),
    "london": (51.51, -0.13, "умеренный океанический"), "berlin": (52.52, 13.40, "умеренный"),
    "moscow": (55.76, 37.62, "умеренный континентальный"), "yakutsk": (62.03, 129.73, "субарктика"),
    "fairbanks": (64.84, -147.72, "субарктика"), "denver": (39.74, -104.99, "высокогорье США 1600 м"),
    "la_paz": (-16.50, -68.15, "Альтиплано 3600 м"), "quito": (-0.18, -78.47, "Анды 2800 м"),
    "lhasa": (29.65, 91.13, "Тибет 3650 м"), "chicago": (41.88, -87.63, "умеренный"),
    "seattle": (47.61, -122.33, "побережье Тихого океана"), "buenos_aires": (-34.60, -58.38, "субтропики Ю. полушария"),
    "santiago": (-33.45, -70.67, "средиземноморье Ю. полушария"), "sydney": (-33.87, 151.21, "побережье Австралии"),
    "perth": (-31.95, 115.86, "средиземноморье Австралии"), "tokyo": (35.68, 139.69, "муссон умеренный"),
    "ulaanbaatar": (47.92, 106.92, "холодная степь 1300 м"), "almaty": (43.24, 76.89, "предгорья"),
    "madrid": (40.42, -3.70, "средиземноморье, плато 650 м"),
}
PLACES = [(k, la, lo, "игра") for k, (la, lo) in GAME.items()] + [(k, v[0], v[1], "доп: " + v[2]) for k, v in EXTRA.items()]


def _hdr(buf):
    return buf[:4].decode(), struct.unpack("<HHHHHH", buf[4:16]), struct.unpack("<ffffffff", buf[16:48]), struct.unpack("<IIII", buf[48:64])


def load_td(path=TD_BIN):
    b = open(path, "rb").read()
    magic, (ver, codec, nlon, nlat, nm, _), (lon0, lat0, dlon, dlat, tds, tdo, sds, zs), (raw_size, comp, y0, y1) = _hdr(b)
    assert magic == "HHTD" and ver == 1 and codec == 1 and len(b) == 64 + comp
    raw = brotli.decompress(b[64:]); assert len(raw) == raw_size
    a = np.frombuffer(raw, "<i2")
    n = nm * nlat * nlon
    td = a[:n].reshape(nm, nlat, nlon).astype(np.float64); sd = a[n:2 * n].reshape(nm, nlat, nlon).astype(np.float64)
    z = a[2 * n:].reshape(nlat, nlon).astype(np.float64)
    miss = td == -32768
    return {"td": np.where(miss, np.nan, td * tds + tdo), "sd": np.where(sd == -32768, np.nan, sd * sds), "z": z * zs, "years": (y0, y1)}


def load_ua(path=UA_BIN):
    b = open(path, "rb").read()
    magic, (ver, codec, nlon, nlat, nm, lvl), (lon0, lat0, dlon, dlat, ts, to, zs, zo), (raw_size, comp, y0, y1) = _hdr(b)
    assert magic == "HHUA" and codec == 1 and len(b) == 64 + comp and lvl == 700
    raw = brotli.decompress(b[64:]); assert len(raw) == raw_size
    a = np.frombuffer(raw, "<i2").astype(np.float64); n = nm * nlat * nlon
    sd = np.load(SD_UA)["sd_k"].astype(np.float64) if os.path.exists(SD_UA) else np.full((nm, nlat, nlon), np.nan)
    return {"t": a[:n].reshape(nm, nlat, nlon) * ts + to, "z": a[n:].reshape(nm, nlat, nlon) * zs + zo, "sd": sd, "years": (y0, y1), "hdr_ver": ver}


def bil(a, lat, lon):
    """Билинейно по центрам ячеек 1° (HH7): долгота по кругу, широта зажата в [-89.5, 89.5]."""
    fj = min(max(lat, -89.5), 89.5) + 89.5; fi = lon + 179.5
    j0 = min(int(np.floor(fj)), 178); tj = fj - j0
    i0 = int(np.floor(fi)); ti = fi - i0; i0 %= 360; i1 = (i0 + 1) % 360
    return (a[..., j0, i0] * (1 - tj) * (1 - ti) + a[..., j0, i1] * (1 - tj) * ti
            + a[..., j0 + 1, i0] * tj * (1 - ti) + a[..., j0 + 1, i1] * tj * ti)


def month_weights(d):
    """Значение месяца — на 15-е, между серединами линейно (декабрь<->январь по кругу): (m0, m1, w1), месяцы 0..11."""
    if d.day >= 15:
        n = calendar.monthrange(d.year, d.month)[1]; m0 = d.month - 1; m1 = d.month % 12; w = (d.day - 15) / n
    else:
        py, pm = (d.year, d.month - 1) if d.month > 1 else (d.year - 1, 12)
        n = calendar.monthrange(py, pm)[1]; m0 = pm - 1; m1 = d.month - 1; w = (d.day + n - 15) / n
    return m0, m1, w


def at_day(a12, lat, lon, d):
    """a12: (12,180,360) -> значение на дату d."""
    v = bil(a12, lat, lon); m0, m1, w = month_weights(d)
    return v[m0] * (1 - w) + v[m1] * w


GTD = {"DJF": -4.5, "MAM": -3.9, "JJA": -3.3, "SON": -4.2}   # 30-60°, HH7/HH-1 README


def g_td(lat, d):
    """К/км, контракт HH7: 30–60° по сезону (местному; юг — сдвиг на 6 месяцев), тропики ±20° −4,6, прочее −4,0."""
    a = abs(lat)
    if 30 <= a <= 60:
        m = d.month if lat >= 0 else (d.month + 5) % 12 + 1
        return GTD["DJF" if m in (12, 1, 2) else "MAM" if m in (3, 4, 5) else "JJA" if m in (6, 7, 8) else "SON"]
    return -4.6 if a <= 20 else -4.0
