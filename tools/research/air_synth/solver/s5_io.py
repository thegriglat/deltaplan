"""S5 v2: поля решателя P2 по корпусу (docs/contracts/air-synth.md) — запись/чтение частей, вид VDS, план.
Части part-{k:05d}.h5 (временное имя .tmp -> fsync -> os.replace), общий вид solve.h5 (VDS) детерминированно из частей.
Часть k — случаи плана [k*S, (k+1)*S). Общие помощники (части, fsync) — из corpus_io SY-1."""
from __future__ import annotations

import datetime
import json
import os
import sys
from pathlib import Path

import h5py
import numpy as np

CORPUS_DIR = Path(__file__).resolve().parents[1] / "corpus"
if str(CORPUS_DIR) not in sys.path:
    sys.path.insert(0, str(CORPUS_DIR))
import corpus_io as cio  # noqa: E402

CONTRACT = "S5 v4"
CONTRACT_OK = ("S5 v2", "S5 v4")     # v4 (SY-10): группа game, столбец rank, условия hgw24 (S2 v4)
VIEW = "solve.h5"
AGL_M = (25, 50, 75, 100, 150, 200, 300, 400, 600, 800, 1100, 1500, 2000)
NY = NX = 96
STATUS = {"ok": 0, "max": 1, "diverged": 2}
TARGET = {"final": 0, "late_mean": 1}
CASES_DTYPE = np.dtype([("case", "<i8"), ("relief_id", "<i8"), ("cond_id", "<i4"), ("group", "i1"), ("status_m", "i1"), ("status_h", "i1"),
                        ("iters_m", "<i4"), ("iters_h", "<i4"), ("target_m", "i1"), ("target_h", "i1"), ("late_n_m", "<i2"), ("late_n_h", "<i2"),
                        ("late_spread60_p90_m", "<f4"), ("late_spread60_p90_h", "<f4"), ("seconds", "<f4"), ("rank", "<i4")])
DATASETS = {"fields/m": ((3, 13, NY, NX), "<f2"), "fields/h": ((4, 13, NY, NX), "<f2"), "inputs/hc": ((NY, NX), "<f4"),
            "inputs/heat_flux": ((NY, NX), "<f2"), "inputs/hbl": ((NY, NX), "<f2"), "cases": ((), CASES_DTYPE)}
REQUIRED_ATTRS = ("contract", "kind", "created", "git_commit", "command", "shard_size", "n_records", "complete", "relief_corpus", "conditions",
                  "group_codes", "solver_version", "max_outer", "late_from", "late_step", "agl_m", "dx_m", "x0_m", "y0_m", "device", "workers")


# ------------------------------------------------------------------ план
GROUPS = {"train": 0, "holdout": 1, "game": 2}
GROUP_CODES = "0=train,1=holdout,2=game"


def make_plan(train_ids, holdout_ids, k_cond=12):
    """Явный план S5 v2: [relief_id, cond_id, group] — сначала train (рельеф, затем условие), затем holdout. Детерминирован."""
    return [[int(r), c, g] for g, ids in (("train", train_ids), ("holdout", holdout_ids)) for r in ids for c in range(k_cond)]


def plan_model(first=0, n_train=300, n_holdout=60, k_cond=12):
    """Модельный счёт: id first…first+n_train-1 — train, следующие n_holdout — holdout."""
    ids = list(range(first, first + n_train + n_holdout))
    return make_plan(ids[:n_train], ids[n_train:], k_cond)


def plan_real(place_rows, k_cond=12):
    """Реальные места: place_rows — [(id, part)], part pool -> train, holdout -> holdout (part 'game' не входит)."""
    tr = sorted(i for i, p in place_rows if p == "pool")
    ho = sorted(i for i, p in place_rows if p == "holdout")
    return make_plan(tr, ho, k_cond)


def plan_hg(place_rows, k_cond=24):
    """Места дельтаплана (S5 v4): place_rows — [(id, part)]; очередь holdout, затем train (id по возрастанию); part game -> группа game
    (корпус игры считается отдельным каталогом). rank не используется (−1)."""
    ids = lambda part: sorted(i for i, p in place_rows if p == part)
    return [[int(r), c, g] for g, part in (("game", "game"), ("holdout", "holdout"), ("train", "train")) for r in ids(part) for c in range(k_cond)]


def group_bounds(plan):
    """{group: (первый case, последний case + 1)}."""
    b = {}
    for i, (_, _, g) in enumerate(plan):
        lo, hi = b.get(g, (i, i))
        b[g] = (lo, i + 1)
    return b


def write_plan(d, plan, extra=None):
    p = os.path.join(d, "plan.json")
    tmp = p + ".tmp"
    json.dump(dict(plan=plan, **(extra or {})), open(tmp, "w"))
    os.replace(tmp, p)


def read_plan(d):
    return json.load(open(os.path.join(d, "plan.json")))["plan"]


