"""Входные станции для мест LT-4: lat/lon и высота земли по данным измерений.

  python3 make_stations_in.py  → stations_in.csv (site,station,level_m,lat,lon,ground_asl_m)

Perdigão: lat/lon мачт — tools/research/cases/perdigao/out/masts.csv (ETRS89 из NetCDF/PT-TM06 → WGS84, pyproj),
высота земли — towers_layout.csv (terrain_elev_asl_m). Уровни приборов — в cases/make_cases.py (из windowmean).
Askervein: X, Y — локальная сетка отчёта Taylor & Teunissen = сетка OSGB36 без буквы квадрата NF
(E = X, N = 800000 + Y; HT -> 57,19 с. ш., 7,37 з. д., остров Южный Уист) плюс сдвиг ASK_DE/ASK_DN по рельефу, Z — высота земли.
OSGB36 (Эйри 1830, ТМ, F0 0,9996012717) -> широта/долгота обратным разложением ОС и помертом Хелмерта
OSGB36 -> WGS84 (7 параметров, ошибка до ~5 м против OSTN15 — меньше шага рельефа 25 м).
"""
import csv
import math
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
MASTS = ROOT / "tools/research/cases/perdigao/out/masts.csv"
ASK = ROOT / "tools/research/data/askervein/askervein_validation1.txt"
# Привязка сетки отчёта к OSGB подобрана по рельефу: поиск сдвига (и поворота, получился 0) станций в кадре места,
# минимизирующий RMS(высота растра игры − Z станции) по 41 станции: RMS 38 м без сдвига -> 1,5 м (макс. 3,3 м)
# при E' = E − 112 м, N' = N − 197 м (шаг поиска 5 м). Причина расхождения 226 м не выяснялась (старая локальная сетка,
# гео-привязка DSM — не проверялось).
ASK_DE, ASK_DN = -112.0, -197.0


def osgb_to_wgs84(E, N):
    a, b = 6377563.396, 6356256.909
    F0, lat0, lon0 = 0.9996012717, math.radians(49), math.radians(-2)
    N0, E0 = -100000.0, 400000.0
    e2 = 1 - b * b / (a * a)
    n = (a - b) / (a + b)
    phi = lat0
    M = 0.0
    while True:
        phi = (N - N0 - M) / (a * F0) + phi
        M = b * F0 * ((1 + n + 5 / 4 * n**2 + 5 / 4 * n**3) * (phi - lat0)
                      - (3 * n + 3 * n**2 + 21 / 8 * n**3) * math.sin(phi - lat0) * math.cos(phi + lat0)
                      + (15 / 8 * n**2 + 15 / 8 * n**3) * math.sin(2 * (phi - lat0)) * math.cos(2 * (phi + lat0))
                      - 35 / 24 * n**3 * math.sin(3 * (phi - lat0)) * math.cos(3 * (phi + lat0)))
        if abs(N - N0 - M) < 1e-5:
            break
    s, c, t = math.sin(phi), math.cos(phi), math.tan(phi)
    nu = a * F0 / math.sqrt(1 - e2 * s * s)
    rho = a * F0 * (1 - e2) / (1 - e2 * s * s) ** 1.5
    eta2 = nu / rho - 1
    dE = E - E0
    VII = t / (2 * rho * nu)
    VIII = t / (24 * rho * nu**3) * (5 + 3 * t * t + eta2 - 9 * t * t * eta2)
    IX = t / (720 * rho * nu**5) * (61 + 90 * t * t + 45 * t**4)
    X = 1 / (c * nu)
    XI = 1 / (6 * c * nu**3) * (nu / rho + 2 * t * t)
    XII = 1 / (120 * c * nu**5) * (5 + 28 * t * t + 24 * t**4)
    XIIA = 1 / (5040 * c * nu**7) * (61 + 662 * t * t + 1320 * t**4 + 720 * t**6)
    lat = phi - VII * dE**2 + VIII * dE**4 - IX * dE**6
    lon = lon0 + X * dE - XI * dE**3 + XII * dE**5 - XIIA * dE**7
    # OSGB36 (Эйри) -> декартовы -> Хелмерт -> WGS84 (GRS80)
    H = 0.0
    nu1 = a / math.sqrt(1 - e2 * math.sin(lat) ** 2)
    x = (nu1 + H) * math.cos(lat) * math.cos(lon)
    y = (nu1 + H) * math.cos(lat) * math.sin(lon)
    z = ((1 - e2) * nu1 + H) * math.sin(lat)
    tx, ty, tz = -446.448, 125.157, -542.060
    s_ = 20.4894e-6
    rx, ry, rz = [math.radians(v / 3600) for v in (-0.1502, -0.2470, -0.8421)]
    x2 = tx + (1 + s_) * x - rz * y + ry * z
    y2 = ty + rz * x + (1 + s_) * y - rx * z
    z2 = tz - ry * x + rx * y + (1 + s_) * z
    a2, b2 = 6378137.0, 6356752.314140
    e22 = 1 - b2 * b2 / (a2 * a2)
    p = math.hypot(x2, y2)
    lat2 = math.atan2(z2, p * (1 - e22))
    for _ in range(10):
        nu2 = a2 / math.sqrt(1 - e22 * math.sin(lat2) ** 2)
        lat2 = math.atan2(z2 + e22 * nu2 * math.sin(lat2), p)
    return math.degrees(lat2), math.degrees(math.atan2(y2, x2))


def main():
    rows = []
    towers = {}
    for r in csv.DictReader(open(ROOT / "tools/research/data/perdigao/towers_layout.csv")):
        towers[r["name"]] = float(r["terrain_elev_asl_m"])
    for r in csv.DictReader(open(MASTS)):
        rows.append(("perdigao", r["name"], "", float(r["lat"]), float(r["lon"]), towers.get(r["name"], float(r["ground_asl"]))))
    seen = set()
    for r in csv.DictReader(open(ASK)):
        name = r["Name"].replace(" ", "")
        key = (name, r["X(m)"], r["Y(m)"])
        if key in seen:
            continue
        seen.add(key)
        lat, lon = osgb_to_wgs84(float(r["X(m)"]) + ASK_DE, 800000.0 + float(r["Y(m)"]) + ASK_DN)
        rows.append(("askervein", name, "", lat, lon, float(r["Z(m)"])))
    with open(HERE / "stations_in.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["site", "station", "level_m", "lat", "lon", "ground_asl_m"])
        for s in rows:
            w.writerow([s[0], s[1], s[2], f"{s[3]:.7f}", f"{s[4]:.7f}", s[5]])
    print(len(rows), "станций")


if __name__ == "__main__":
    main()
