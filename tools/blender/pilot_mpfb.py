"""Тело пилота из MPFB 2 (MakeHuman для Blender): человек, кулаки вокруг трубы, запекание.

Используется из build_pilot.py. MPFB — только инструмент сборки (GPL-3.0, в игру не попадает),
базовый меш, морфы и веса рига game_engine — CC0 (ASSETS.md). MPFB ставится в отдельный
пользовательский каталог Blender: tools/blender/setup_mpfb.sh.

Система координат MPFB: Z вверх, лицом к −Y, стопы на z = 0, метры (scale 0.1).
"""
import math
import sys

import bpy
from mathutils import Matrix, Vector

USER_DIR = "~/.cache/deltaplan/blender_user"
# взрослый мужчина ~30 лет, атлетичный-средний, рост ≈ 1,78 м (height 0.5 → 1,727, 0.6 → 1,844)
MACRO = {"gender": 1.0, "age": 0.538, "muscle": 0.6, "weight": 0.55, "height": 0.545,
         "proportions": 0.5}
FINGERS = ("index", "middle", "ring", "pinky")
MIN_CLEAR = 0.0192     # ни одна вершина кисти не ближе к оси трубы (стойка r 0,019)


def require_mpfb():
    """HumanService, TargetService из MPFB или внятная ошибка."""
    try:
        from bl_ext.user_default.mpfb.services.humanservice import HumanService
        from bl_ext.user_default.mpfb.services.targetservice import TargetService
    except ImportError:
        print("\nОШИБКА: не найден MPFB 2 (MakeHuman для Blender). Установите его в отдельный "
              "каталог Blender (один раз):\n    tools/blender/setup_mpfb.sh\nи запускайте сборку "
              "пилота так:\n    BLENDER_USER_RESOURCES=%s blender --background --python "
              "tools/blender/build_pilot.py\n" % USER_DIR, file=sys.stderr)
        sys.exit(1)
    return HumanService, TargetService


def make_human():
    """(меш Human, риг game_engine) — в позе покоя MPFB (A-поза)."""
    human_service, target_service = require_mpfb()
    md = target_service.get_default_macro_info_dict()
    md.update(MACRO)
    # detailed_helpers: кубики суставов нужны, чтобы риг подогнался под фигуру
    h = human_service.create_human(mask_helpers=True, detailed_helpers=True,
                                   extra_vertex_groups=True, feet_on_ground=True, scale=0.1,
                                   macro_detail_dict=md)
    rig = human_service.add_builtin_rig(h, "game_engine")
    bpy.context.view_layer.update()
    return h, rig


# ------------------------------------------------------------------ кулак

def _set_dir(rig, name: str, target_tail: Vector) -> None:
    """Повернуть кость (кратчайшим поворотом) так, чтобы хвост смотрел в target_tail."""
    pb = rig.pose.bones[name]
    bpy.context.view_layer.update()
    m = pb.matrix.copy()
    head = m.translation.copy()
    d = Vector(m.col[1][:3]).normalized()
    q = d.rotation_difference((target_tail - head).normalized())
    r = q.to_matrix().to_4x4() @ Matrix(m.to_3x3()).to_4x4()
    r.translation = head
    pb.matrix = r
    bpy.context.view_layer.update()


def _wrap(p: Vector, axis_pt: Vector, axis: Vector, sense: int, lengths, radii) -> list:
    """Звенья вокруг трубы: от точки p каждое звено касается окружности радиуса radii[i]
    (или упирается в неё концом), обход вокруг оси axis в сторону sense (+1/−1)."""
    pts = [p]
    for ln, rad in zip(lengths, radii):
        cp = axis_pt + axis * (p - axis_pt).dot(axis)
        er = p - cp
        rho = er.length
        er.normalize()
        et = axis.cross(er) * sense
        if rho <= rad + 1e-5:
            d = et
        elif rho * rho - rad * rad <= ln * ln:           # касание внутри звена
            a = math.asin(rad / rho)
            d = -er * math.cos(a) + et * math.sin(a)
        else:                                            # звено упирается концом
            cb = (rho * rho + ln * ln - rad * rad) / (2 * rho * ln)
            b = math.acos(min(max(cb, -1.0), 1.0))
            d = -er * math.cos(b) + et * math.sin(b)
        p = p + d * ln
        pts.append(p)
    return pts


def _hand_frame(rig, s: str):
    pb = rig.pose.bones
    w = pb["hand_" + s].head.copy()
    f = (w - pb["lowerarm_" + s].head).normalized()
    j = {k: pb[k + "_01_" + s].head.copy() for k in FINGERS}
    n0 = (j["index"] - w).cross(j["pinky"] - w)
    curl = Vector()
    dist = Vector()
    for k in FINGERS:
        d1 = (pb[k + "_01_" + s].tail - j[k]).normalized()
        tip = pb[k + "_03_" + s].tail - j[k]
        curl += tip - d1 * tip.dot(d1)
        dist += d1
    n = n0.normalized() * (1 if n0.dot(curl) > 0 else -1)     # к ладони
    a = j["index"] - j["pinky"]
    a = (a - n * a.dot(n)).normalized()                       # ось трубы: мизинец → большой
    dd = a.cross(n)
    dd *= 1 if dd.dot(dist) > 0 else -1                       # к кончикам пальцев
    return w, f, j, n, a, dd


