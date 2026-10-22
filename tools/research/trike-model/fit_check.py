"""TK-6: проверка посадки пилота (поза sit) в тележке v2 числами -> fit.json.

    blender --background --python tools/research/trike-model/fit_check.py [-- --out tools/research/trike-model/fit.json]

Оси Blender (нос +Y, вверх +Z, начало — HangPoint), см. TK-K1..K3. Меши пилота (PilotBody, Helmet) берутся после
depsgraph (evaluated, арматура в позе sit), меши тележки — Trike_LOD0 и Engine_LOD0 (объединение вершин 1e-5, острова связности).
Все значения в см, по модулю (в *_signed — со знаком: < 0 — внутри детали).
"""
import json
import math
import os
import sys

import bmesh
import bpy
from mathutils import Vector
from mathutils.bvhtree import BVHTree

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tools", "blender"))
import render_trike as T  # noqa: E402

a = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
OUT = a[a.index("--out") + 1] if "--out" in a else os.path.join(ROOT, "tools/research/trike-model/fit.json")
P = json.load(open(os.path.join(ROOT, "tools/blender/trike_params.json")))
S = P["seat"]
V = lambda l: Vector(l)  # noqa: E731

T.load(True)
dg = bpy.context.evaluated_depsgraph_get()


def islands(obj):
    """Острова связности (вершины слиты по позиции) -> [(BVH, bbox_lo, bbox_hi, closed, ntri)]."""
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    bmesh.ops.transform(bm, matrix=obj.matrix_world, verts=bm.verts)
    bm.verts.ensure_lookup_table()
    seen, out = set(), []
    for v0 in bm.verts:
        if v0.index in seen:
            continue
        st, comp = [v0], []
        seen.add(v0.index)
        while st:
            v = st.pop()
            comp.append(v)
            for e in v.link_edges:
                w = e.other_vert(v)
                if w.index not in seen:
                    seen.add(w.index)
                    st.append(w)
        fs = {f for v in comp for f in v.link_faces}
        closed = all(len(e.link_faces) == 2 for v in comp for e in v.link_edges)
        sub = bmesh.new()
        m = {}
        for v in comp:
            m[v.index] = sub.verts.new(v.co)
        for f in fs:
            try:
                sub.faces.new([m[v.index] for v in f.verts])
            except ValueError:
                pass
        bmesh.ops.triangulate(sub, faces=sub.faces[:])
        bvh = BVHTree.FromBMesh(sub)
        co = [v.co.copy() for v in comp]
        lo = Vector((min(c.x for c in co), min(c.y for c in co), min(c.z for c in co)))
        hi = Vector((max(c.x for c in co), max(c.y for c in co), max(c.z for c in co)))
        out.append({"bvh": bvh, "lo": lo, "hi": hi, "closed": closed, "ntri": len(sub.faces),
                    "src": obj.name, "co": co})
        sub.free()
    bm.free()
    return out


isl = islands(bpy.data.objects["Trike_LOD0"]) + islands(bpy.data.objects["Engine_LOD0"])
closed = [i for i in isl if i["closed"]]


def inside(i, p):
    """Чётность пересечений луча по трём осям (большинство голосов)."""
    pad = 1e-4
    if any(p[k] < i["lo"][k] - pad or p[k] > i["hi"][k] + pad for k in range(3)):
        return False
    votes = 0
    for d in (Vector((0, 0, 1)), Vector((0.31, 0.83, 0.47)).normalized(), Vector((-0.77, 0.21, -0.6)).normalized()):
        n, o = 0, p.copy()
        while True:
            loc, nor, idx, dist = i["bvh"].ray_cast(o, d)
            if loc is None:
                break
            n += 1
            o = loc + d * 1e-6
        votes += n % 2
    return votes >= 2


