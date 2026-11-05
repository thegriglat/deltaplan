#!/usr/bin/env python3
"""SLT-1: раскладка UV1 меша Sail у glb крыльев. Только python3 + numpy, Godot не нужен.
Запуск из корня репозитория:  python3 tools/research/sail-texture/uv_measure.py
Читает configs/wings/*.json -> visual.visual_model, assets/models/glider_*.glb; пишет uv_table.json рядом.
Система координат: glTF/Godot, Y вверх, нос = -Z, правая законцовка = +X."""
import glob, json, os, struct, sys
import numpy as np

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "uv_table.json")
CT = {5120: np.int8, 5121: np.uint8, 5122: np.int16, 5123: np.uint16, 5125: np.uint32, 5126: np.float32}
NC = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


def load_glb(path):
    b = open(path, "rb").read()
    assert b[:4] == b"glTF"
    off, js, bn = 12, None, b""
    while off < len(b):
        ln, ty = struct.unpack("<II", b[off:off + 8])
        if ty == 0x4E4F534A:
            js = json.loads(b[off + 8:off + 8 + ln])
        elif ty == 0x004E4942:
            bn = b[off + 8:off + 8 + ln]
        off += 8 + ln
    return js, bn


def acc(js, bn, i):
    a = js["accessors"][i]
    bv = js["bufferViews"][a["bufferView"]]
    n, nc, dt = a["count"], NC[a["type"]], CT[a["componentType"]]
    st = bv.get("byteStride", nc * np.dtype(dt).itemsize)
    base = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
    isz = np.dtype(dt).itemsize
    raw = np.frombuffer(bn, dtype=np.uint8)
    out = np.empty((n, nc), dtype=dt)
    for k in range(nc):
        idx = base + np.arange(n) * st + k * isz
        out[:, k] = np.frombuffer(raw[idx[:, None] + np.arange(isz)].tobytes(), dtype=dt)
    return out.astype(np.float64) if a["componentType"] != 5125 and a["componentType"] != 5123 else out


def node_world(js):
    """Мировая (в рамках модели) матрица каждого узла, колоночная конвенция glTF."""
    nodes = js["nodes"]
    par = {c: i for i, n in enumerate(nodes) for c in n.get("children", [])}

    def local(n):
        if "matrix" in n:
            return np.array(n["matrix"]).reshape(4, 4).T
        t = n.get("translation", [0, 0, 0]); q = n.get("rotation", [0, 0, 0, 1]); s = n.get("scale", [1, 1, 1])
        x, y, z, w = q
        R = np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                      [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                      [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])
        M = np.eye(4); M[:3, :3] = R * np.array(s); M[:3, 3] = t
        return M

    def world(i):
        M = local(nodes[i])
        return world(par[i]) @ M if i in par else M
    return [world(i) for i in range(len(nodes))]


def rd(x, n=4):
    return [round(float(v), n) for v in x]


def region_info(P, UV):
    """P (n,3) в модели, UV (n,2). Аффинная подгонка (u,v) = A (x,z) + c."""
    if len(P) == 0:
        return None
    X = np.c_[P[:, 0], P[:, 2], np.ones(len(P))]
    sol, *_ = np.linalg.lstsq(X, UV, rcond=None)
    A = sol[:2].T  # [[du/dx, du/dz],[dv/dx, dv/dz]]
    res = UV - X @ sol
    corr = lambda a, b: float(np.corrcoef(a, b)[0, 1]) if np.std(a) > 1e-9 and np.std(b) > 1e-9 else 0.0
    return {
        "uv_bbox": rd([UV[:, 0].min(), UV[:, 1].min(), UV[:, 0].max(), UV[:, 1].max()]),
        "n_verts": int(len(P)),
        "corr_u_x": round(corr(UV[:, 0], P[:, 0]), 3),
        "corr_v_z": round(corr(UV[:, 1], P[:, 2]), 3),
        "corr_u_z": round(corr(UV[:, 0], P[:, 2]), 3),
        "affine_xz_to_uv": [rd(A[0], 5), rd(A[1], 5)],
        "affine_det": round(float(np.linalg.det(A)), 6),
        "affine_resid_max_uv": round(float(np.abs(res).max()), 4),
        "x_range": rd([P[:, 0].min(), P[:, 0].max()]),
        "z_range": rd([P[:, 2].min(), P[:, 2].max()]),
    }