def _dominant(ob, me, rig) -> list:
    """[(координата, кость с наибольшим весом)] — только кости рига."""
    names = _groups(ob)
    bones = rig.data.bones
    out = []
    for v in me.vertices:
        gs = [g for g in v.groups if names.get(g.group) in bones]
        if gs:
            out.append((v.co.copy(), names[max(gs, key=lambda g: g.weight).group]))
    return out


def palm_thickness(rig, verts: list, s: str) -> dict:
    """{кость: толщина от оси до ладонной стороны, м} для фаланг и подушки у костяшек."""
    w, f, j, n, a, dd = _hand_frame(rig, s)
    pb = rig.pose.bones
    out = {}
    jm = sum(j.values(), Vector()) / 4
    for co, nm in verts:
        if not nm.endswith("_" + s):
            continue
        if nm.startswith("hand"):
            if -0.03 < (co - jm).dot(dd) < 0.005:
                out[nm] = max(out.get(nm, 0.0), (co - jm).dot(n))
            continue
        if nm.split("_")[0] not in FINGERS + ("thumb",):
            continue
        hd = pb[nm].head
        d = (pb[nm].tail - hd).normalized()
        npp = (n - d * n.dot(d)).normalized()
        out[nm] = max(out.get(nm, 0.0), (co - hd).dot(npp))
    return out


def pose_fist(rig, s: str, grip_r: float, th: dict, oblique: float = 12.0):
    """Согнуть пальцы кисти s ('l'/'r') вокруг трубы радиуса grip_r; th — толщины (palm_thickness
    + поправки). Ось трубы — поперёк ладони, со стороны указательного ближе к запястью на oblique°
    (косая ладонная складка — большой палец достаёт до трубы). Возвращает (точка на оси, ось
    мизинец→большой палец)."""
    bones = rig.data.bones
    w, f, j, n, a, dd = _hand_frame(rig, s)
    jm = sum(j.values(), Vector()) / 4
    a = (Matrix.Rotation(math.radians(oblique), 3, n) @ a).normalized()
    if a.dot(dd) > 0:        # указательный конец — к запястью
        a = (Matrix.Rotation(math.radians(-2 * oblique), 3, n) @ a).normalized()
    c0 = jm + n * (grip_r + th["hand_" + s]) - dd * 0.004
    for k in FINGERS:
        names = [f"{k}_0{i}_{s}" for i in (1, 2, 3)]
        pts = _wrap(j[k], c0, a, -1 if a.cross(j[k] - c0).dot(dd) < 0 else 1,
                    [bones[nm].length for nm in names], [grip_r + th[nm] for nm in names])
        for nm, tgt in zip(names, pts[1:]):
            _set_dir(rig, nm, tgt)
    # большой палец: пястная кость к точке под трубой (ладонная сторона, ближе к запястью),
    # дальше — навстречу пальцам вокруг трубы, чуть дальше указательного
    names = [f"thumb_0{i}_{s}" for i in (1, 2, 3)]
    cmc = rig.pose.bones[names[0]].head.copy()
    l1 = bones[names[0]].length
    ct = c0 + a * ((j["index"] - c0).dot(a) + 0.01)
    eb = -n
    dt = grip_r + th[names[1]]
    best = None
    for phi in range(-240, -40, 2):
        for k in range(0, 40):
            rho = dt + 0.001 * k
            m = ct + (dd * math.cos(math.radians(phi)) + eb * math.sin(math.radians(phi))) * rho
            cost = (((m - cmc).length - l1) / 0.002) ** 2 + ((phi + 140) / 40) ** 2 \
                + ((rho - dt - 0.004) / 0.01) ** 2
            if best is None or cost < best[0]:
                best = (cost, m)
    _set_dir(rig, names[0], best[1])
    p = rig.pose.bones[names[1]].head.copy()
    sense = 1 if dd.cross(eb).dot(a) > 0 else -1          # против обхода пальцев
    pts = _wrap(p, ct, a, sense, [bones[nm].length for nm in names[1:]],
                [grip_r + th[nm] for nm in names[1:]])
    for nm, tgt in zip(names[1:], pts[1:]):
        _set_dir(rig, nm, tgt)
    return c0, a


def _groups(ob) -> dict:
    return {g.index: g.name for g in ob.vertex_groups}


