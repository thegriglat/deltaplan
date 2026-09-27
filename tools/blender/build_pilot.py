"""Пилот-манекен со скелетом и позами: assets/models/pilot.glb (+ assets/source/pilot.blend).

    blender --background --python tools/blender/build_pilot.py

Контракт (docs/models.md → «Пилот»): начало координат = карабин (точка подвеса HangPoint крыла),
вперёд +Y Blender = −Z Godot. Скелет `Pilot` (Armature → Skeleton3D), меши PilotBody (тело,
подвеска, руки, ноги, ботинки, фал) и Helmet (голова в шлеме — отдельно, кабинная камера её прячет).
Кости: Hips, Spine, Chest, Head, UpperArm.L/R, Forearm.L/R, Hand.L/R, Thigh.L/R, Shin.L/R,
Foot.L/R, PodTail (кокон ног), Strap (подвесной фал). Пустышки на костях: Head (глаза), HandL/HandR
(хват), CockpitCamera. Анимации: stand, walk, run, run_air, climb_in, prone, climb_out, flare
(docs/models.md).

Позы задаются положением тела и углами суставов в пространстве модели; руки — двухзвенная IK к
точкам хвата на стойках/базовой штанге (из glider_params.json: трапеция средняя для трёх крыльев).
Геометрия — в позе покоя (стоя, руки вниз), каждая часть жёстко привязана к своей кости.
"""
import math
import os
import sys

import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bl_util as U  # noqa: E402

FPS = 24
# длины сегментов (рост 1,75 м), м
PELVIS, SPINE, CHEST, HEAD = 0.12, 0.30, 0.23, 0.25
UPPER, FORE, HAND = 0.30, 0.27, 0.08
THIGH, SHIN, FOOT = 0.44, 0.44, 0.19
SHOULDER_X, SHOULDER_DOWN, HIP_X = 0.19, 0.06, 0.1
POD_LEN = 0.65          # кокон стоя (висит за ногами)
POD_ON = 1.45
EYE_FWD = 0.12          # глаза впереди оси шеи, м           # кокон лёжа (надет на ноги)
HEAD_PRONE = 20          # наклон головы лёжа, °: пустышки Head/CockpitCamera заданы так,
                         # что в позе prone взгляд горизонтален / на 10° вверх
X = Vector((1, 0, 0))


def rot_x(deg: float) -> Matrix:
    return Matrix.Rotation(math.radians(deg), 3, "X")