# --- меши пилота (evaluated, мировые координаты)
pil = {}
for nm in ("PilotBody", "Helmet"):
    ob = bpy.data.objects[nm]
    ev = ob.evaluated_get(dg)
    me = ev.to_mesh()
    verts = [ev.matrix_world @ v.co for v in me.vertices]
    mat = {}
    for p in me.polygons:
        for vi in p.vertices:
            mat[vi] = ob.material_slots[p.material_index].name if ob.material_slots else nm
    gn = {g.index: g.name for g in ob.vertex_groups}
    col = set()  # вершины кокона/фала: кости схлопнуты в точку (TK-K3), геометрии нет
    for v in ob.data.vertices:
        w = sum(g.weight for g in v.groups if gn.get(g.group, "").startswith(("Pod", "Strap")))
        if w > 0.5:
            col.add(v.index)
    pil[nm] = [(verts[k], mat.get(k, nm)) for k in range(len(verts)) if k not in col]
    print("COLLAPSED", nm, len(col))
SKIP = {"Strap", "Visor", "PodStripe"}  # схлопнутые/вырожденные
pts = [(p, m, nm) for nm, l in pil.items() for p, m in l if m not in SKIP]

# --- проникание: вершины пилота внутри замкнутых деталей
pen = {"inside_cm": 0.0, "n_inside": 0, "worst": None}
for p, m, nm in pts:
    for i in closed:
        if inside(i, p):
            loc, nor, idx, dist = i["bvh"].find_nearest(p)
            d = dist * 100
            pen["n_inside"] += 1
            if d > pen["inside_cm"]:
                pen.update(inside_cm=d, worst={"vertex": [round(c, 3) for c in p], "material": m,
                                               "island_lo": [round(c, 3) for c in i["lo"]],
                                               "island_hi": [round(c, 3) for c in i["hi"]]})


def isl_near(point, tol=0.12):
    return [i for i in isl if all(i["lo"][k] - tol <= point[k] <= i["hi"][k] + tol for k in range(3))]


def down_gap(verts, islands_):
    """Минимум (z вершины - z поверхности ниже) по лучу вниз; со знаком: < 0 — вершина ниже верхней поверхности."""
    best = None
    for p in verts:
        for i in islands_:
            if not (i["lo"].x - 1e-4 <= p.x <= i["hi"].x + 1e-4 and i["lo"].y - 1e-4 <= p.y <= i["hi"].y + 1e-4):
                continue
            loc, nor, idx, dist = i["bvh"].ray_cast(Vector((p.x, p.y, i["hi"].z + 0.05)), Vector((0, 0, -1)))
            if loc is None:
                continue
            g = p.z - loc.z
            if best is None or g < best[0]:
                best = (g, p, loc)
    return best


# --- сиденье: низ седалища -> верх подушки
sp, spz = V(S["seat_pan"]), S["seat_pan_size"]
pan = min((i for i in closed if abs((i["hi"].z + i["lo"].z) / 2 - sp.z) < 0.1),
          key=lambda i: ((i["hi"] + i["lo"]) / 2 - sp).length)
hip_z = S["hip"][2]
seat_v = [p for p, m, nm in pts if m in ("Trousers", "Pod", "Jacket") and abs(p.x - sp.x) <= spz[0] / 2
          and abs(p.y - sp.y) <= spz[1] / 2 and p.z < hip_z]
sg = down_gap(seat_v, [pan])

# --- спинка: по нормали спинки
ang = math.radians(S["backrest_angle_deg"])
bb = V(S["backrest_base"])
n_b, u_b = Vector((0, math.cos(ang), math.sin(ang))), Vector((0, -math.sin(ang), math.cos(ang)))
back = min((i for i in closed if i["lo"].z > bb.z - 0.1 and i["hi"].z > bb.z + 0.3 and abs((i["hi"].y + i["lo"].y) / 2 - bb.y + 0.1) < 0.3
            and (i["hi"].x - i["lo"].x) > 0.3 and (i["hi"].z - i["lo"].z) > 0.4), key=lambda i: ((i["hi"] + i["lo"]) / 2 - bb).length)
d_front = max(c.dot(n_b) for c in back["co"])
bw, bh = S["backrest_size"]
best_b = None
for p, m, nm in pts:
    if m in ("Glove", "Boot", "Sole", "JacketSleeve") or nm == "Helmet":
        continue
    h = (p - bb).dot(u_b)
    if abs(p.x - bb.x) <= bw / 2 and 0 <= h <= bh:
        s = p.dot(n_b) - d_front
        if best_b is None or s < best_b[0]:
            best_b = (s, p)