# ------------------------------------------------------------------ запись
def _check_finite(name, a):
    if not np.all(np.isfinite(a)):
        raise ValueError(f"{name}: есть NaN/inf — ошибка записи")


def write_part(d, k, cases, fields_m, fields_h, hc, heat_flux, hbl, attrs):
    """Часть k: cases (M,) CASES_DTYPE, fields_m (M,3,13,96,96), fields_h (M,4,…), hc (M,96,96), heat_flux, hbl; attrs — атрибуты корня
    (кроме общих). NaN/inf в полях — ValueError. Случаи — по возрастанию `case`. Возвращает размер файла."""
    cases = np.asarray(cases, CASES_DTYPE)
    m = len(cases)
    if m == 0 or np.any(np.diff(cases["case"]) <= 0):
        raise ValueError("write_part: case должны возрастать")
    arrs = {"fields/m": np.asarray(fields_m, "<f2"), "fields/h": np.asarray(fields_h, "<f2"), "inputs/hc": np.asarray(hc, "<f4"),
            "inputs/heat_flux": np.asarray(heat_flux, "<f2"), "inputs/hbl": np.asarray(hbl, "<f2")}
    for n, a in arrs.items():
        if a.shape != (m,) + DATASETS[n][0]:
            raise ValueError(f"{n}: форма {a.shape}, ожидается {(m,) + DATASETS[n][0]}")
        _check_finite(n, a)
    os.makedirs(d, exist_ok=True)
    path = cio.part_path(d, k)
    tmp = path + ".tmp"
    with h5py.File(tmp, "w") as f:
        f.attrs["contract"], f.attrs["kind"] = CONTRACT, "solve"
        f.attrs["created"] = datetime.datetime.now().isoformat(timespec="seconds")
        f.attrs["git_commit"] = f.attrs["command"] = ""
        for key, v in attrs.items():
            f.attrs[key] = v
        f.attrs["n_records"], f.attrs["complete"] = m, True
        f.attrs["group_codes"] = GROUP_CODES
        for n, a in arrs.items():
            f.create_dataset(n, data=a, track_times=False, chunks=(1,) + a.shape[1:], compression="gzip", compression_opts=4, shuffle=True)
        f.create_dataset("cases", data=cases, track_times=False, compression="gzip", compression_opts=4, shuffle=True)
        f["fields/m"].attrs["channels"] = "u,v,w"
        f["fields/h"].attrs["channels"] = "u,v,w,theta_prime"
        f["fields/m"].attrs["axes"] = f["fields/h"].attrs["axes"] = "case, channel, agl, j (north), i (east)"
    cio._replace_fsync(tmp, path)
    return os.path.getsize(path)


def build_view(d, n_total=None):
    """Вид solve.h5 (VDS по частям), детерминированно; complete = части 0..K-1 подряд и суммарно n_total случаев."""
    parts = cio.list_parts(d)
    if not parts:
        raise FileNotFoundError(f"нет частей в {d}")
    counts, root = [], None
    for k in parts:
        with h5py.File(cio.part_path(d, k), "r") as f:
            if f.attrs["contract"] not in CONTRACT_OK:
                raise ValueError(f"{cio.part_path(d, k)}: контракт {f.attrs['contract']!r}")
            root = root or dict(f.attrs)
            counts.append(int(f["cases"].shape[0]))
    total = sum(counts)
    if n_total is None:
        try:
            n_total = len(read_plan(d))
        except FileNotFoundError:
            n_total = None
    complete = bool(n_total is not None and total == n_total and parts == list(range(len(parts))))
    path = os.path.join(d, VIEW)
    tmp = path + ".tmp"
    with h5py.File(tmp, "w") as f:
        for key, v in root.items():
            f.attrs[key] = v
        f.attrs["n_records"], f.attrs["complete"] = total, complete
        for name, (tail, dt) in sorted(DATASETS.items()):
            lay = h5py.VirtualLayout(shape=(total,) + tail, dtype=np.dtype(dt))
            pos = 0
            for k, c in zip(parts, counts):
                lay[pos:pos + c] = h5py.VirtualSource(os.path.basename(cio.part_path(d, k)), name, shape=(c,) + tail)
                pos += c
            ds = f.create_virtual_dataset(name, lay)
            if name.startswith("fields/"):
                ds.attrs["channels"] = "u,v,w" if name == "fields/m" else "u,v,w,theta_prime"
    cio._replace_fsync(tmp, path)
    return dict(n_records=total, complete=complete, parts=len(parts))