def dirs(info, below):
    """u=0 на какой законцовке; v=0 у какой кромки; зеркальность при взгляде снаружи
    (сверху для верха, снизу для низа; нос вверх экрана)."""
    if info is None:
        return {}
    cu, cv = info["corr_u_x"], info["corr_v_z"]
    A = np.array(info["affine_xz_to_uv"])
    # экран: right = +x (сверху) или -x (снизу), down = +z. (u,v) по экрану: A @ diag(sx,1)
    S = np.diag([-1.0 if below else 1.0, 1.0])
    B = A @ S
    mirrored = bool(np.linalg.det(B) < 0)
    return {
        "u_dir": "u=0 у левой законцовки (-X), u растёт вправо" if cu > 0 else "u=0 у правой законцовки (+X), u растёт влево",
        "v_dir": "v растёт назад (к +Z): v=0 у передней кромки" if cv > 0 else "v растёт к носу (к -Z): v=0 у задней кромки",
        "mirrored_when_viewed": mirrored,
        "screen_jacobian_uv_by_right_down": [rd(B[0], 5), rd(B[1], 5)],
    }


def measure(model_id):
    path = os.path.join(ROOT, "assets", "models", f"glider_{model_id}.glb")
    rec = {"id": model_id, "glb": os.path.relpath(path, ROOT), "has_sail": False}
    if not os.path.exists(path):
        rec["note"] = "нет glb"
        return rec
    js, bn = load_glb(path)
    W = node_world(js)
    sails = [i for i, n in enumerate(js["nodes"]) if n.get("name") == "Sail" and "mesh" in n]
    if not sails:
        rec["note"] = "нет узла Sail с мешем"
        return rec
    rec["has_sail"] = True
    ni = sails[0]
    rec["n_sail_nodes"] = len(sails)
    mesh = js["meshes"][js["nodes"][ni]["mesh"]]
    Ps, U1, U2, mats = [], [], [], set()
    for pr in mesh["primitives"]:
        mats.add(pr.get("material"))
        p = acc(js, bn, pr["attributes"]["POSITION"])
        Ps.append((np.c_[p, np.ones(len(p))] @ W[ni].T)[:, :3])
        U1.append(acc(js, bn, pr["attributes"]["TEXCOORD_0"]))
        U2.append(acc(js, bn, pr["attributes"]["TEXCOORD_1"]) if "TEXCOORD_1" in pr["attributes"] else np.full((len(p), 2), np.nan))
    P, UV, UV2 = np.vstack(Ps), np.vstack(U1), np.vstack(U2)
    rec["n_primitives"] = len(mesh["primitives"]); rec["n_verts"] = int(len(P)); rec["has_uv2"] = bool(not np.isnan(UV2).any())
    rec["uv_all_bbox"] = rd([UV[:, 0].min(), UV[:, 1].min(), UV[:, 0].max(), UV[:, 1].max()])
    # материал и текстура
    m = js.get("materials", [{}])[list(mats)[0]] if mats != {None} else {}
    bct = m.get("pbrMetallicRoughness", {}).get("baseColorTexture")
    rec["albedo_texture"] = bct is not None
    rec["albedo_uv_set"] = bct.get("texCoord", 0) if bct else None
    rec["base_color_factor"] = m.get("pbrMetallicRoughness", {}).get("baseColorFactor")
    if bct:
        img = js["images"][js["textures"][bct["index"]]["source"]]
        bv = js["bufferViews"][img["bufferView"]] if "bufferView" in img else None
        if bv is not None:
            d = bn[bv.get("byteOffset", 0):bv.get("byteOffset", 0) + bv["byteLength"]]
            if d[:8] == b"\x89PNG\r\n\x1a\n":
                rec["albedo_px"] = list(struct.unpack(">II", d[16:24]))
    # регионы: связные компоненты по индексам (отдельные сетки верха, низа и кармана киля)
    comp = np.arange(len(P)); off = 0; tris = []
    def find(i):
        while comp[i] != i:
            comp[i] = comp[comp[i]]; i = comp[i]
        return i
    for pr in mesh["primitives"]:
        n_p = len(acc(js, bn, pr["attributes"]["POSITION"]))
        idx = acc(js, bn, pr["indices"]).astype(np.int64).reshape(-1, 3) + off if "indices" in pr else (np.arange(n_p).reshape(-1, 3) + off)
        tris.append(idx)
        for t in idx:
            r0, r1, r2 = find(t[0]), find(t[1]), find(t[2])
            comp[r1] = r0; comp[find(r2)] = r0
        off += n_p
    roots = np.array([find(i) for i in range(len(P))])
    top = np.zeros(len(P), bool); bot = top.copy(); keel = top.copy(); comps = []
    for r in np.unique(roots):
        m_ = roots == r
        uw = UV[m_, 0].max() - UV[m_, 0].min(); vm = UV[m_, 1].mean()
        kind = "keel" if uw < 0.05 else ("top" if vm > 0.5 else "bottom")
        {"top": top, "bottom": bot, "keel": keel}[kind][m_] = True
        comps.append({"kind": kind, "n_verts": int(m_.sum()), "uv_bbox": rd([UV[m_, 0].min(), UV[m_, 1].min(), UV[m_, 0].max(), UV[m_, 1].max()])})
    rec["components"] = comps
    rec["unassigned_verts"] = int((~(top | bot | keel)).sum())
    rec["uv_bbox_top"] = region_info(P[top], UV[top])
    rec["uv_bbox_bottom"] = region_info(P[bot], UV[bot])
    rec["uv_bbox_keel"] = region_info(P[keel], UV[keel]) if keel.any() else None
    rec["top_dirs"] = dirs(rec["uv_bbox_top"], False)
    rec["bottom_dirs"] = dirs(rec["uv_bbox_bottom"], True)
    # короткие поля по контракту задания
    rec["top_u_dir"] = "левая" if rec["uv_bbox_top"] and rec["uv_bbox_top"]["corr_u_x"] > 0 else "правая"
    rec["top_v_dir"] = "передняя" if rec["uv_bbox_top"] and rec["uv_bbox_top"]["corr_v_z"] > 0 else "задняя"
    rec["bottom_u_dir"] = "левая" if rec["uv_bbox_bottom"] and rec["uv_bbox_bottom"]["corr_u_x"] > 0 else "правая"
    rec["bottom_v_dir"] = "передняя" if rec["uv_bbox_bottom"] and rec["uv_bbox_bottom"]["corr_v_z"] > 0 else "задняя"
    rec["mirrored_when_viewed"] = {"top": rec["top_dirs"].get("mirrored_when_viewed"),
                                   "bottom": rec["bottom_dirs"].get("mirrored_when_viewed")}
    T = np.vstack(tris)
    def area_xz(mask):
        t = T[mask[T[:, 0]] & mask[T[:, 1]] & mask[T[:, 2]]]
        a, b, c = P[t[:, 0]], P[t[:, 1]], P[t[:, 2]]
        return float(0.5 * np.abs((b[:, 0] - a[:, 0]) * (c[:, 2] - a[:, 2]) - (c[:, 0] - a[:, 0]) * (b[:, 2] - a[:, 2])).sum())
    rec["planform_area_top_m2"] = round(area_xz(top), 3)
    # размеры (без килевого кармана)
    Pw = P[~keel]
    rec["span_m"] = round(float(Pw[:, 0].max() - Pw[:, 0].min()), 3)
    root = Pw[(np.abs(Pw[:, 0]) < 0.05)]
    rec["root_chord_m"] = round(float(root[:, 2].max() - root[:, 2].min()), 3)
    rec["aspect_span_over_root_chord"] = round(rec["span_m"] / rec["root_chord_m"], 2) if rec["root_chord_m"] > 0 else None
    rec["mean_chord_m"] = round(rec["planform_area_top_m2"] / rec["span_m"], 3)
    rec["aspect_span_over_mean_chord"] = round(rec["span_m"] / rec["mean_chord_m"], 2)
    # UV2.y: верх 0..1, низ +2
    if rec["has_uv2"]:
        rec["uv2_y_top_range"] = rd([UV2[top, 1].min(), UV2[top, 1].max()], 3)
        rec["uv2_y_bottom_range"] = rd([UV2[bot, 1].min(), UV2[bot, 1].max()], 3)
    # прочие меши с материалом паруса (общая текстура)
    other = []
    for i, n in enumerate(js["nodes"]):
        if "mesh" in n and i != ni:
            for pr in js["meshes"][n["mesh"]]["primitives"]:
                if pr.get("material") in mats and mats != {None}:
                    other.append(n.get("name")); break
    rec["other_meshes_with_sail_uv"] = other
    return rec


