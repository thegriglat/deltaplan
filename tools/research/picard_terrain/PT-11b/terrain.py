"""PT-11: рельеф места из places/<имя>.bin/.json (int16 LE, строка j к +Z) и поиск гребней по линии ветра."""
import json
import numpy as np

ROOT = None  # каталог копии (tests/fixtures/wind/...)


class Terrain:
    def __init__(self, root, place):
        m = json.load(open(f"{root}/tests/fixtures/wind/places/{place}.json"))
        g = m["grid"]
        self.nx, self.nz, self.dx = g["width"], g["height"], g["spacing"]
        self.x0, self.z0 = g["origin_x"], g["origin_z"]
        raw = np.fromfile(f"{root}/tests/fixtures/wind/places/{place}.bin", dtype="<i2", count=self.nx * self.nz)
        self.h = (m["h_offset"] + raw.astype(np.float64) * m["h_scale"]).reshape(self.nz, self.nx)

    def height(self, x, z):
        """Билинейно; вне растра - край."""
        fx = np.clip((np.asarray(x, float) - self.x0) / self.dx, 0, self.nx - 1.001)
        fz = np.clip((np.asarray(z, float) - self.z0) / self.dx, 0, self.nz - 1.001)
        i, j = fx.astype(int), fz.astype(int)
        ax, az = fx - i, fz - j
        h = self.h
        return ((1 - ax) * (1 - az) * h[j, i] + ax * (1 - az) * h[j, i + 1]
                + (1 - ax) * az * h[j + 1, i] + ax * az * h[j + 1, i + 1])

    def inside(self, x, z, margin=0.0):
        return (self.x0 + margin <= x <= self.x0 + (self.nx - 1) * self.dx - margin
                and self.z0 + margin <= z <= self.z0 + (self.nz - 1) * self.dx - margin)


def crest_lines(ter, center, radius, wdir_to, up_len=4000.0, down_len=3000.0, step=25.0, min_gain=120.0, max_gain=1e9, min_drop=60.0,
                n_max=3, min_sep=1500.0, seed=0):
    """Профили вдоль ветра (wdir_to - единичный (ux, uz) куда дует ветер). Для каждой линии, проходящей через
    начальную точку в круге (center, radius), ищется гребень: максимум высоты в интервале профиля [-up_len, down_len]
    от точки; требуются подъём от минимума наветренной части >= min_gain и спад подветренной >= min_drop,
    сам максимум не на краю. Берутся лучшие по подъёму n_max гребней, разнесённые >= min_sep."""
    ux, uz = wdir_to
    s = np.arange(-up_len, down_len + 1, step)
    cands = []
    rng = np.random.default_rng(seed)
    cx, cz = center
    # точки старта - сетка 250 м в круге
    for gx in np.arange(cx - radius, cx + radius + 1, 250.0):
        for gz in np.arange(cz - radius, cz + radius + 1, 250.0):
            if (gx - cx) ** 2 + (gz - cz) ** 2 > radius ** 2:
                continue
            xs, zs = gx + ux * s, gz + uz * s
            if not (ter.inside(xs[0], zs[0], 500) and ter.inside(xs[-1], zs[-1], 500)):
                continue
            hh = ter.height(xs, zs)
            k = int(np.argmax(hh))
            if k < 20 or k > len(s) - 20:
                continue
            gain = hh[k] - hh[:k].min()
            drop = hh[k] - hh[k:].min()
            # гребень должен быть локальным максимумом в окне +-500 м (не просто край склона)
            w = int(500 / step)
            if hh[k] < hh[max(0, k - w):k + w + 1].max() - 1e-9:
                continue
            if min_gain <= gain <= max_gain and drop >= min_drop:
                cands.append((gain, float(xs[k]), float(zs[k]), float(hh[k]), float(drop)))
    cands.sort(reverse=True)
    out = []
    for c in cands:
        if all((c[1] - o[1]) ** 2 + (c[2] - o[2]) ** 2 >= min_sep ** 2 for o in out):
            out.append(c)
        if len(out) >= n_max:
            break
    return [dict(gain=c[0], x=c[1], z=c[2], h=c[3], drop=c[4]) for c in out]