# ------------------------------------------------------------------ чтение
class Solve:
    """Чтение S5: каталог с solve.h5 (вид) или только частями. Отказывает при неизвестном contract."""

    def __init__(self, path):
        self.path = str(path)
        view = os.path.join(self.path, VIEW)
        self._files = []
        if os.path.exists(view):
            files = [view]
        else:
            files = [cio.part_path(self.path, k) for k in cio.list_parts(self.path)]
        if not files:
            raise FileNotFoundError(f"нет solve.h5 и частей в {self.path}")
        self._off = [0]
        for p in files:
            f = h5py.File(p, "r")
            if f.attrs.get("contract") not in CONTRACT_OK or f.attrs.get("kind") != "solve":
                got = f.attrs.get("contract")
                f.close()
                raise ValueError(f"контракт {got!r}, ожидается {CONTRACT!r}")
            self._files.append(f)
            self._off.append(self._off[-1] + int(f["cases"].shape[0]))
        self.attrs = dict(self._files[0].attrs)
        self.cases = np.concatenate([f["cases"][:] for f in self._files])

    def __len__(self):
        return len(self.cases)

    def _loc(self, i):
        j = int(np.searchsorted(self._off, i, side="right")) - 1
        return self._files[j], i - self._off[j]

    def get(self, name, i):
        f, r = self._loc(i)
        return f[name][r]

    def close(self):
        for f in self._files:
            f.close()
        self._files = []


# ------------------------------------------------------------------ погода hgw24 (S2 v4): подмена конфига Day, код air3d не правится
HG_SKY = "hgw"         # ключ облачности в подменённом конфиге (cover непрерывно, heat = 1 − 0,75·cover)
HG_COLUMNS = ("dt_surface_k", "dt_upper_k", "lapse_k_per_km", "inv_depth_m", "inv_range_k", "cloud_cover")
_MONTHLY = (("typical_max_c",), ("dew_point_c",), ("upper_air", "temp_c"), ("diurnal", "range_k"))


def _air3d_weather():
    p = str(Path(__file__).resolve().parents[3] / "air3d")
    if p not in sys.path:
        sys.path.insert(0, p)
    import weather as W
    return W


def weather_cfg(base, lat, dt_upper_k, lapse_k_per_km, inv_depth_f, inv_range_f, cloud_cover):
    """Копия конфига погоды (weather_model.json) с возмущениями дня hgw24 (S2 v4): t_u (верхний уровень) += dt_upper, градиент
    свободной атмосферы gam = lapse, глубина приземной инверсии и суточная амплитуда range_k — множители, облачность — своя запись
    sky[HG_SKY] (cover, heat = 1 − 0,75·cover; её читают weather.Day и wind_prof.for_hour). dt_surface — сдвиг t_max (в столбце t_max_c).
    Южное полушарие: месячные таблицы (северные) сдвигаются на 6 месяцев, чтобы дата (месяц + 6) давала тот же сезон."""
    import copy
    cfg = copy.deepcopy(base)
    if lat < 0:
        for path in _MONTHLY:
            d = cfg
            for k in path[:-1]:
                d = d[k]
            a = list(d[path[-1]])
            d[path[-1]] = a[6:] + a[:6]
    ua = cfg["upper_air"]
    lat_shift = -0.5 * (abs(float(lat)) - 50.0)    # S2 v4 (уточнение по ревью): климатология t_u — тот же широтный сдвиг, что у t_max
    ua["temp_c"] = [float(t) + float(dt_upper_k) + lat_shift for t in ua["temp_c"]]
    ua["lapse_k_per_km"] = float(lapse_k_per_km)
    dn = cfg["diurnal"]
    dn["inversion_depth_m"] = float(dn["inversion_depth_m"]) * float(inv_depth_f)
    dn["range_k"] = [float(r) * float(inv_range_f) for r in dn["range_k"]]
    cc = float(cloud_cover)
    cfg["sky"][HG_SKY] = dict(cover=cc, heat=1.0 - 0.75 * cc, soft=min(cc / 0.85, 1.0), duty_k=1.0, cb_k=1.0)
    return cfg


class weather_override:
    """with weather_override(cfg): ... — подменяет weather.CFG (и возвращает прежний). cfg None — ничего не делает (побитно как раньше)."""

    def __init__(self, cfg):
        self.cfg, self.W, self.old = cfg, None, None

    def __enter__(self):
        if self.cfg is not None:
            self.W = _air3d_weather()
            self.old, self.W.CFG = self.W.CFG, self.cfg
        return self

    def __exit__(self, *a):
        if self.W is not None:
            self.W.CFG = self.old


def cfg_from_row(row):
    """Подменённый конфиг по строке условий S2 v4 (dict/структурная запись) или None, если столбцов hgw24 нет (v2/v3 — как раньше)."""
    names = row.dtype.names if hasattr(row, "dtype") and row.dtype.names else tuple(row)
    if "dt_upper_k" not in names:
        return None
    W = _air3d_weather()
    g = lambda k: float(row[k])
    return weather_cfg(W.CFG, g("lat_deg"), g("dt_upper_k"), g("lapse_k_per_km"), g("inv_depth_m"), g("inv_range_k"), g("cloud_cover"))