class Pose:
    """Позиции суставов в пространстве модели. lean — наклон корпуса вперёд от вертикали, °
    (90 — лёжа), head_lean — наклон головы от вертикали, °; ноги: (бедро вперёд, сгиб колена, стопа)
    для L и R; hands — точки хвата; elbow_pole — куда отводить локти (вектор)."""

    def __init__(self, hips, lean, head_lean, legs, hands, elbow_pole, pod=0.0):
        self.head_lean = head_lean
        self.hips = Vector(hips)
        r = rot_x(-lean)
        self.u = r @ Vector((0, 0, 1))
        self.f = r @ Vector((0, 1, 0))
        rh = rot_x(-head_lean)
        self.hu = rh @ Vector((0, 0, 1))
        self.hf = rh @ Vector((0, 1, 0))
        self.lean = lean
        self.legs = legs
        self.hands = [Vector(h) for h in hands]
        self.pole = Vector(elbow_pole)
        self.pod = pod  # 0 — кокон висит за ногами (стоя), 1 — надет на ноги (лёжа)

    @staticmethod
    def lerp(a: "Pose", b: "Pose", t: float, hand_t=None) -> "Pose":
        """Промежуточная поза: параметры линейно; hand_t — своя доля для каждой руки."""
        ht = hand_t or (t, t)
        return Pose(a.hips.lerp(b.hips, t), a.lean + (b.lean - a.lean) * t,
                    a.head_lean + (b.head_lean - a.head_lean) * t,
                    [tuple(x + (y - x) * t for x, y in zip(la, lb))
                     for la, lb in zip(a.legs, b.legs)],
                    [a.hands[i].lerp(b.hands[i], ht[i]) for i in range(2)],
                    a.pole.lerp(b.pole, t), a.pod + (b.pod - a.pod) * t)

    def bones(self) -> dict:
        """{кость: (голова, направление, опорная ось Z, длина)} в пространстве модели."""
        b = {}
        h, u, f = self.hips, self.u, self.f
        chest = h + u * SPINE
        neck = chest + u * CHEST
        b["Hips"] = (h, u, f, PELVIS)
        b["Spine"] = (h, u, f, SPINE)
        b["Chest"] = (chest, u, f, CHEST)
        b["Head"] = (neck, self.hu, self.hf, HEAD)
        for i, (s, side) in enumerate((("L", -1), ("R", 1))):
            sh = neck - u * SHOULDER_DOWN + X * side * SHOULDER_X
            elbow, wrist, grip = two_bone(sh, self.hands[i], UPPER, FORE + HAND,
                                          self.pole + X * side * 0.6)
            d_up = (elbow - sh).normalized()
            d_fore = (grip - elbow).normalized()
            b["UpperArm." + s] = (sh, d_up, f, UPPER)
            b["Forearm." + s] = (elbow, d_fore, f, FORE)
            b["Hand." + s] = (elbow + d_fore * FORE, d_fore, f, HAND)
            thigh, knee, foot = self.legs[i]
            hip = h + X * side * HIP_X - u * 0.04
            d_th = rot_x(-self.lean + thigh) @ Vector((0, 0, -1))
            kn = hip + d_th * THIGH
            d_sh = rot_x(-self.lean + thigh - knee) @ Vector((0, 0, -1))
            an = kn + d_sh * SHIN
            d_ft = rot_x(-self.lean + thigh - knee + foot) @ Vector((0, 0, -1))
            b["Thigh." + s] = (hip, d_th, f, THIGH)
            b["Shin." + s] = (kn, d_sh, f, SHIN)
            b["Foot." + s] = (an, d_ft, -d_sh, FOOT)
        k = self.pod
        b["PodTail"] = (h - f * 0.2 * (1 - k) - u * 0.02, -u, f, POD_LEN + (POD_ON - POD_LEN) * k)
        attach = h + u * 0.28 - f * 0.15
        b["Strap"] = (Vector((0, 0, -0.03)), (attach - Vector((0, 0, -0.03))).normalized(), -f,
                      (attach - Vector((0, 0, -0.03))).length)
        return b


def two_bone(a: Vector, target: Vector, l1: float, l2: float, pole: Vector):
    """Двухзвенная IK: плечо a, цель target. Возвращает (локоть, запястье, хват)."""
    d = target - a
    dist = min(max(d.length, abs(l1 - l2) + 1e-3), l1 + l2 - 1e-3)
    dn = d.normalized()
    x = (dist * dist + l1 * l1 - l2 * l2) / (2 * dist)
    hgt = math.sqrt(max(l1 * l1 - x * x, 0.0))
    pn = (pole - dn * pole.dot(dn)).normalized()
    elbow = a + dn * x + pn * hgt
    grip = a + dn * dist
    wrist = elbow + (grip - elbow).normalized() * FORE
    return elbow, wrist, grip


def bone_matrix(head: Vector, y: Vector, zref: Vector, length: float = 1.0) -> Matrix:
    y = y.normalized()
    if abs(y.dot(zref.normalized())) > 0.95:
        zref = X.cross(y) if abs(y.dot(X)) < 0.95 else Vector((0, 0, 1))
    x = y.cross(zref).normalized()
    z = x.cross(y).normalized()
    m = Matrix((x, y * length, z)).transposed().to_4x4()
    m.translation = head
    return m


# ------------------------------------------------------------------ позы

