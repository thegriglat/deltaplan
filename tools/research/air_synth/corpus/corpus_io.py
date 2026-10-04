"""Формат корпуса air-synth в HDF5 (контракты S1 v3 рельеф, S2 v2 условия — docs/contracts/air-synth.md).
Части part-{k:05d}.h5 (пишет один процесс: временное имя .tmp -> fsync -> os.replace) + общий вид corpus.h5 /
conditions.h5 из виртуальных наборов (VDS), собираемый детерминированно из частей."""
import datetime
import glob
import json
import os
import re
import numpy as np
import h5py

CONTRACT = {"relief": "S1 v3", "conditions": "S2 v2"}
VIEW_NAME = {"relief": "corpus.h5", "conditions": "conditions.h5"}
NG100, DX100, X0 = 384, 100.0, -19200.0
NG400, DX400 = 96, 400.0
OFFSET_M, SCALE_M = 2500.0, 0.15
SKY_CODES = "0=clear,1=partly,2=overcast"

SUMMARY_DTYPE = np.dtype([("id", "<i8")] + [(n, "<f8") for n in
                          ("h_min_m", "h_max_m", "relief_m", "slope_mean_deg_400", "slope_p95_deg_100", "compute_seconds")])
PLACE_DTYPE = np.dtype([("id", "<i8"), ("name", "S16"), ("lat_deg", "<f8"), ("lon_deg", "<f8"), ("system", "S32"), ("part", "S8"),
                        ("stratum", "S32"), ("source", "S32"), ("zoom", "<i4"), ("src_spacing_m", "<f8"), ("source_sha256", "S64")])
_F8 = ("u10_m_s wind_from_deg hour_local t_max_c lat_deg lon_deg utc_offset_h alpha max_profile z_i_m z_lcl_m heat brk cap_agl_m "
       "sun_el_deg sun_az_deg t_c n_bv_s froude w_star_m_s w_star_over_u hs_w_m2 u_sat_m_s").split()
CONDITIONS_DTYPE = np.dtype([("relief_id", "<i8"), ("cond_id", "<i4")] +
                            [(n, "<f8") for n in _F8[:7]] + [("sky", "i1"), ("month", "i1"), ("day", "i1")] +
                            [(n, "<f8") for n in _F8[7:]] + [("stability_class", "i1"), ("has_cap", "?"), ("mechanical", "?"),
                                                              ("strat_override", "?"), ("n_bv_override_s", "<f8"), ("z_i_override_agl_m", "<f8")])


def data_root():
    return os.environ.get("AIR_SYNTH_DATA", os.path.expanduser("~/air_synth_data"))


# ------------------------------------------------------------------ высоты
def quantize(h):
    """float (…, ny, nx) -> int16 по контракту: q = round((h − 2500)/0,15); вне диапазона int16 или не конечно — ValueError."""
    h = np.asarray(h, dtype=np.float64)
    if not np.all(np.isfinite(h)):
        raise ValueError("высоты не конечны")
    q = np.rint((h - OFFSET_M) / SCALE_M)
    if q.min() < -32768 or q.max() > 32767:
        raise ValueError(f"высоты вне диапазона int16: {h.min():.1f}…{h.max():.1f} м (допустимо {OFFSET_M - 32768 * SCALE_M:.0f}…{OFFSET_M + 32767 * SCALE_M:.0f})")
    return q.astype("<i2")


def to_float(q, dtype=np.float32):
    """int16 -> метры над морем (float32 по умолчанию; float64 — без потери)."""
    return (OFFSET_M + SCALE_M * np.asarray(q).astype(np.float64)).astype(dtype)