def main():
    ids = []
    for f in sorted(glob.glob(os.path.join(ROOT, "configs", "wings", "*.json"))):
        c = json.load(open(f))
        vm = c.get("visual", {}).get("visual_model")
        if vm:
            ids.append(os.path.basename(vm)[len("glider_"):-len(".glb")])
    ids = sorted(set(ids))
    models = [measure(i) for i in ids]
    schema = ("uv_bbox_*: {uv_bbox [umin,vmin,umax,vmax], corr_u_x/corr_v_z — корреляция u с X, v с Z (Z назад), "
              "affine_xz_to_uv — подгонка (u,v)=A(x,z)+c по вершинам региона, affine_det, affine_resid_max_uv}. "
              "Регионы — связные компоненты сетки: keel (u-размах <0.05), top (средний v>0.5), bottom (v<0.5); v как в Godot (v=0 вверху картинки). *_dirs.mirrored_when_viewed: "
              "изображение смотрится зеркально, если смотреть на регион снаружи (сверху / снизу), нос вверху экрана, "
              "v вниз по картинке как в Godot. Система: Y вверх, нос -Z, правая законцовка +X.")
    json.dump({"models": models, "schema": schema, "n_wing_configs": len(ids)}, open(OUT, "w"), ensure_ascii=False, indent=1)
    print("models", len(models), "->", OUT)


if __name__ == "__main__":
    main()