def grip_points(cf: dict, eye) -> dict:
    """Точки хвата: на стойке на высоте z (стоя/сваливание) и на базовой штанге (лёжа)."""
    w = 0.71  # полуширина базовой штанги, средняя по крыльям
    apex = Vector((0.04, cf["apex_forward_m"], cf["keel_z_m"] - 0.05))
    bar = Vector((w, cf["basebar_forward_m"], cf["keel_z_m"] - cf["basebar_drop_m"]))

    def upright(z: float, side: int) -> Vector:
        s = (apex.z - z) / (apex.z - bar.z)
        p = apex.lerp(bar, s)
        return Vector((side * p.x, p.y - 0.03, p.z))

    return {"upright": upright, "bar": lambda side: Vector((side * 0.33, bar.y, bar.z + 0.035))}


def poses(cf: dict, eye: Vector) -> dict:
    g = grip_points(cf, eye)
    up, bar = g["upright"], g["bar"]
    feet_z = -1.95
    hip_z = feet_z + THIGH + SHIN + 0.07
    pole_down = Vector((0, -0.3, -1))
    stand_hands = [up(-0.52, -1), up(-0.52, 1)]

    def grounded(hips_y: float, lean: float, head: float, legs: list) -> Pose:
        """Поза на земле: стопы горизонтально, нижняя стопа — на земле (z ступни −1.99)."""
        legs = [(th, kn, 90 + lean - th + kn + ft) for th, kn, ft in legs]
        p = Pose((0, hips_y, hip_z), lean, head, legs, stand_hands, pole_down)
        low = min(p.bones()["Foot." + s][0].z for s in ("L", "R"))
        return Pose((0, hips_y, hip_z - 1.91 - low), lean, head, legs, stand_hands, pole_down)

    def standing(t: float, kind: str) -> Pose:
        ph = 2 * math.pi * t
        if kind == "stand":   # корпус вперёд, колени чуть согнуты, ноги впереди таза
            return grounded(0.12, 32, 34, [(34, 36, 0), (26, 30, 0)])
        amp, knee, lean = (24, 40, 26) if kind == "walk" else (42, 85, 40)
        legs = []
        for phase in (0.0, math.pi):
            s_ = math.sin(ph + phase)
            c_ = math.cos(ph + phase)
            th = amp * s_ + (10 if kind == "run" else 4)
            kn = 8 + knee * max(0.0, c_) ** 1.5 + (15 if kind == "run" else 0)
            legs.append((th, kn, -15 * s_))
        return grounded(0.2, lean, lean * 0.75, legs)

    out = {"stand": [standing(0, "stand")]}
    out["walk"] = [standing(i / 24, "walk") for i in range(25)]
    out["run"] = [standing(i / 16, "run") for i in range(17)]
    fl_hands = [up(-0.3, -1), up(-0.3, 1)]
    out["flare"] = [Pose((0, -0.05, hip_z - 0.1), -8, -4, [(28, 12, 80), (22, 10, 80)],
                         fl_hands, Vector((0, -0.6, -1)))]
    # лёжа: тело подгоняется так, чтобы глаза совпали с pilot_eye
    lean, hl, legs = 84, HEAD_PRONE, [(0, 0, 10), (0, 0, 10)]
    p = Pose((0, 0, -1.36), lean, hl, legs, [bar(-1), bar(1)], Vector((0, -0.2, -1)), pod=1.0)
    e = eye_of(p)
    p = Pose(Vector((0, 0, -1.36)) + (eye - e), lean, hl, legs, [bar(-1), bar(1)],
             Vector((0, -0.2, -1)), pod=1.0)
    out["prone"] = [p]
    prone = p
    flare = out["flare"][0]
    # после отрыва ноги ещё «бегут в воздухе», шаги затихают (1,5 с)
    n = 36
    run_air = []
    for i in range(n + 1):
        t = i / n
        k = (1 - t) ** 1.5
        ph = 2 * math.pi * 1.5 * (t - 0.25 * t * t)   # шаги реже к концу
        legs = []
        for phase in (0.0, math.pi):
            s_, c_ = math.sin(ph + phase), math.cos(ph + phase)
            legs.append((8 + 40 * k * s_, 20 + 70 * k * max(0.0, c_) ** 1.5 + 10 * (1 - k),
                         90 - 12 * k * s_))
        run_air.append(Pose((0, 0.2, hip_z - 0.1 + 0.05 * t), 40 + 10 * t, 30, legs,
                            stand_hands, pole_down))
    out["run_air"] = run_air
    # заползание в кокон: корпус ложится, ноги подтягиваются назад в кокон, руки по очереди
    # перехватывают со стоек на базовую штангу (1,5 с)
    a0 = run_air[-1]
    climb = []
    for i in range(n + 1):
        t = i / n
        s_t = t * t * (3 - 2 * t)
        q = Pose.lerp(a0, prone, s_t, (_ease(t, 0.3, 0.6), _ease(t, 0.5, 0.85)))
        q.legs = [(lg[0], lg[1] + 55 * math.sin(math.pi * t), lg[2]) for lg in q.legs]
        climb.append(Pose(q.hips, q.lean, q.head_lean, q.legs, q.hands, q.pole,
                          _ease(t, 0.35, 1.0)))
    out["climb_in"] = climb
    # выход из кокона перед посадкой: ноги вниз, корпус вертикально, руки на стойки (1,5 с)
    out_ = []
    for i in range(n + 1):
        t = i / n
        s_t = t * t * (3 - 2 * t)
        q = Pose.lerp(prone, flare, s_t, (_ease(t, 0.1, 0.45), _ease(t, 0.3, 0.65)))
        q.legs = [(lg[0], lg[1] + 45 * math.sin(math.pi * t), lg[2]) for lg in q.legs]
        out_.append(Pose(q.hips, q.lean, q.head_lean, q.legs, q.hands, q.pole,
                         1.0 - _ease(t, 0.0, 0.6)))
    out["climb_out"] = out_
    return out