def evaluated_mesh(ob):
    dg = bpy.context.evaluated_depsgraph_get()
    return bpy.data.meshes.new_from_object(ob.evaluated_get(dg), preserve_all_data_layers=True,
                                           depsgraph=dg)


def _wrist_fix(rig, s: str, c: Vector, a: Vector) -> tuple:
    """Повернуть кисть в запястье, чтобы ось трубы была поперёк предплечья и пересекала его
    продолжение. Возвращает (ось трубы, расстояние запястье → хват вдоль предплечья)."""
    pb = rig.pose.bones["hand_" + s]
    w = pb.head.copy()
    f = (w - rig.pose.bones["lowerarm_" + s].head).normalized()
    a0 = (a - f * a.dot(f)).normalized()
    e1 = f.cross(a0).normalized()      # наклон оси трубы (лучевое/локтевое отведение)
    e2 = a0                            # сгиб/разгиб кисти

    def rot(x, y):
        return Matrix.Rotation(math.radians(x), 3, e1) @ Matrix.Rotation(math.radians(y), 3, e2)

    def cost(x, y):
        r = rot(x, y)
        ra = r @ a
        p = w + r @ (c - w)
        cr = ra.cross(f)
        dist = abs((p - w).dot(cr)) / max(cr.length, 1e-9)
        return (ra.dot(f)) ** 2 * 0.01 + dist ** 2 + (x * x + y * y) * 1e-9

    best = min(((cost(x, y), x, y) for x in range(-60, 61, 2) for y in range(-60, 61, 2)))
    for step in (0.5, 0.1, 0.02):
        _, bx, by = best
        best = min((cost(bx + i * step, by + k * step), bx + i * step, by + k * step)
                   for i in range(-6, 7) for k in range(-6, 7))
    _, x, y = best
    r = rot(x, y)
    m = pb.matrix.copy()
    t = Matrix.Translation(w) @ r.to_4x4() @ Matrix.Translation(-w)
    pb.matrix = t @ m
    bpy.context.view_layer.update()
    ra = (r @ a).normalized()
    p = w + r @ (c - w)
    # точка на прямой предплечья, ближайшая к оси трубы
    n = f.cross(ra)
    t2 = (p - w).cross(ra).dot(n) / n.length_squared
    print("FIST %s: запястье повёрнуто %.1f° / %.1f°, ось трубы ⟂ предплечью %.3f, хват %.3f м"
          % (s, x, y, ra.dot(f), t2))
    return ra, t2


def make_fists(h, rig, grip_r: float) -> dict:
    """Кулаки обеих рук (поза рига). {s: (ось трубы, HAND, зазор)}. Толщины фаланг меряются по
    мешу; если вершины кисти ближе MIN_CLEAR к оси трубы — виноватые звенья отодвигаются."""
    me = evaluated_mesh(h)
    verts = _dominant(h, me, rig)
    bpy.data.meshes.remove(me)
    out = {}
    for s in ("l", "r"):
        th = palm_thickness(rig, verts, s)
        for it in range(6):
            for pb in rig.pose.bones:
                if pb.name.endswith("_" + s) and pb.name.split("_")[0] in FINGERS + ("thumb",):
                    pb.matrix_basis = Matrix.Identity(4)
            bpy.context.view_layer.update()
            c, a = pose_fist(rig, s, grip_r, th)
            me = evaluated_mesh(h)
            worst = {}
            for co, nm in _dominant(h, me, rig):
                if not nm.endswith("_" + s) or nm.startswith(("lowerarm", "upperarm", "clav")):
                    continue
                d = co - c
                r = (d - a * d.dot(a)).length
                worst[nm] = min(worst.get(nm, 1.0), r)
            bpy.data.meshes.remove(me)
            clr = min(worst.values())
            bad = {k: v for k, v in worst.items() if v < MIN_CLEAR}
            print("FIST %s: зазор до оси трубы %.4f м %s" % (s, clr, " ".join(
                "%s %.4f" % kv for kv in sorted(bad.items()))))
            if not bad:
                break
            for k, v in bad.items():
                th[k] = th.get(k, 0.0) + (MIN_CLEAR - v) + 0.0005
        a2, hand = _wrist_fix(rig, s, c, a)
        out[s] = (a2, hand, clr)
    return out


def eye_center(h) -> Vector:
    """Середина между глазными яблоками (вспомогательная геометрия MPFB)."""
    mask = [m for m in h.modifiers if m.type == "MASK"]
    for m in mask:
        m.show_viewport = False
    me = evaluated_mesh(h)
    for m in mask:
        m.show_viewport = True
    names = _groups(h)
    pts = [v.co.copy() for v in me.vertices
           if any(names.get(g.group, "") in ("helper-l-eye", "helper-r-eye") and g.weight > 0.5
                  for g in v.groups)]
    bpy.data.meshes.remove(me)
    return sum(pts, Vector()) / len(pts)

