"""Чтение/запись/проверка форматов F1, F2, M1 модуля cascade-2d (docs/contracts/cascade-2d.md)."""
import datetime
import json
import math
import os
import numpy as np

LEVELS_DX = (400, 200, 100, 50, 25)
CASES = ("C0", "C1", "C2", "C3", "C4")
SOURCES = ("picard", "cascade", "baseline")
VARIANTS = ("V0", "V1", "V2", "V3", "V3h", "B400", "B200", "B100", "B50")
X_MIN, X_LEN = -6400.0, 12800.0
ARRAY_ORDER = ("u", "w", "th", "cell", "tu", "tw", "h")

F1_KEYS = ("format", "version", "case", "source", "variant", "dx", "dz", "nx", "nz", "x0", "z0",
           "parent_dx", "seed", "arrays", "git", "created")
F2_KEYS = ("format", "version", "case", "source", "variant", "dx", "parent_dx", "seed", "threads", "ny",
           "status", "iters", "time", "memory", "balance", "y_uniform", "query", "field", "cmd", "host",
           "git", "notes")
M1_KEYS = ("format", "version", "case", "ref", "U_ref", "E_ref", "rows")
M1_ROW_KEYS = ("field", "source", "variant", "dx", "parent_dx", "seed", "E_u", "E_w", "E_u_lee", "dS",
               "r_w", "L_rec", "L_rec_ref", "w_max", "w_max_ref", "F_up", "F_up_ref", "max_rel_div",
               "max_speed", "sigma_u", "sigma_w")


class ContractError(Exception):
    pass


def data_dir():
    return os.path.expanduser(os.environ.get("CASCADE2D_DATA", "~/data/cascade_2d"))


def array_shapes(nx, nz):
    return {"u": (nz, nx + 1), "w": (nz + 1, nx), "th": (nz, nx), "cell": (nz, nx),
            "tu": (nz, nx + 1), "tw": (nz + 1, nx), "h": (nx,)}