def _ease(t: float, t0: float, t1: float) -> float:
    x = min(max((t - t0) / (t1 - t0), 0.0), 1.0)
    return x * x * (3 - 2 * x)


def eye_of(p: Pose) -> Vector:
    head, hu, hf, _ = p.bones()["Head"]
    return head + hu * 0.12 + hf * EYE_FWD


# ------------------------------------------------------------------ геометрия (поза покоя)

def rest_pose() -> Pose:
    hip_z = -1.95 + THIGH + SHIN + 0.07
    neck = Vector((0, 0.2, hip_z + SPINE + CHEST))
    hands = [neck + Vector((s * 0.3, 0.02, -SHOULDER_DOWN - UPPER - FORE - HAND + 0.02))
             for s in (-1, 1)]
    return Pose((0, 0.2, hip_z), 0, 0, [(0, 0, 90), (0, 0, 90)], hands, Vector((0, -1, 0)))


def body_parts(rest: dict) -> list:
    """[(кость, MeshBuilder)] — части тела в позе покоя."""
    parts = []

    def part(bone):
        mb = U.MeshBuilder()
        parts.append((bone, mb))
        return mb

    h, u, f, _ = rest["Spine"]
    m = part("Hips")
    m.add_ellipsoid(h + u * 0.02, (0.17, 0.13, 0.12), "Pod", 14, 8)
    m = part("Spine")
    m.add_ellipsoid(h + u * 0.17, (0.16, 0.12, 0.15), "Pod", 14, 8)
    c, _, _, _ = rest["Chest"]
    m = part("Chest")
    m.add_ellipsoid(c + u * 0.1, (0.2, 0.12, 0.16), "Jacket", 16, 10)
    m.add_ellipsoid(c + u * 0.02 + f * 0.01, (0.19, 0.12, 0.12), "Pod", 14, 8)   # подвеска
    for s in (-1, 1):   # плечевые лямки
        m.add_tube([c + u * 0.02 + X * s * 0.1 + f * 0.13, c + u * 0.21 + X * s * 0.1 + f * 0.1,
                    c + u * 0.22 + X * s * 0.1 - f * 0.1], 0.02, "Strap", sides=6)
    for s, side in (("L", -1), ("R", 1)):
        a, d, _, _ = rest["UpperArm." + s]
        m = part("UpperArm." + s)
        m.add_ellipsoid(a, (0.07, 0.075, 0.07), "Jacket", 10, 6)
        m.add_tube([a, a + d * UPPER], [0.052, 0.045], "Jacket", sides=10)
        e, d, _, _ = rest["Forearm." + s]
        m = part("Forearm." + s)
        m.add_ellipsoid(e, (0.047, 0.047, 0.047), "Jacket", 8, 5)
        m.add_tube([e, e + d * FORE], [0.045, 0.036], "Jacket", sides=10)
        w, d, _, _ = rest["Hand." + s]
        m = part("Hand." + s)
        m.add_ellipsoid(w + d * 0.05, (0.045, 0.05, 0.06), "Glove", 10, 6,
                        Matrix((X, d.cross(X).normalized(), d)).transposed())
        hp, d, _, _ = rest["Thigh." + s]
        m = part("Thigh." + s)
        m.add_ellipsoid(hp, (0.085, 0.085, 0.085), "Pod", 8, 5)
        m.add_tube([hp, hp + d * THIGH], [0.085, 0.062], "Pod", sides=10)
        k, d, _, _ = rest["Shin." + s]
        m = part("Shin." + s)
        m.add_ellipsoid(k, (0.062, 0.062, 0.062), "Trousers", 8, 5)
        m.add_tube([k, k + d * (SHIN - 0.04)], [0.058, 0.045], "Trousers", sides=10)
        an, df, _, _ = rest["Foot." + s]
        m = part("Foot." + s)   # ботинок: голенище + носок + подошва
        m.add_tube([an + Vector((0, 0, 0.1)), an - Vector((0, 0, 0.02))], [0.05, 0.055], "Boot",
                   sides=10)
        m.add_ellipsoid(an + df * 0.08 - Vector((0, 0, 0.035)), (0.055, 0.13, 0.05), "Boot", 12, 7)
        m.add_box(an + df * 0.07 - Vector((0, 0, 0.078)), (0.1, 0.27, 0.02), "Sole")
    p, d, fz, _ = rest["PodTail"]
    m = part("PodTail")   # кокон ног: мешок, в полёте надет на ноги
    rings = []
    prof = [(0.0, 0.22, 0.16), (0.25, 0.22, 0.17), (0.55, 0.19, 0.15), (0.75, 0.17, 0.13),
            (0.9, 0.11, 0.09), (1.0, 0.02, 0.02)]
    side = d.cross(fz).normalized()
    up = side.cross(d).normalized()
    for t, rx, rz in prof:
        rings.append([p + d * (POD_LEN * t) + side * rx * math.cos(a) + up * rz * math.sin(a)
                      for a in [2 * math.pi * k / 14 for k in range(14)]])
    for i in range(len(rings) - 1):
        for k in range(14):
            k2 = (k + 1) % 14
            idx = [m.add_vert(rings[i][k]), m.add_vert(rings[i + 1][k]),
                   m.add_vert(rings[i + 1][k2]), m.add_vert(rings[i][k2])]
            stripe = abs(math.cos(2 * math.pi * (k + 0.5) / 14)) > 0.92 and 0 < i < 4
            m.add_face(idx, "Stripe" if stripe else "Pod")
    top = [m.add_vert(v) for v in rings[0]]
    m.add_face(list(reversed(top)), "Pod", smooth=False)
    a, d, _, ln = rest["Strap"]
    m = part("Strap")
    m.add_tube([a, a + d * ln], 0.012, "Strap", sides=6, ellipse=(2.0, 0.6))
    m.add_ellipsoid(a, (0.012, 0.03, 0.04), "Visor", 8, 5)
    return parts