# --- подножки / педаль
feet = {}
for side, key, sx in (("l", "foot_l", -1), ("r", "throttle_pedal", 1)):
    fp = V(S[key])
    cand = [i for i in closed if i["lo"].x - 0.05 <= fp.x <= i["hi"].x + 0.05 and i["lo"].y - 0.1 <= fp.y <= i["hi"].y + 0.1
            and i["hi"].z - fp.z < 0.06 and fp.z - i["hi"].z < 0.06 and (i["hi"].z - i["lo"].z) < 0.06]
    sole = [p for p, m, nm in pts if m == "Sole" and p.x * sx > 0]
    g = down_gap(sole, cand)
    feet[side] = (g, cand)

# --- глаза и контрольные точки позы
head = bpy.data.objects["Head"].matrix_world.translation
eye_err = (head - V(S["eye"])).length * 100
bones = {}
arm = bpy.data.objects["Pilot"]
for nm in ("Thigh.L", "Thigh.R"):
    b = arm.pose.bones[nm]
    bones[nm] = arm.matrix_world @ b.head  # TK-K3: середина голов костей бедра
hip_mid = (bones["Thigh.L"] + bones["Thigh.R"]) / 2


def r(x):
    return round(abs(x) * 100, 2)


res = {
    "version": 1,
    "units": "cm",
    "model": {"trike": "assets/models/trike/trike.glb (Trike_LOD0, Engine_LOD0)", "pilot": "assets/models/pilot.glb (action sit)"},
    "method": "вершины PilotBody/Helmet (evaluated) против замкнутых островов Trike_LOD0/Engine_LOD0; проникание = max(глубина "
              "вершин внутри замкнутого острова (чётность луча, расстояние до ближайшей поверхности), заглубление подошв/седалища "
              "ниже верхней плоскости опоры по лучу вниз); зазоры — по лучу вниз (сиденье, подножки) и по нормали спинки (спинка)",
    "n_pilot_vertices": len(pts),
    "n_trike_islands": len(isl), "n_closed_islands": len(closed),
    "pen_inside_cm": round(pen["inside_cm"], 2), "n_vertices_inside": pen["n_inside"], "pen_inside_worst": pen["worst"],
    "seat_gap_signed_cm": round(sg[0] * 100, 2) if sg else None,
    "seat_gap_cm": r(sg[0]) if sg else None,
    "back_gap_signed_cm": round(best_b[0] * 100, 2) if best_b else None,
    "back_gap_cm": r(best_b[0]) if best_b else None,
    "foot_gap_l_signed_cm": round(feet["l"][0][0] * 100, 2) if feet["l"][0] else None,
    "foot_gap_l_cm": r(feet["l"][0][0]) if feet["l"][0] else None,
    "foot_gap_r_signed_cm": round(feet["r"][0][0] * 100, 2) if feet["r"][0] else None,
    "foot_gap_r_cm": r(feet["r"][0][0]) if feet["r"][0] else None,
    "foot_support_islands": {k: len(v[1]) for k, v in feet.items()},
    "eye_err_cm": round(eye_err, 2), "head": [round(c, 3) for c in head], "seat_eye": S["eye"],
    "hip_err_cm": round((hip_mid - V(S["hip"])).length * 100, 2),
}
overs = [-x for x in (res["seat_gap_signed_cm"], res["foot_gap_l_signed_cm"], res["foot_gap_r_signed_cm"]) if x is not None and x < 0]
res["pen_support_cm"] = round(max(overs, default=0.0), 2)
res["max_penetration_cm"] = round(max(res["pen_inside_cm"], res["pen_support_cm"]), 2)
os.makedirs(os.path.dirname(OUT), exist_ok=True)
json.dump(res, open(OUT, "w"), indent=1, ensure_ascii=False)
print("FIT", json.dumps({k: v for k, v in res.items() if k not in ("method", "model", "pen_inside_worst")}, ensure_ascii=False))
print("WORST", res["pen_inside_worst"])