def block_mean(z, f=4):
    ny, nx = z.shape[-2:]
    return z.reshape(*z.shape[:-2], ny // f, f, nx // f, f).mean(axis=(-3, -1))


def slopes_deg(z, dx):
    gy, gx = np.gradient(z, dx)
    return np.degrees(np.arctan(np.hypot(gx, gy)))[1:-1, 1:-1]


def encode_relief(rid, z100, compute_seconds=0.0):
    """z100 float64 (384, 384) -> (q100, q400, строка summary). h400 — блочное среднее до квантования."""
    z100 = np.asarray(z100, dtype=np.float64)
    if z100.shape != (NG100, NG100):
        raise ValueError(f"z100 должен быть {NG100}x{NG100}, а не {z100.shape}")
    z400 = block_mean(z100, 4)
    q100, q400 = quantize(z100), quantize(z400)
    s = np.zeros((), SUMMARY_DTYPE)
    s["id"] = rid
    s["h_min_m"], s["h_max_m"] = z400.min(), z400.max()
    s["relief_m"] = z400.max() - z400.min()
    s["slope_mean_deg_400"] = slopes_deg(z400, DX400).mean()
    s["slope_p95_deg_100"] = np.percentile(slopes_deg(z100, DX100), 95)
    s["compute_seconds"] = compute_seconds
    return q100, q400, s


# ------------------------------------------------------------------ запись
def part_path(d, k):
    return os.path.join(d, f"part-{k:05d}.h5")


def list_parts(d):
    out = []
    for p in glob.glob(os.path.join(d, "part-*.h5")):
        m = re.fullmatch(r"part-(\d{5})\.h5", os.path.basename(p))
        if m:
            out.append(int(m.group(1)))
    return sorted(out)


def _replace_fsync(tmp, path):
    fd = os.open(tmp, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
    os.replace(tmp, path)


def _root_attrs(f, kind, attrs, n):
    f.attrs["contract"] = CONTRACT[kind]
    f.attrs["kind"] = kind
    f.attrs["created"] = datetime.datetime.now().isoformat(timespec="seconds")
    for k in ("git_commit", "command"):
        f.attrs[k] = ""
    for k, v in attrs.items():
        f.attrs[k] = v
    f.attrs["n_records"] = n
    f.attrs["complete"] = True


def _ds(g, name, data, **kw):
    return g.create_dataset(name, data=data, track_times=False, **kw)


def write_part(d, k, ids, q100, q400, summary, params=None, place=None, attrs=None, columns=None):
    """Часть рельефов k: ids (N,) int64, q100 (N,384,384) int16, q400, summary (N,) SUMMARY_DTYPE;
    params (N,) структурный (gen/params, columns — имена столбцов) или place (N,) PLACE_DTYPE."""
    os.makedirs(d, exist_ok=True)
    ids = np.asarray(ids, "<i8")
    n = len(ids)
    if not (np.all(np.diff(ids) > 0) and q100.shape == (n, NG100, NG100) and q400.shape == (n, NG400, NG400) and len(summary) == n):
        raise ValueError("write_part: ids должны возрастать, формы — по контракту")
    path = part_path(d, k)
    tmp = path + ".tmp"
    with h5py.File(tmp, "w") as f:
        _root_attrs(f, "relief", attrs or {}, n)
        _ds(f, "relief/id", ids)
        for name, q, dx in (("relief/h100", q100, DX100), ("relief/h400", q400, DX400)):
            ds = _ds(f, name, q, chunks=(1,) + q.shape[1:], compression="gzip", compression_opts=4, shuffle=True)
            ds.attrs.update(offset_m=OFFSET_M, scale_m=SCALE_M, dx_m=dx, x0_m=X0, y0_m=X0, units="m above sea level",
                            axes="record, j (north), i (east)")
        _ds(f, "summary", np.asarray(summary, SUMMARY_DTYPE), compression="gzip", compression_opts=4, shuffle=True)
        if params is not None:
            ds = _ds(f, "gen/params", params)
            ds.attrs["columns"] = json.dumps(list(columns or params.dtype.names))
        if place is not None:
            _ds(f, "place", np.asarray(place, PLACE_DTYPE))
    _replace_fsync(tmp, path)
    return os.path.getsize(path)


def write_conditions_part(d, k, table, attrs=None):
    """Часть условий k: table (M,) CONDITIONS_DTYPE по (relief_id, cond_id)."""
    os.makedirs(d, exist_ok=True)
    table = np.asarray(table, CONDITIONS_DTYPE)
    key = list(zip(table["relief_id"], table["cond_id"]))
    if key != sorted(key):
        raise ValueError("строки условий должны идти по (relief_id, cond_id)")
    path = part_path(d, k)
    tmp = path + ".tmp"
    with h5py.File(tmp, "w") as f:
        _root_attrs(f, "conditions", attrs or {}, len(table))
        ds = _ds(f, "conditions/table", table, compression="gzip", compression_opts=4, shuffle=True)
        ds.attrs["sky_codes"] = SKY_CODES
    _replace_fsync(tmp, path)
    return os.path.getsize(path)


def clean_tmp(d):
    for p in glob.glob(os.path.join(d, "*.tmp")):
        os.remove(p)


def write_manifest(d, extra):
    """manifest.json — копия атрибутов (для людей), атомарно."""
    p = os.path.join(d, "manifest.json")
    tmp = p + ".tmp"
    json.dump(extra, open(tmp, "w"), indent=1, sort_keys=True, ensure_ascii=False, default=str)
    os.replace(tmp, p)


def read_manifest(d):
    p = os.path.join(d, "manifest.json")
    return json.load(open(p)) if os.path.exists(p) else None


def build_view(d, kind=None):
    """Пересборка общего вида (VDS) из частей — детерминированно (побитно тот же файл при тех же частях).
    complete = True, если части покрывают n_total из manifest.json (или контигуозны от 0 и последняя неполная/полная — без manifest нельзя)."""
    parts = list_parts(d)
    if not parts:
        raise FileNotFoundError(f"нет частей в {d}")
    with h5py.File(part_path(d, parts[0]), "r") as f0:
        kind = kind or f0.attrs["kind"]
        root = dict(f0.attrs)
        dsets = []
        f0.visititems(lambda n, o: dsets.append((n, o.dtype, o.shape[1:], dict(o.attrs))) if isinstance(o, h5py.Dataset) else None)
    counts = []
    for k in parts:
        with h5py.File(part_path(d, k), "r") as f:
            counts.append(int(f["relief/id" if kind == "relief" else "conditions/table"].shape[0]))
            if f.attrs["contract"] != CONTRACT[kind]:
                raise ValueError(f"{part_path(d, k)}: контракт {f.attrs['contract']!r}")
    total = sum(counts)
    man = read_manifest(d) or {}
    shard_size = int(root.get("shard_size", 0))
    nt = man.get("n_total")
    complete = bool(nt is not None and total == nt and parts == list(range(len(parts))))
    path = os.path.join(d, VIEW_NAME[kind])
    tmp = path + ".tmp"
    with h5py.File(tmp, "w") as f:
        for k_, v in root.items():
            f.attrs[k_] = v
        f.attrs["n_records"] = total
        f.attrs["complete"] = complete
        for name, dt, tail, at in sorted(dsets, key=lambda x: x[0]):
            lay = h5py.VirtualLayout(shape=(total,) + tail, dtype=dt)
            pos = 0
            for k, c in zip(parts, counts):
                lay[pos:pos + c] = h5py.VirtualSource(os.path.basename(part_path(d, k)), name, shape=(c,) + tail)
                pos += c
            ds = f.create_virtual_dataset(name, lay)
            for ak, av in at.items():
                ds.attrs[ak] = av
    _replace_fsync(tmp, path)
    if man:
        man.update(parts=parts, n_records=total, complete=complete)
        write_manifest(d, man)
    return dict(kind=kind, n_records=total, complete=complete, parts=len(parts))


# ------------------------------------------------------------------ чтение
def _check_contract(f, kind):
    c = f.attrs.get("contract")
    if c != CONTRACT[kind] or f.attrs.get("kind") != kind:
        raise ValueError(f"контракт {c!r} (kind {f.attrs.get('kind')!r}), ожидается {CONTRACT[kind]!r}")


def _dec(row, dt):
    out = {}
    for n in dt.names:
        v = row[n]
        out[n] = v.decode() if isinstance(v, bytes) else (v.item() if hasattr(v, "item") else v)
    return out


class Corpus:
    """Корпус рельефов S1: каталог с corpus.h5 (вид) или только частями (тогда читается по частям, как есть)."""

    def __init__(self, path):
        self.path = path
        self._files = {}
        view = os.path.join(path, VIEW_NAME["relief"])
        if os.path.exists(view):
            self._view = self._f(view)
            _check_contract(self._view, "relief")
            self.attrs = dict(self._view.attrs)
            self._ids = self._view["relief/id"][:]
            self._src = None
        else:
            parts = list_parts(path)
            if not parts:
                raise FileNotFoundError(f"нет corpus.h5 и частей в {path}")
            self._view = None
            ids, src = [], []
            for k in parts:
                f = self._f(part_path(path, k))
                _check_contract(f, "relief")
                i = f["relief/id"][:]
                ids.append(i)
                src += [(f, j) for j in range(len(i))]
            self.attrs = dict(self._f(part_path(path, parts[0])).attrs)
            self._ids = np.concatenate(ids)
            self._src = src
        self.contract = self.attrs["contract"]
        cp = self.attrs.get("clipped_places", "")
        cp = cp.decode() if isinstance(cp, bytes) else str(cp)
        self.clipped_places = [x for x in cp.split(",") if x]     # реальные места с обрезанными узлами (S1 v3), иначе []

    def _f(self, p):
        if p not in self._files:
            self._files[p] = h5py.File(p, "r")
        return self._files[p]

    def close(self):
        for f in self._files.values():
            f.close()
        self._files = {}

    def __len__(self):
        return len(self._ids)

    def ids(self):
        return self._ids.tolist()

    def _row(self, rid):
        i = int(np.searchsorted(self._ids, rid))
        if i >= len(self._ids) or self._ids[i] != rid:
            raise KeyError(rid)
        return i

    def _get(self, name, rid):
        i = self._row(rid)
        if self._view is not None:
            return self._view[name][i]
        f, j = self._src[i]
        return f[name][j]

    def _has(self, name):
        f = self._view if self._view is not None else self._src[0][0]
        return name in f

    def h100(self, rid, dtype=np.float32):
        """Высоты 100 м, (384, 384) [j — север, i — восток], м над морем."""
        return to_float(self._get("relief/h100", rid), dtype)

    def h400(self, rid, dtype=np.float32):
        return to_float(self._get("relief/h400", rid), dtype)

    def summary(self, rid):
        return _dec(self._get("summary", rid), SUMMARY_DTYPE)

    def params(self, rid):
        """Параметры генерации (только модельные): dict столбец -> значение."""
        if not self._has("gen/params"):
            raise KeyError("нет gen/params (реальный корпус)")
        r = self._get("gen/params", rid)
        return _dec(r, r.dtype)

    def place(self, rid):
        if not self._has("place"):
            raise KeyError("нет place (модельный корпус)")
        return _dec(self._get("place", rid), PLACE_DTYPE)

    def __iter__(self):
        """Итерация по рельефам: dict (id, h100, h400 float32, summary, params|place)."""
        for rid in self._ids.tolist():
            d = dict(id=rid, h100=self.h100(rid), h400=self.h400(rid), summary=self.summary(rid))
            if self._has("gen/params"):
                d["params"] = self.params(rid)
            if self._has("place"):
                d["place"] = self.place(rid)
            yield d

    def iter_batches(self, size=100):
        """Пачки: (ids, h100 float32 (b,384,384), h400 (b,96,96))."""
        for s in range(0, len(self._ids), size):
            ids = self._ids[s:s + size]
            if self._view is not None:
                q1, q4 = self._view["relief/h100"][s:s + size], self._view["relief/h400"][s:s + size]
            else:
                q1 = np.stack([self._src[i][0]["relief/h100"][self._src[i][1]] for i in range(s, s + len(ids))])
                q4 = np.stack([self._src[i][0]["relief/h400"][self._src[i][1]] for i in range(s, s + len(ids))])
            yield ids, to_float(q1), to_float(q4)


class Conditions:
    """Набор условий S2: таблица (структурный массив numpy), выборка по relief_id, проверка ссылок."""

    def __init__(self, path):
        self.path = path
        view = os.path.join(path, VIEW_NAME["conditions"])
        files = [view] if os.path.exists(view) else [part_path(path, k) for k in list_parts(path)]
        if not files:
            raise FileNotFoundError(f"нет conditions.h5 и частей в {path}")
        tabs = []
        for p in files:
            with h5py.File(p, "r") as f:
                _check_contract(f, "conditions")
                self.attrs = dict(f.attrs)
                tabs.append(f["conditions/table"][:])
        self.table = np.concatenate(tabs)

    def __len__(self):
        return len(self.table)

    def for_relief(self, rid):
        return self.table[self.table["relief_id"] == rid]

    def validate_refs(self):
        rc = self.attrs.get("relief_corpus", "")
        if not rc:
            raise ValueError("атрибут relief_corpus пуст")
        c = Corpus(rc)
        missing = sorted(set(self.table["relief_id"].tolist()) - set(c.ids()))
        c.close()
        if missing:
            raise ValueError(f"relief_id нет в корпусе {rc}: {missing[:10]}")
        return True


def write_reliefs(out, reliefs, shard_size=100, generator_version="", corpus_seed=0, command="", git_commit="", theta_cloud="", columns=None):
    """Готовые рельефы -> корпус (части + вид + manifest.json). reliefs — список dict(z100 float64 (384,384), compute_seconds?,
    place=dict по PLACE_DTYPE (реальные) или params=dict (модельные)); id — порядковый номер 0…n−1."""
    reliefs = list(reliefs)
    os.makedirs(out, exist_ok=True)
    clean_tmp(out)
    attrs = dict(shard_size=shard_size, n_total=len(reliefs), generator_version=generator_version, corpus_seed=np.uint64(corpus_seed),
                 theta_cloud=theta_cloud, command=command, git_commit=git_commit)
    write_manifest(out, dict(attrs, contract=CONTRACT["relief"], kind="relief", n_total=len(reliefs), corpus_seed=int(corpus_seed)))
    for k in range((len(reliefs) + shard_size - 1) // shard_size):
        chunk = reliefs[k * shard_size:(k + 1) * shard_size]
        ids = list(range(k * shard_size, k * shard_size + len(chunk)))
        enc = [encode_relief(i, r["z100"], r.get("compute_seconds", 0.0)) for i, r in zip(ids, chunk)]
        kw = {}
        if "place" in chunk[0]:
            pl = np.zeros(len(chunk), PLACE_DTYPE)
            for j, (i, r) in enumerate(zip(ids, chunk)):
                pl[j]["id"] = i
                for n, v in r["place"].items():
                    pl[j][n] = v.encode() if isinstance(v, str) else v
            kw["place"] = pl
        else:
            names = columns or list(chunk[0]["params"])
            dt = np.dtype([("id", "<i8"), ("corpus_seed", "<u8"), ("cloud_point", "<i4")] + [(n, "<f8") for n in names])
            pa = np.zeros(len(chunk), dt)
            for j, (i, r) in enumerate(zip(ids, chunk)):
                pa[j]["id"], pa[j]["corpus_seed"], pa[j]["cloud_point"] = i, corpus_seed, r.get("cloud_point", -1)
                for n in names:
                    pa[j][n] = r["params"][n]
            kw["params"], kw["columns"] = pa, names
        write_part(out, k, ids, np.stack([e[0] for e in enc]), np.stack([e[1] for e in enc]), np.array([e[2] for e in enc]), attrs=attrs, **kw)
    return build_view(out, "relief")
