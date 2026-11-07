"""Чтение/запись SW1–SW3 (пара json+bin, float32 LE, запись атомарная: .bin, затем JSON)."""
import datetime
import json
import os
import subprocess

import numpy as np


def git_rev():
    try:
        r = subprocess.run(["git", "rev-parse", "--short", "HEAD"], capture_output=True, text=True,
                           cwd=os.path.dirname(os.path.abspath(__file__)), timeout=5)
        return r.stdout.strip() or "unknown"
    except Exception:
        return "unknown"


def now_iso():
    return datetime.datetime.now().replace(microsecond=0).isoformat()


def _atomic_write(path, data, mode):
    tmp = path + ".tmp"
    with open(tmp, mode) as f:
        f.write(data)
    os.replace(tmp, path)


def write_pair(json_path, meta, arrays):
    """arrays: {имя: ndarray (ny, nx)}; в meta['arrays'] записываются [смещение, длина] в float32."""
    idx, blobs, off = {}, [], 0
    for k, a in arrays.items():
        a = np.ascontiguousarray(a, dtype="<f4").ravel()
        idx[k] = [off, int(a.size)]
        blobs.append(a.tobytes())
        off += a.size
    meta = dict(meta, arrays=idx)
    _atomic_write(json_path[: -len(".json")] + ".bin", b"".join(blobs), "wb")
    _atomic_write(json_path, json.dumps(meta, ensure_ascii=False, indent=1), "w")


def write_json(json_path, meta):
    _atomic_write(json_path, json.dumps(meta, ensure_ascii=False, indent=1), "w")


def read_pair(json_path):
    """-> (meta, {имя: ndarray float64 (ny, nx)})."""
    with open(json_path) as f:
        meta = json.load(f)
    g = meta["grid"]
    shape = (g["ny"], g["nx"])
    raw = np.fromfile(json_path[: -len(".json")] + ".bin", dtype="<f4")
    arrs = {k: raw[o:o + n].astype(np.float64).reshape(shape) for k, (o, n) in meta["arrays"].items()}
    return meta, arrs
