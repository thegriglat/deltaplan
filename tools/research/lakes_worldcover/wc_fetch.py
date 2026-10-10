"""Окно ESA WorldCover 10 м (COG на S3, HTTP range) для места: вода на сетке detail10 (4001x4001, 10 м)
с k=3 подвыборками на клетку (как SurfaceStage._detail10). Пишет cache/wc_<place>.npz (uint8: число водных
подвыборок 0..9 и тот же счёт для класса 'любой код' не нужен). Запуск: python -I wc_fetch.py aushkul ..."""
import json, math, struct, sys, zlib, os, urllib.request
import numpy as np

URL = "https://esa-worldcover.s3.eu-central-1.amazonaws.com/v200/2021/map/ESA_WorldCover_10m_2021_v200_{t}_Map.tif"
R = 6371008.8
HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.normpath(os.path.join(HERE, "../../../data/terrain"))
CACHE = os.path.join(HERE, "cache")


def rng(url, a, b):
    req = urllib.request.Request(url, headers={"Range": f"bytes={a}-{b}", "User-Agent": "deltaplan-research"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


class Cog:
    def __init__(self, url):
        self.url = url
        h = rng(url, 0, 262143)
        assert h[:2] == b"II" and struct.unpack("<H", h[2:4])[0] == 42, "не классический LE TIFF"
        off = struct.unpack("<I", h[4:8])[0]
        n = struct.unpack("<H", h[off:off + 2])[0]
        tags = {}
        sz = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 12: 8, 16: 8}
        fm = {1: "B", 2: "c", 3: "H", 4: "I", 12: "d", 16: "Q"}
        for i in range(n):
            e = h[off + 2 + 12 * i: off + 14 + 12 * i]
            tag, typ, cnt = struct.unpack("<HHI", e[:8])
            nb = sz[typ] * cnt
            raw = e[8:8 + nb] if nb <= 4 else h[struct.unpack("<I", e[8:12])[0]:][:nb]
            tags[tag] = struct.unpack("<%d%s" % (cnt, fm[typ]), raw) if typ in fm and typ != 2 else raw
        self.w, self.h = tags[256][0], tags[257][0]
        self.tw, self.th = tags[322][0], tags[323][0]
        self.off, self.cnt = tags[324], tags[325]
        self.comp = tags[259][0]
        self.pred = tags.get(317, (1,))[0]
        sc, tp = tags[33550], tags[33922]
        self.px, self.py = sc[0], sc[1]
        self.lon0, self.lat0 = tp[3], tp[4]
        self.tx = (self.w + self.tw - 1) // self.tw
        self.cache = {}

    def tile(self, ti, tj):
        k = (ti, tj)
        if k not in self.cache:
            i = tj * self.tx + ti
            raw = rng(self.url, self.off[i], self.off[i] + self.cnt[i] - 1)
            d = zlib.decompress(raw) if self.comp in (8, 32946) else raw
            a = np.frombuffer(d, np.uint8).reshape(self.th, self.tw)
            if self.pred == 2:
                a = np.cumsum(a, axis=1, dtype=np.uint8)
            self.cache[k] = a
        return self.cache[k]

    def sample(self, col, row):
        """col,row — массивы глобальных пикселей (одинаковой формы) -> uint8 (255 вне файла)."""
        out = np.full(col.shape, 255, np.uint8)
        ok = (col >= 0) & (col < self.w) & (row >= 0) & (row < self.h)
        ti = np.where(ok, col // self.tw, -1)
        tj = np.where(ok, row // self.th, -1)
        for a in np.unique(ti[ok]):
            for b in np.unique(tj[ok & (ti == a)]):
                m = ok & (ti == a) & (tj == b)
                out[m] = self.tile(a, b)[row[m] - b * self.th, col[m] - a * self.tw]
        return out


def grid_deg(meta, k=3, n=4001, step=10.0, o=-20000.0):
    mlat = R * math.pi / 180
    mlon = mlat * math.cos(math.radians(meta["center_lat"]))
    offs = (np.arange(k) + 0.5) / k - 0.5
    z = o + (np.arange(n)[:, None] + 0 * offs) * step + offs * step
    x = o + (np.arange(n)[:, None]) * step + offs * step
    lat = meta["center_lat"] - z.reshape(-1) / mlat
    lon = meta["center_lon"] + x.reshape(-1) / mlon
    return lat, lon


def run(place):
    meta = json.load(open(f"{DATA}/{place}/meta.json"))
    lat, lon = grid_deg(meta)
    la3 = np.floor(lat / 3).astype(int) * 3
    lo3 = np.floor(lon / 3).astype(int) * 3
    n = lat.size
    wat = np.zeros((n, n), bool)   # подвыборки: строка x столбец
    code = np.zeros((n, n), np.uint8)
    for la in np.unique(la3):
        for lo in np.unique(lo3):
            name = "%s%02d%s%03d" % ("N" if la >= 0 else "S", abs(la), "E" if lo >= 0 else "W", abs(lo))
            c = Cog(URL.format(t=name))
            rm, cm = la3 == la, lo3 == lo
            rr = np.floor((c.lat0 - lat[rm]) / c.py).astype(int)
            cc = np.floor((lon[cm] - c.lon0) / c.px).astype(int)
            C, Rr = np.meshgrid(cc, rr)
            v = c.sample(C, Rr)
            ii = np.ix_(np.where(rm)[0], np.where(cm)[0])
            code[ii] = v
            print(place, name, "tiles", len(c.cache), flush=True)
    wat = code == 80
    cnt = wat.reshape(4001, 3, 4001, 3).sum(axis=(1, 3)).astype(np.uint8)
    os.makedirs(CACHE, exist_ok=True)
    np.savez_compressed(f"{CACHE}/wc_{place}.npz", water_cnt=cnt, code=code[1::3, 1::3])  # code — центральная подвыборка
    print(place, "water frac", cnt.sum() / 9 / 4001 ** 2)


if __name__ == "__main__":
    for p in sys.argv[1:]:
        run(p)