def helmet(rest: dict, mb: U.MeshBuilder) -> None:
    n, hu, hf, _ = rest["Head"]
    hc = n + hu * 0.13
    mb.add_tube([n - hu * 0.05, hc], 0.055, "Jacket", sides=10)   # шея (прячется со шлемом)
    mb.add_ellipsoid(hc + hf * 0.01, (0.12, 0.14, 0.13), "Helmet", 14, 9)
    mb.add_ellipsoid(hc + hf * 0.06 - hu * 0.07, (0.075, 0.07, 0.07), "Skin", 10, 6)
    mb.add_ellipsoid(hc + hf * 0.11, (0.1, 0.035, 0.04), "Visor", 12, 6)


# ------------------------------------------------------------------ сборка

def merge(parts: list) -> tuple:
    mb = U.MeshBuilder()
    groups = {}
    for bone, p in parts:
        base = len(mb.verts)
        mb.verts += p.verts
        for f, uv, mat, sm in zip(p.faces, p.uvs, p.mats, p.smooth):
            mb.add_face([i + base for i in f], p.mat_names[mat], uv, sm)
        groups.setdefault(bone, []).extend(range(base, len(mb.verts)))
    return mb, groups


def skin(ob, arm, groups: dict) -> None:
    for bone, idx in groups.items():
        vg = ob.vertex_groups.new(name=bone)
        vg.add(idx, 1.0, "REPLACE")
    ob.parent = arm
    mod = ob.modifiers.new("Armature", "ARMATURE")
    mod.object = arm


