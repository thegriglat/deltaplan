"""Прикидка сжатия высот мест: квантование, предсказатель, byte shuffle, уровни zstd.
python -I exp.py  (venv heat_ca: zstandard, numpy). Результат: results/py_sizes.json"""
import json, sys, time, os
import numpy as np, zstandard as zstd
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../../data/terrain"))
PLACES = ["altai", "ongudai", "aushkul", "askarovo"]

def load(place, lid):
    m = json.load(open(f"{ROOT}/{place}/meta.json"))
    l = [x for x in m["layers"] if x["id"] == lid][0]
    raw = zstd.ZstdDecompressor().decompress(open(f"{ROOT}/{place}/{l['file']}", "rb").read())
    return np.frombuffer(raw, "<f4").reshape(l["height"], l["width"]).astype(np.float64), len(open(f"{ROOT}/{place}/{l['file']}", "rb").read())

def z(b, lvl):
    return len(zstd.ZstdCompressor(level=lvl).compress(b))

def zz(d):  # zigzag
    d = d.astype(np.int64); return ((d << 1) ^ (d >> 63))

def shuffle16(a):  # a: uint array -> planes lo, hi
    a = a.astype(np.uint32)
    return np.concatenate([(a & 255).astype(np.uint8).ravel(), ((a >> 8) & 255).astype(np.uint8).ravel(), (a >> 16).astype(np.uint8).ravel()])

def shuffle2(a):
    a = a.astype(np.uint32)
    return np.concatenate([(a & 255).astype(np.uint8).ravel(), ((a >> 8) & 255).astype(np.uint8).ravel()])

def pred_left(q):
    d = q.copy(); d[:, 1:] -= q[:, :-1]; d[0, 0] = q[0, 0]; d[1:, 0] = q[1:, 0] - q[:-1, 0]; return d

def pred_avg(q):  # (W+N)/2 floor
    P = np.zeros_like(q); P[1:, 1:] = (q[1:, :-1] + q[:-1, 1:]) >> 1; P[0, 1:] = q[0, :-1]; P[1:, 0] = q[:-1, 0]; return q - P

def pred_med(q):  # LOCO-I
    W = np.zeros_like(q); N = W.copy(); NW = W.copy()
    W[:, 1:] = q[:, :-1]; N[1:] = q[:-1]; NW[1:, 1:] = q[:-1, :-1]
    W[0, 0] = 0
    P = np.where(NW >= np.maximum(W, N), np.minimum(W, N), np.where(NW <= np.minimum(W, N), np.maximum(W, N), W + N - NW))
    P[0, 1:] = q[0, :-1]; P[1:, 0] = q[:-1, 0]; P[0, 0] = 0
    return q - P

def pred_grad(q):  # W+N-NW (plane)
    W = np.zeros_like(q); N = W.copy(); NW = W.copy()
    W[:, 1:] = q[:, :-1]; N[1:] = q[:-1]; NW[1:, 1:] = q[:-1, :-1]
    P = W + N - NW; P[0, 1:] = q[0, :-1]; P[1:, 0] = q[:-1, 0]; P[0, 0] = 0
    return q - P

res = {}
tot = {}
def add(key, place, n):
    tot.setdefault(key, {}).setdefault(place, 0); tot[key][place] += n

for p in PLACES:
    for lid in ["detail", "far"]:
        h, cur = load(p, lid)
        f32 = h.astype("<f4").tobytes()
        add("A f32 zstd3 (текущее, файл)", p, cur)
        add("A f32 zstd19", p, z(f32, 19))
        add("A f32 zstd19+shuffle4", p, z(np.frombuffer(f32, np.uint8).reshape(-1, 4).T.copy().tobytes(), 19))
        for sh in [32, 16, 8, 4]:
            q = np.round((h - h.min()) * sh).astype(np.int64)
            bits = int(q.max()).bit_length()
            err = np.abs(q / sh + h.min() - h)
            tag = f"q1/{sh}"
            res.setdefault(tag, {"maxerr": 0, "bits": 0}); res[tag]["maxerr"] = max(res[tag]["maxerr"], float(err.max())); res[tag]["bits"] = max(res[tag]["bits"], bits)
            res[tag].setdefault("rmse2", []).append(float((err ** 2).mean()))
            if bits > 16:
                # 3 плоскости байт (24 бит)
                sf = shuffle16
                raw = q.astype("<u4").tobytes()
                add(f"{tag} u32? пропуск", p, 0)
            for pn, pf in [("raw", lambda a: a), ("left", pred_left), ("avg", pred_avg), ("med", pred_med), ("grad", pred_grad)]:
                d = pf(q); u = zz(d) if pn != "raw" else q
                nb = max(int(u.max()).bit_length(), 1)
                planes = shuffle2(u) if nb <= 16 else shuffle16(u)
                for lvl in (3, 19):
                    add(f"{tag} {pn} shuf zstd{lvl}", p, z(planes.tobytes(), lvl))
                if nb <= 16 and lvl == 19:
                    pass
res_sizes = {k: {p: round(v.get(p, 0) / 1e6, 3) for p in PLACES} | {"sum": round(sum(v.values()) / 1e6, 3)} for k, v in tot.items()}
for k in res: res[k]["rmse"] = float(np.sqrt(np.mean(res[k].pop("rmse2"))))
json.dump({"sizes_mb": res_sizes, "quant": res}, open(os.path.join(os.path.dirname(__file__), "results/py_sizes.json"), "w"), indent=1, ensure_ascii=False)
for k, v in sorted(res_sizes.items(), key=lambda kv: kv[1]["sum"]):
    print(f"{v['sum']:8.2f}  {k}  " + " ".join(f"{v[p]:.2f}" for p in PLACES))
print(res)