def _isnum(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def _isint(v):
    return isinstance(v, int) and not isinstance(v, bool)


def _num_or_null(v):
    return v is None or _isnum(v)


def _bin_path(json_path):
    return os.path.splitext(json_path)[0] + ".bin"


# ---------------- F1 ----------------

def _check_keys(d, keys, what):
    if not isinstance(d, dict):
        raise ContractError(f"{what}: не объект")
    miss = [k for k in keys if k not in d]
    if miss:
        raise ContractError(f"{what}: нет ключей {miss}")


def validate_f1_meta(m):
    _check_keys(m, F1_KEYS, "F1")
    if m["format"] != "cascade2d-field":
        raise ContractError(f"F1: format={m['format']!r}")
    if m["version"] != 1:
        raise ContractError(f"F1: version={m['version']!r}")
    if m["case"] not in CASES:
        raise ContractError(f"F1: case={m['case']!r}")
    src, var = m["source"], m["variant"]
    if src not in SOURCES:
        raise ContractError(f"F1: source={src!r}")
    if src == "picard" and var is not None:
        raise ContractError("F1: у picard variant должен быть null")
    if src == "cascade" and var not in ("V0", "V1", "V2", "V3", "V3h"):
        raise ContractError(f"F1: variant={var!r} для cascade")
    if src == "baseline" and var not in ("B400", "B200", "B100", "B50"):
        raise ContractError(f"F1: variant={var!r} для baseline")
    for k in ("dx", "nx", "nz"):
        if not _isint(m[k]):
            raise ContractError(f"F1: {k} не целое")
    if m["dx"] not in LEVELS_DX:
        raise ContractError(f"F1: dx={m['dx']} вне {LEVELS_DX}")
    if not _isnum(m["dz"]) or abs(m["dz"] - m["dx"] / 4) > 1e-9:
        raise ContractError(f"F1: dz={m['dz']} != dx/4")
    if m["nx"] != int(X_LEN // m["dx"]):
        raise ContractError(f"F1: nx={m['nx']} != {int(X_LEN // m['dx'])}")
    if m["nz"] < 1:
        raise ContractError("F1: nz < 1")
    if not _isnum(m["x0"]) or abs(m["x0"] - X_MIN) > 1e-9:
        raise ContractError(f"F1: x0={m['x0']!r} != {X_MIN}")
    if not _isnum(m["z0"]):
        raise ContractError("F1: z0 не число")
    if abs(m["z0"] + m["dz"]) > 1e-9:
        raise ContractError(f"F1: z0={m['z0']} != -dz")
    if not (m["parent_dx"] is None or m["parent_dx"] in LEVELS_DX):
        raise ContractError(f"F1: parent_dx={m['parent_dx']!r}")
    if src == "picard" and m["parent_dx"] is not None:
        raise ContractError("F1: у picard parent_dx должен быть null")
    if not (m["seed"] is None or _isint(m["seed"])):
        raise ContractError("F1: seed не целое/null")
    if (var == "V3h") != (m["seed"] is not None):
        raise ContractError("F1: seed — int у V3h, иначе null")
    if not isinstance(m["git"], (str, type(None))):
        raise ContractError("F1: git не строка")
    if not isinstance(m["created"], str):
        raise ContractError("F1: created не строка")
    try:
        datetime.datetime.fromisoformat(m["created"].replace("Z", "+00:00"))
    except ValueError:
        raise ContractError(f"F1: created={m['created']!r} не ISO")
    arr = m["arrays"]
    if not isinstance(arr, dict):
        raise ContractError("F1: arrays не объект")
    shapes = array_shapes(m["nx"], m["nz"])
    for name, shp in shapes.items():
        if name not in arr:
            raise ContractError(f"F1: нет массива {name}")
        ent = arr[name]
        if (not isinstance(ent, list) or len(ent) != 2 or not all(_isint(e) for e in ent)
                or ent[0] < 0):
            raise ContractError(f"F1: arrays.{name} не [смещение, длина]")
        n = int(np.prod(shp))
        if ent[1] != n:
            raise ContractError(f"F1: arrays.{name} длина {ent[1]} != {n} {shp}")
    return shapes


def read_f1(path):
    """-> (meta, {имя: ndarray float32 формы по F1}). Проверяет всё, кроме физики (см. check_f1_arrays)."""
    path = str(path)
    with open(path) as f:
        meta = json.load(f)
    shapes = validate_f1_meta(meta)
    bp = _bin_path(path)
    if not os.path.exists(bp):
        raise ContractError(f"F1: нет {bp}")
    size = os.path.getsize(bp)
    if size % 4:
        raise ContractError(f"F1: размер .bin {size} не кратен 4")
    data = np.fromfile(bp, dtype="<f4")
    out = {}
    for name, shp in shapes.items():
        off, n = meta["arrays"][name]
        if off + n > data.size:
            raise ContractError(f"F1: arrays.{name} [{off}+{n}] выходит за .bin ({data.size} float32)")
        out[name] = data[off:off + n].reshape(shp).copy()
    return meta, out


def check_f1_arrays(meta, arrays):
    """Физические инварианты: конечность, 0 на стенках, cell 0/1."""
    for name, a in arrays.items():
        if not np.all(np.isfinite(a)):
            raise ContractError(f"F1: {name} содержит NaN/Inf")
    if not np.all((arrays["cell"] == 0) | (arrays["cell"] == 1)):
        raise ContractError("F1: cell не 0/1")
    for v, t in (("u", "tu"), ("w", "tw")):
        if np.any(arrays[v][arrays[t] == 0] != 0):
            raise ContractError(f"F1: {v} != 0 на гранях {t}=0")


def write_f1(path, meta, arrays):
    """Пишет .bin и .json через временные файлы и переименование (json последним).
    meta без `arrays` дополняется смещениями; `format`, `version`, `created` — по умолчанию."""
    path = str(path)
    meta = dict(meta)
    meta.setdefault("format", "cascade2d-field")
    meta.setdefault("version", 1)
    meta.setdefault("created", datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"))
    shapes = array_shapes(meta["nx"], meta["nz"])
    offs, chunks, pos = {}, [], 0
    for name in ARRAY_ORDER:
        a = np.asarray(arrays[name], dtype="<f4")
        if a.shape != shapes[name]:
            raise ContractError(f"write_f1: {name} форма {a.shape} != {shapes[name]}")
        offs[name] = [pos, a.size]
        pos += a.size
        chunks.append(a.ravel())
    meta["arrays"] = offs
    validate_f1_meta(meta)
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    bp = _bin_path(path)
    tb, tj = bp + ".tmp", path + ".tmp"
    np.concatenate(chunks).astype("<f4").tofile(tb)
    os.replace(tb, bp)
    with open(tj, "w") as f:
        json.dump(meta, f, ensure_ascii=False, indent=1)
    os.replace(tj, path)


# ---------------- баланс ----------------

def div2d(meta, arrays):
    """Дивергенция клеток (nz, nx) по F1: (u[k,i+1]-u[k,i])/dx + (w[k+1,i]-w[k,i])/dz;
    в клетках земли (cell=0) — 0."""
    u = arrays["u"].astype(np.float64)
    w = arrays["w"].astype(np.float64)
    d = (u[:, 1:] - u[:, :-1]) / meta["dx"] + (w[1:, :] - w[:-1, :]) / meta["dz"]
    return np.where(arrays["cell"] > 0.5, d, 0.0)


def rel_div(div, dx, U_ref):
    """|div|·dx/U_ref."""
    return np.abs(div) * dx / U_ref


# ---------------- F2 ----------------

def validate_f2(r):
    _check_keys(r, F2_KEYS, "F2")
    if r["format"] != "cascade2d-run":
        raise ContractError(f"F2: format={r['format']!r}")
    if r["version"] != 1:
        raise ContractError(f"F2: version={r['version']!r}")
    if r["case"] not in CASES:
        raise ContractError(f"F2: case={r['case']!r}")
    if r["source"] not in ("picard", "cascade"):
        raise ContractError(f"F2: source={r['source']!r}")
    if r["source"] == "picard" and r["variant"] is not None:
        raise ContractError("F2: у picard variant null")
    if r["source"] == "cascade" and r["variant"] not in ("V0", "V1", "V2", "V3", "V3h"):
        raise ContractError(f"F2: variant={r['variant']!r}")
    if r["dx"] not in LEVELS_DX:
        raise ContractError(f"F2: dx={r['dx']!r}")
    if not (r["parent_dx"] is None or r["parent_dx"] in LEVELS_DX):
        raise ContractError("F2: parent_dx")
    if not (r["seed"] is None or _isint(r["seed"])):
        raise ContractError("F2: seed")
    if not _isint(r["threads"]) or r["threads"] < 1:
        raise ContractError("F2: threads")
    if not _isint(r["ny"]) or r["ny"] < 1:
        raise ContractError("F2: ny")
    if r["source"] == "picard" and r["ny"] < 4:
        raise ContractError("F2: у picard ny >= 4")
    if r["source"] == "cascade" and r["ny"] != 1:
        raise ContractError("F2: у каскада ny = 1")
    if r["status"] not in ("ok", "max", "diverged"):
        raise ContractError(f"F2: status={r['status']!r}")
    if r["source"] == "picard":
        if not _isint(r["iters"]) or r["iters"] < 0:
            raise ContractError("F2: iters у picard — целое")
    elif r["iters"] is not None:
        raise ContractError("F2: iters у каскада null")
    t = r["time"]
    _check_keys(t, ("total_s", "setup_s", "work_s", "per_row_s"), "F2.time")
    for k in ("total_s", "setup_s", "work_s", "per_row_s"):
        if not _isnum(t[k]) or t[k] < 0:
            raise ContractError(f"F2.time.{k}")
    if abs(t["per_row_s"] - t["work_s"] / r["ny"]) > 1e-6 * max(1.0, t["work_s"]):
        raise ContractError("F2.time.per_row_s != work_s/ny")
    mem = r["memory"]
    _check_keys(mem, ("peak_rss_mb", "arrays_mb"), "F2.memory")
    for k in ("peak_rss_mb", "arrays_mb"):
        if not _isnum(mem[k]) or mem[k] < 0:
            raise ContractError(f"F2.memory.{k}")
    b = r["balance"]
    _check_keys(b, ("max_rel_div", "rms_rel_div", "levels"), "F2.balance")
    for k in ("max_rel_div", "rms_rel_div"):
        if not _isnum(b[k]) or b[k] < 0:
            raise ContractError(f"F2.balance.{k}")
    if not isinstance(b["levels"], list) or not b["levels"]:
        raise ContractError("F2.balance.levels — непустой список")
    for lv in b["levels"]:
        _check_keys(lv, ("dx", "max_rel_div"), "F2.balance.levels[]")
        if lv["dx"] not in LEVELS_DX or not _isnum(lv["max_rel_div"]):
            raise ContractError("F2.balance.levels[]")
    if r["source"] == "picard":
        if not _isnum(r["y_uniform"]) or r["y_uniform"] < 0:
            raise ContractError("F2: y_uniform у picard — число")
        if r["query"] is not None:
            raise ContractError("F2: query у picard null")
    else:
        if r["y_uniform"] is not None:
            raise ContractError("F2: y_uniform у каскада null")
        q = r["query"]
        if q is not None:  # у каскада без опроса точки допустим null
            _check_keys(q, ("n_points", "us_per_point", "threads", "max_abs_diff_vs_full"), "F2.query")
            if not _isint(q["n_points"]) or q["n_points"] < 0:
                raise ContractError("F2.query.n_points")
            if not _isnum(q["us_per_point"]) or not _isnum(q["max_abs_diff_vs_full"]):
                raise ContractError("F2.query: числа")
            if q["threads"] != 1:
                raise ContractError("F2.query.threads = 1")
    if not isinstance(r["field"], str) or not isinstance(r["cmd"], str):
        raise ContractError("F2: field/cmd — строки")
    h = r["host"]
    _check_keys(h, ("cpu", "rustc"), "F2.host")
    return r


def read_f2(path):
    with open(path) as f:
        return validate_f2(json.load(f))


# ---------------- M1 ----------------

def validate_m1(m):
    _check_keys(m, M1_KEYS, "M1")
    if m["format"] != "cascade2d-metrics":
        raise ContractError(f"M1: format={m['format']!r}")
    if m["version"] != 1:
        raise ContractError(f"M1: version={m['version']!r}")
    if m["case"] not in CASES:
        raise ContractError(f"M1: case={m['case']!r}")
    if not isinstance(m["ref"], str):
        raise ContractError("M1: ref не строка")
    if not _isnum(m["U_ref"]) or m["U_ref"] <= 0:
        raise ContractError("M1: U_ref > 0")
    if not isinstance(m["E_ref"], dict):
        raise ContractError("M1: E_ref не объект")
    if not isinstance(m["rows"], list):
        raise ContractError("M1: rows не список")
    for i, row in enumerate(m["rows"]):
        w = f"M1.rows[{i}]"
        _check_keys(row, M1_ROW_KEYS, w)
        if not isinstance(row["field"], str):
            raise ContractError(f"{w}.field")
        if row["source"] not in SOURCES:
            raise ContractError(f"{w}.source={row['source']!r}")
        if row["variant"] is not None and row["variant"] not in VARIANTS:
            raise ContractError(f"{w}.variant={row['variant']!r}")
        if row["dx"] not in LEVELS_DX:
            raise ContractError(f"{w}.dx")
        if not (row["parent_dx"] is None or row["parent_dx"] in LEVELS_DX):
            raise ContractError(f"{w}.parent_dx")
        if not (row["seed"] is None or _isint(row["seed"])):
            raise ContractError(f"{w}.seed")
        for k in ("E_u", "E_w", "E_u_lee", "r_w", "L_rec", "L_rec_ref", "w_max", "w_max_ref",
                  "F_up", "F_up_ref", "max_rel_div", "max_speed"):
            if not _num_or_null(row[k]):
                raise ContractError(f"{w}.{k} не число/null")
        for k in ("E_u", "E_w", "max_rel_div", "max_speed"):
            if row[k] is None:
                raise ContractError(f"{w}.{k} не может быть null")
        dS = row["dS"]
        _check_keys(dS, ("25", "50", "100", "mean"), f"{w}.dS")
        for k in ("25", "50", "100", "mean"):
            if not _num_or_null(dS[k]):
                raise ContractError(f"{w}.dS.{k}")
        for k in ("sigma_u", "sigma_w"):
            v = row[k]
            if v is not None and not (isinstance(v, list) and all(_isnum(e) for e in v)):
                raise ContractError(f"{w}.{k} не список чисел/null")
            if v is not None and row["variant"] != "V3h":
                raise ContractError(f"{w}.{k} только у V3h")
    return m


def read_m1(path):
    with open(path) as f:
        return validate_m1(json.load(f))