def main() -> None:
    params = U.load_json("tools/blender/glider_params.json")
    cf = params["control_frame"]
    eye = Vector(params["pilot_eye"])
    U.reset_scene()
    bpy.context.scene.render.fps = FPS
    mats = {
        "Pod": U.material("Pod", U.srgb((0.10, 0.13, 0.22)), rough=0.7),
        "Stripe": U.material("PodStripe", U.srgb((0.95, 0.55, 0.05)), rough=0.6),
        "Jacket": U.material("Jacket", U.srgb((0.22, 0.24, 0.27)), rough=0.8),
        "Trousers": U.material("Trousers", U.srgb((0.16, 0.16, 0.17)), rough=0.85),
        "Boot": U.material("Boot", U.srgb((0.3, 0.2, 0.12)), rough=0.7),
        "Sole": U.material("Sole", U.srgb((0.08, 0.08, 0.08)), rough=0.9),
        "Helmet": U.material("Helmet", U.srgb((0.92, 0.92, 0.9)), rough=0.3),
        "Visor": U.material("Visor", U.srgb((0.05, 0.05, 0.07)), rough=0.1, metal=0.3),
        "Skin": U.material("Skin", U.srgb((0.85, 0.65, 0.52)), rough=0.6),
        "Glove": U.material("Glove", U.srgb((0.06, 0.06, 0.06)), rough=0.7),
        "Strap": U.material("Strap", U.srgb((0.15, 0.15, 0.15)), rough=0.7),
    }
    rest = rest_pose().bones()
    # скелет
    ad = bpy.data.armatures.new("Pilot")
    arm = bpy.data.objects.new("Pilot", ad)
    bpy.context.scene.collection.objects.link(arm)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode="EDIT")
    parent = {"Spine": "Hips", "Chest": "Spine", "Head": "Chest", "PodTail": "Hips"}
    for s in ("L", "R"):
        parent.update({"UpperArm." + s: "Chest", "Forearm." + s: "UpperArm." + s,
                       "Hand." + s: "Forearm." + s, "Thigh." + s: "Hips",
                       "Shin." + s: "Thigh." + s, "Foot." + s: "Shin." + s})
    for name, (h, d, zr, ln) in rest.items():
        eb = ad.edit_bones.new(name)
        m = bone_matrix(h, d, zr)
        eb.head = h
        eb.tail = h + d.normalized() * ln
        eb.align_roll(Vector(m.col[2][:3]))
    for name, par in parent.items():
        ad.edit_bones[name].parent = ad.edit_bones[par]
    bpy.ops.object.mode_set(mode="OBJECT")
    rest_m = {b.name: b.matrix_local.copy() for b in ad.bones}
    # меши
    mb, groups = merge(body_parts(rest))
    skin(mb.build("PilotBody", mats), arm, groups)
    hb = U.MeshBuilder()
    helmet(rest, hb)
    hob = hb.build("Helmet", mats)
    skin(hob, arm, {"Head": list(range(len(hb.verts)))})
    # пустышки на костях (в позе покоя)
    ad.pose_position = "REST"
    bpy.context.view_layer.update()
    n, hu, hf, _ = rest["Head"]
    rest_eye = n + hu * 0.12 + hf * EYE_FWD
    cam = rest_eye + rot_x(HEAD_PRONE) @ Vector((0, -0.25, 0.08))  # лёжа: 0,25 м сзади, 0,08 выше
    look = rot_x(HEAD_PRONE) @ hf
    marks = {"Head": ("Head", U.look_matrix(rest_eye, rest_eye + look)),
             "CockpitCamera": ("Head", U.look_matrix(cam, cam + rot_x(HEAD_PRONE + 10) @ hf))}
    for s, nm in (("L", "HandL"), ("R", "HandR")):
        w, d, _, _ = rest["Hand." + s]
        marks[nm] = ("Hand." + s, Matrix.Translation(w + d * HAND))
    for nm, (bone, mw) in marks.items():
        e = U.empty(nm, (0, 0, 0))
        e.parent = arm
        e.parent_type = "BONE"
        e.parent_bone = bone
        bpy.context.view_layer.update()
        e.matrix_world = mw
    ad.pose_position = "POSE"
    # анимации
    arm.animation_data_create()
    for aname, frames in poses(cf, eye).items():
        act = bpy.data.actions.new(aname)
        act.use_fake_user = True
        arm.animation_data.action = act
        for fi, pose in enumerate(frames):
            pm = {n: bone_matrix(h, d, zr, ln / ((rest[n][3]) or 1.0))
                  for n, (h, d, zr, ln) in pose.bones().items()}
            for name, m in pm.items():
                rm = rest_m[name]
                rmn = bone_matrix(rest[name][0], rest[name][1], rest[name][2])
                corr = rmn.inverted() @ rm   # поправка на крен кости, выставленный Blender
                mp = m @ corr
                par = parent.get(name)
                if par:
                    basis = (rest_m[par].inverted() @ rm).inverted() @ (
                        pm[par] @ (bone_matrix(rest[par][0], rest[par][1], rest[par][2])
                                   .inverted() @ rest_m[par])).inverted() @ mp
                else:
                    basis = rm.inverted() @ mp
                pb = arm.pose.bones[name]
                pb.rotation_mode = "QUATERNION"
                loc, rot, sc = basis.decompose()
                pb.location, pb.rotation_quaternion, pb.scale = loc, rot, sc
                for path in ("location", "rotation_quaternion", "scale"):
                    pb.keyframe_insert(path, frame=fi + 1)
        track = arm.animation_data.nla_tracks.new()
        track.name = aname
        track.strips.new(aname, 1, act)
        track.mute = True
    arm.animation_data.action = bpy.data.actions["prone"]
    os.makedirs(U.MODELS, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(U.SOURCE, "pilot.blend"),
                                check_existing=False, compress=True)
    bpy.ops.export_scene.gltf(filepath=os.path.join(U.MODELS, "pilot.glb"), export_format="GLB",
                              export_yup=True, export_animations=True,
                              export_animation_mode="ACTIONS", export_force_sampling=True,
                              export_skins=True, export_cameras=False, export_lights=False)
    print("EXPORTED pilot: %d tris, eye(prone) %s" % (U.tri_count(),
                                                      eye_of(poses(cf, eye)["prone"][0])))


if __name__ == "__main__":
    main()
