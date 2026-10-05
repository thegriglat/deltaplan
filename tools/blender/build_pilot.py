"""Пилот со скелетом и позами: assets/models/pilot.glb (+ assets/source/pilot.blend).

    tools/blender/setup_mpfb.sh      # один раз: MPFB 2 в отдельный каталог Blender
    BLENDER_USER_RESOURCES=~/.cache/deltaplan/blender_user \\
        blender --background --python tools/blender/build_pilot.py

Контракт (docs/guide/models.md → «Пилот»): начало координат = карабин (точка подвеса HangPoint крыла),
вперёд +Y Blender = −Z Godot. Скелет `Pilot` (Armature → Skeleton3D), меши PilotBody (тело,
подвеска, руки, ноги, ботинки, перчатки, кокон, фал) и Helmet (голова, шея и шлем — отдельно,
кабинная камера её прячет). Кости: Hips, Spine, Chest, Head, UpperArm.L/R, Forearm.L/R, Hand.L/R,
Thigh.L/R, Shin.L/R, Foot.L/R, PodTail (кокон ног), Strap (подвесной фал). Пустышки на костях: Head
(глаза), HandL/HandR (хват), CockpitCamera. Анимации: stand, walk, run, run_air, climb_in, prone,
climb_out, flare (docs/guide/models.md).

Тело — MakeHuman (MPFB 2, pilot_mpfb.py): мужчина ~30 лет, 1,78 м, с плавной привязкой к костям
(веса рига game_engine, слитые в наши 17 костей). Кулаки — кисти MPFB с пальцами, согнутыми вокруг
трубы, запечены в позу покоя (кисть — жёсткий кулак на кости Hand). Длины звеньев и суставы
скелета берутся с меша MPFB. Подвеска, кокон, фал, краги перчаток, шлем и визор — процедурные.

Позы задаются положением тела и углами суставов в пространстве модели; руки — двухзвенная IK к
точкам хвата на стойках/базовой штанге (из glider_params.json: трапеция средняя для трёх крыльев).
"""
import math
import os
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bl_util as U  # noqa: E402
import pilot_mpfb as M  # noqa: E402

FPS = 24
SOLE_T = 0.02           # толщина подошвы ботинка, м (нижняя подошва стоя — 2,0 м ниже карабина)
FOOT_Z = 0.015          # низ стопы MPFB над землёй, м (внутри подошвы; задаёт скелет и позы)
BOOT_TOP = 0.15         # верх голенища ботинка над землёй, м (ниже него стопы MPFB удаляются)
POD_LEN = 0.65          # кокон стоя (висит за ногами)
POD_ON = 1.45           # кокон лёжа (надет на ноги)
HEAD_PRONE = 20         # наклон головы лёжа, °: пустышки Head/CockpitCamera заданы так,
                        # что в позе prone взгляд горизонтален / на 10° вверх
FORE_TWIST = 0.5        # доля поворота кисти вокруг предплечья, которую берёт предплечье
PRONE_SPLAY = -0.6      # лёжа ноги сведены (в коконе), 1 — естественная стойка MPFB
# бюджет треугольников после прореживания (тело без кистей и головы / кисти / голова с шеей)
TRIS_BODY, TRIS_HANDS, TRIS_HEAD = 2700, 900, 420
X = Vector((1, 0, 0))


class D:
    """Размеры скелета, м и ° — подгоняются под меш MPFB (fit_dims)."""
    PELVIS, SPINE, CHEST, HEAD = 0.12, 0.16, 0.40, 0.26
    UPPER, FORE, HAND = 0.25, 0.27, 0.11
    THIGH, SHIN, FOOT = 0.43, 0.45, 0.15
    SHOULDER_X, SHOULDER_DOWN, SHOULDER_FWD = 0.19, 0.1, 0.0
    HIP_X, HIP_DOWN, HIP_FWD = 0.11, 0.0, 0.0
    SPLAY_TH, SPLAY_SH = 6.0, 6.0      # ноги врозь (от вертикали во фронтальной плоскости), °
    EYE_UP, EYE_FWD = 0.16, 0.09
    ANKLE_H = 0.09                      # голеностоп над подошвой
    BACK = 0.15                         # спина за осью позвоночника у крепления фала
    POD_BACK = 0.25                     # кокон стоя: центр за тазом


def rot_x(deg: float) -> Matrix:
    return Matrix.Rotation(math.radians(deg), 3, "X")


def rot_y(deg: float) -> Matrix:
    return Matrix.Rotation(math.radians(deg), 3, "Y")


def signed_angle(a: Vector, b: Vector, axis: Vector) -> float:
    """Угол от a к b вокруг axis (проекции на плоскость ⟂ axis), рад."""
    a = a - axis * a.dot(axis)
    b = b - axis * b.dot(axis)
    return math.atan2(axis.dot(a.cross(b)), a.dot(b))


class Pose:
    """Позиции суставов в пространстве модели. lean — наклон корпуса вперёд от вертикали, °
    (90 — лёжа), head_lean — наклон головы от вертикали, °; ноги: (бедро вперёд, сгиб колена, стопа)
    для L и R; hands — точки хвата; elbow_pole — куда отводить локти (вектор); grips — оси труб в
    кулаках (от мизинца к большому пальцу) для L и R: по ним кисть поворачивается вокруг предплечья,
    чтобы кулак обхватил штангу или стойку; splay — ноги врозь (1 — как стоит человек MPFB)."""
    twist0 = [0.0, 0.0]     # поворот кисти вокруг предплечья в позе покоя (rest_pose)

    def __init__(self, hips, lean, head_lean, legs, hands, elbow_pole, pod=0.0, grips=None,
                 splay=1.0):
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
        self.grips = [Vector(g).normalized() for g in (grips or [(0, 1, 0), (0, 1, 0)])]
        self.splay = splay
        self.twist = [0.0, 0.0]
        self.reach_gap = [0.0, 0.0]

    @staticmethod
    def lerp(a: "Pose", b: "Pose", t: float, hand_t=None) -> "Pose":
        """Промежуточная поза: параметры линейно; hand_t — своя доля для каждой руки."""
        ht = hand_t or (t, t)
        return Pose(a.hips.lerp(b.hips, t), a.lean + (b.lean - a.lean) * t,
                    a.head_lean + (b.head_lean - a.head_lean) * t,
                    [tuple(x + (y - x) * t for x, y in zip(la, lb))
                     for la, lb in zip(a.legs, b.legs)],
                    [a.hands[i].lerp(b.hands[i], ht[i]) for i in range(2)],
                    a.pole.lerp(b.pole, t), a.pod + (b.pod - a.pod) * t,
                    [a.grips[i].lerp(b.grips[i], ht[i]) for i in range(2)],
                    a.splay + (b.splay - a.splay) * t)

    def bones(self) -> dict:
        """{кость: (голова, направление, опорная ось Z, длина)} в пространстве модели."""
        b = {}
        h, u, f = self.hips, self.u, self.f
        chest = h + u * D.SPINE
        neck = chest + u * D.CHEST
        b["Hips"] = (h, u, f, D.PELVIS)
        b["Spine"] = (h, u, f, D.SPINE)
        b["Chest"] = (chest, u, f, D.CHEST)
        b["Head"] = (neck, self.hu, self.hf, D.HEAD)
        for i, (s, side) in enumerate((("L", -1), ("R", 1))):
            sh = neck - u * D.SHOULDER_DOWN + f * D.SHOULDER_FWD + X * side * D.SHOULDER_X
            elbow, grip, pn = two_bone(sh, self.hands[i], D.UPPER, D.FORE + D.HAND,
                                       self.pole + X * side * 0.6)
            self.reach_gap[i] = (self.hands[i] - grip).length
            d_up = (elbow - sh).normalized()
            d_fore = (grip - elbow).normalized()
            # крен плеча и предплечья — по плоскости сгиба локтя (локоть сгибается как у меша);
            # крен кисти: ось X кости — вдоль трубы в кулаке; часть поворота кисти вокруг
            # предплечья берёт предплечье (пронация), иначе запястье перекручивается
            hz = self.grips[i].cross(d_fore)
            self.twist[i] = signed_angle(-pn, hz, d_fore)
            dt = (self.twist[i] - Pose.twist0[i] + math.pi) % (2 * math.pi) - math.pi
            z_fore = Matrix.Rotation(dt * FORE_TWIST, 3, d_fore) @ -pn
            b["UpperArm." + s] = (sh, d_up, -pn, D.UPPER)
            b["Forearm." + s] = (elbow, d_fore, z_fore, D.FORE)
            b["Hand." + s] = (elbow + d_fore * D.FORE, d_fore, hz, D.HAND)
            thigh, knee, foot = self.legs[i]
            hip = h + X * side * D.HIP_X - u * D.HIP_DOWN + f * D.HIP_FWD
            sp = -side * self.splay
            d_th = rot_x(-self.lean + thigh) @ rot_y(sp * D.SPLAY_TH) @ Vector((0, 0, -1))
            kn = hip + d_th * D.THIGH
            d_sh = rot_x(-self.lean + thigh - knee) @ rot_y(sp * D.SPLAY_SH) @ Vector((0, 0, -1))
            an = kn + d_sh * D.SHIN
            d_ft = rot_x(-self.lean + thigh - knee + foot) @ Vector((0, 0, -1))
            b["Thigh." + s] = (hip, d_th, f, D.THIGH)
            b["Shin." + s] = (kn, d_sh, f, D.SHIN)
            b["Foot." + s] = (an, d_ft, -d_sh, D.FOOT)
        k = self.pod
        b["PodTail"] = (h - f * D.POD_BACK * (1 - k) - u * 0.02, -u, f,
                        POD_LEN + (POD_ON - POD_LEN) * k)
        attach = h + u * 0.28 - f * D.BACK
        b["Strap"] = (Vector((0, 0, -0.03)), (attach - Vector((0, 0, -0.03))).normalized(), -f,
                      (attach - Vector((0, 0, -0.03))).length)
        return b


def two_bone(a: Vector, target: Vector, l1: float, l2: float, pole: Vector):
    """Двухзвенная IK: плечо a, цель target. Возвращает (локоть, хват, ось к локтю ⟂ a→target)."""
    d = target - a
    dist = min(max(d.length, abs(l1 - l2) + 1e-3), l1 + l2 - 1e-3)
    dn = d.normalized()
    x = (dist * dist + l1 * l1 - l2 * l2) / (2 * dist)
    hgt = math.sqrt(max(l1 * l1 - x * x, 0.0))
    pn = (pole - dn * pole.dot(dn)).normalized()
    elbow = a + dn * x + pn * hgt
    grip = a + dn * dist
    return elbow, grip, pn


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
    # прежняя фиксированная трапеция (вершина 0,25 вперёд, база 0,90 вперёд / 1,55 ниже киля):
    # опорные позы анимации pilot.glb; в игре руки ставит PilotArmIK по маркерам модели крыла (A2)
    apex = Vector((0.04, 0.25, cf["keel_z_m"] - 0.05))
    bar = Vector((w, 0.90, cf["keel_z_m"] - 1.55))

    def upright(z: float, side: int) -> Vector:
        s = (apex.z - z) / (apex.z - bar.z)
        p = apex.lerp(bar, s)
        return Vector((side * p.x, p.y, p.z))

    def upright_axis(side: int) -> Vector:
        """Ось стойки снизу вверх (большие пальцы вверх)."""
        return (Vector((side * apex.x, apex.y, apex.z)) - Vector((side * bar.x, bar.y, bar.z))
                ).normalized()

    # на штанге хват сверху: большие пальцы внутрь, к центру
    return {"upright": upright, "bar": lambda side: Vector((side * 0.33, bar.y, bar.z)),
            "up_axis": [upright_axis(-1), upright_axis(1)],
            "bar_axis": [Vector((1, 0, 0)), Vector((-1, 0, 0))]}


def poses(cf: dict, eye: Vector) -> dict:
    g = grip_points(cf, eye)
    up, bar = g["upright"], g["bar"]
    ug, bg = g["up_axis"], g["bar_axis"]
    feet_z = -1.95
    hip_z = feet_z + D.THIGH + D.SHIN + 0.07
    pole_down = Vector((0, -0.3, -1))
    stand_hands = [up(-0.52, -1), up(-0.52, 1)]

    def grounded(hips_y: float, lean: float, head: float, legs: list) -> Pose:
        """Поза на земле: стопы горизонтально, нижняя подошва — на 2,0 м ниже карабина."""
        legs = [(th, kn, 90 + lean - th + kn + ft) for th, kn, ft in legs]
        p = Pose((0, hips_y, hip_z), lean, head, legs, stand_hands, pole_down, grips=ug)
        low = min(p.bones()["Foot." + s][0].z for s in ("L", "R"))
        return Pose((0, hips_y, hip_z - 2.0 + D.ANKLE_H - low), lean, head, legs, stand_hands,
                    pole_down, grips=ug)

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
                         fl_hands, Vector((0, -0.6, -1)), grips=ug)]
    # лёжа: тело подгоняется так, чтобы глаза совпали с pilot_eye
    lean, hl, legs = 84, HEAD_PRONE, [(0, 0, 10), (0, 0, 10)]
    p = Pose((0, 0, -1.36), lean, hl, legs, [bar(-1), bar(1)], Vector((0, -0.2, -1)), pod=1.0,
             grips=bg, splay=PRONE_SPLAY)
    e = eye_of(p)
    p = Pose(Vector((0, 0, -1.36)) + (eye - e), lean, hl, legs, [bar(-1), bar(1)],
             Vector((0, -0.2, -1)), pod=1.0, grips=bg, splay=PRONE_SPLAY)
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
                            stand_hands, pole_down, grips=ug))
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
                          _ease(t, 0.35, 1.0), q.grips, q.splay))
    out["climb_in"] = climb
    # выход из кокона перед посадкой: ноги вниз, корпус вертикально, руки на стойки (1,5 с)
    out_ = []
    for i in range(n + 1):
        t = i / n
        s_t = t * t * (3 - 2 * t)
        q = Pose.lerp(prone, flare, s_t, (_ease(t, 0.1, 0.45), _ease(t, 0.3, 0.65)))
        q.legs = [(lg[0], lg[1] + 45 * math.sin(math.pi * t), lg[2]) for lg in q.legs]
        out_.append(Pose(q.hips, q.lean, q.head_lean, q.legs, q.hands, q.pole,
                         1.0 - _ease(t, 0.0, 0.6), q.grips, q.splay))
    out["climb_out"] = out_
    return out


def _ease(t: float, t0: float, t1: float) -> float:
    x = min(max((t - t0) / (t1 - t0), 0.0), 1.0)
    return x * x * (3 - 2 * x)


def eye_of(p: Pose) -> Vector:
    head, hu, hf, _ = p.bones()["Head"]
    return head + hu * D.EYE_UP + hf * D.EYE_FWD


# ------------------------------------------------------------------ тело MPFB → наш скелет

# кость MPFB (без _l/_r) → материал области: подвеска (таз, низ живота, бёдра), куртка, брюки...
REGION = {"pelvis": "Pod", "spine_01": "Pod", "thigh": "Pod", "spine_02": "Jacket",
          "spine_03": "Jacket", "clavicle": "Jacket", "upperarm": "Jacket", "lowerarm": "Jacket",
          "neck_01": "Neck", "head": "Head", "calf": "Trousers", "foot": "Boot", "ball": "Boot",
          "hand": "Glove"}
# кость MPFB → {наша кость: доля}; шея гнётся пополам между грудью и головой
MERGE = {"pelvis": {"Hips": 1}, "spine_01": {"Spine": 1}, "spine_02": {"Chest": 1},
         "spine_03": {"Chest": 1}, "neck_01": {"Head": 0.6, "Chest": 0.4}, "head": {"Head": 1}}
for _s, _S in (("l", "L"), ("r", "R")):
    MERGE.update({"clavicle_" + _s: {"Chest": 1}, "upperarm_" + _s: {"UpperArm." + _S: 1},
                  "lowerarm_" + _s: {"Forearm." + _S: 1}, "hand_" + _s: {"Hand." + _S: 1},
                  "thigh_" + _s: {"Thigh." + _S: 1}, "calf_" + _s: {"Shin." + _S: 1},
                  "foot_" + _s: {"Foot." + _S: 1}, "ball_" + _s: {"Foot." + _S: 1}})
    for _f in M.FINGERS + ("thumb",):
        for _i in (1, 2, 3):
            MERGE["%s_0%d_%s" % (_f, _i, _s)] = {"Hand." + _S: 1}


def region(name: str) -> str:
    base = name[:-2] if name.endswith(("_l", "_r")) else name
    if base.split("_")[0] in M.FINGERS + ("thumb",):
        return "Glove"
    return REGION.get(base, "Jacket")


def vregion(w: dict) -> str:
    """Область вершины по весам MPFB (перчатка — если вес кисти и пальцев ≥ GLOVE_W)."""
    if not w:
        return "Pod"
    if sum(x for k, x in w.items() if region(k) == "Glove") >= GLOVE_W:
        return "Glove"
    return region(max(w, key=w.get))


def mpfb_body():
    """Человек MPFB с кулаками → (объект-меш в наших осях, веса MPFB по вершинам, суставы, оси
    трубы в кулаках, HAND)."""
    h, rig = M.make_human()
    fists = M.make_fists(h, rig, GRIP_R)
    eye = M.eye_center(h)
    pb = rig.pose.bones
    joints = {n: pb[n].head.copy() for n in (
        "pelvis", "spine_02", "neck_01", "upperarm_l", "lowerarm_l", "hand_l", "thigh_l",
        "calf_l", "foot_l")}
    me = M.evaluated_mesh(h)
    names = {g.index: g.name for g in h.vertex_groups}
    bones = {b.name for b in rig.data.bones}
    wts = [{names[g.group]: g.weight for g in v.groups
            if names.get(g.group) in bones and g.weight > 1e-4} for v in me.vertices]
    for ob in (h, rig):
        bpy.data.objects.remove(ob)
    # MPFB лицом к −Y → к +Y; таз на y = 0,2, низ стоп — на FOOT_Z выше −2,0 (в подошве ботинка)
    zmin = min(v.co.z for v in me.vertices)
    rz = Matrix.Rotation(math.pi, 4, "Z")
    p = rz @ joints["pelvis"]
    mt = Matrix.Translation((-p.x, 0.2 - p.y, -2.0 + FOOT_Z - zmin)) @ rz
    me.transform(mt)
    for k in joints:
        joints[k] = mt @ joints[k]
    joints["eye"] = mt @ eye
    joints["sole"] = -2.0
    axes = {s: (mt.to_3x3() @ a).normalized() for s, (a, _, _) in fists.items()}
    hand = sum(hd for _, hd, _ in fists.values()) / 2
    print("FIST clearance: %s" % {s: round(c, 4) for s, (_, _, c) in fists.items()})
    for uv in me.uv_layers[1:]:
        me.uv_layers.remove(uv)
    if me.uv_layers:
        me.uv_layers[0].name = "UVMap"
    ob = bpy.data.objects.new("PilotBodySrc", me)
    bpy.context.scene.collection.objects.link(ob)
    return ob, wts, joints, axes, hand


def fit_dims(j: dict, pts: list, reg: list, hand: float) -> tuple:
    """Длины звеньев и смещения суставов по суставам MPFB (наши оси, поза покоя). Возвращает
    параметры позы покоя (lean, ноги, точки хвата, полюс локтей)."""
    p, s2, nk = j["pelvis"], j["spine_02"], j["neck_01"]
    u = (nk - p).normalized()
    lean = math.degrees(math.atan2(u.y, u.z))
    f = rot_x(-lean) @ Vector((0, 1, 0))
    D.SPINE = (s2 - p).dot(u)
    D.CHEST = (nk - p).length - D.SPINE
    top = max(v.z for v, r in zip(pts, reg) if r == "Head")
    D.HEAD = top - nk.z
    e = j["eye"] - nk
    D.EYE_UP, D.EYE_FWD = e.z, e.y + 0.012          # перед глазного яблока
    sh, el, wr = j["upperarm_l"], j["lowerarm_l"], j["hand_l"]
    r = sh - nk
    D.SHOULDER_X, D.SHOULDER_DOWN, D.SHOULDER_FWD = abs(r.x), -r.dot(u), r.dot(f)
    D.UPPER = (el - sh).length
    D.FORE = (wr - el).length
    D.HAND = hand
    hp, kn, an = j["thigh_l"], j["calf_l"], j["foot_l"]
    r = hp - p
    D.HIP_X, D.HIP_DOWN, D.HIP_FWD = abs(r.x), -r.dot(u), r.dot(f)
    D.THIGH = (kn - hp).length
    D.SHIN = (an - kn).length
    D.ANKLE_H = an.z - j["sole"]
    dth = (kn - hp).normalized()
    dsh = (an - kn).normalized()
    D.SPLAY_TH = math.degrees(math.asin(abs(dth.x)))
    D.SPLAY_SH = math.degrees(math.asin(abs(dsh.x)))
    a_th = math.degrees(math.atan2(dth.y, -dth.z))
    a_sh = math.degrees(math.atan2(dsh.y, -dsh.z))
    th = a_th + lean
    legs = [(th, a_th - a_sh, 90 - a_sh)] * 2
    # спина у крепления фала и таз сзади — по мешу
    z_att = p.z + 0.28 * u.z
    back = [v.y for v in pts if abs(v.z - z_att) < 0.02 and abs(v.x) < 0.06]
    D.BACK = p.y + 0.28 * u.y - min(back) + 0.035
    # точки хвата и полюс, при которых two_bone ставит локти в локти MPFB
    fore = (wr - el).normalized()
    g_l = wr + fore * hand
    g_r = Vector((-g_l.x, g_l.y, g_l.z))
    dn = (g_l - sh).normalized()
    v = (el - sh) - dn * (el - sh).dot(dn)
    k = -0.6 / v.x
    pole = Vector((0, k * v.y, k * v.z))
    print("DIMS " + ", ".join("%s %.3f" % (n, getattr(D, n)) for n in dir(D) if n.isupper()))
    print("DIMS lean %.1f°, ноги %s" % (lean, legs[0]))
    return lean, legs, [g_l, g_r], pole, el


def rest_pose(rest_args) -> Pose:
    lean, legs, hands, pole, grips = rest_args
    return Pose(REST_HIPS, lean, 0, legs, hands, pole, grips=grips)


# ------------------------------------------------------------------ перчатки, подвеска, шлем

GLOVE_W = 0.3          # грань — перчатка, если средний вес кисти и пальцев не меньше
GRIP_R = 0.0205        # внутренний радиус кулака, м: базовая штанга 0,017, стойка 0,019


def glove_frame(bone: tuple, side: int):
    """(запястье, a, w, b) — оси перчатки в позе покоя; side −1 — левая, +1 — правая."""
    wr, d, zr, _ = bone
    y = d.normalized()
    x = y.cross(zr).normalized()         # = ось X кости (bone_matrix) = ось трубы
    bk = y.cross(x) * side               # тыл кисти: у правой y×T, у левой T×y
    return wr, y, x, bk


def glove_pt(fr, a: float, w: float, b: float) -> Vector:
    wr, y, x, bk = fr
    return wr + y * a + x * w + bk * b


def loft(mb: U.MeshBuilder, fr, rings: list, mat: str, sides: int = 10, cap: bool = True) -> None:
    """Эллиптические кольца вдоль кисти: rings = [(a, b центра, полуширина по w, полутолщина)]."""
    _, y, x, bk = fr
    pts = []
    for a, bc, hw, hb in rings:
        c = glove_pt(fr, a, 0.0, bc)
        pts.append([c + x * hw * math.cos(2 * math.pi * k / sides)
                    + bk * hb * math.sin(2 * math.pi * k / sides) for k in range(sides)])
    base = len(mb.verts)
    for ring in pts:
        for v in ring:
            mb.add_vert(v)
    # грани наружу при любой руке: нормаль первого четырёхугольника — от оси
    q0 = [pts[0][0], pts[1][0], pts[1][1]]
    c0 = glove_pt(fr, rings[0][0], 0.0, rings[0][1])
    flip = (q0[1] - q0[0]).cross(q0[2] - q0[0]).dot(q0[0] - c0) < 0
    for i in range(len(pts) - 1):
        for k in range(sides):
            k2 = (k + 1) % sides
            q = [base + i * sides + k, base + (i + 1) * sides + k,
                 base + (i + 1) * sides + k2, base + i * sides + k2]
            mb.add_face(list(reversed(q)) if flip else q, mat)
    for i, rev in ((0, not flip), (len(pts) - 1, flip)) if cap else ():
        idx = [base + i * sides + k for k in range(sides)]
        mb.add_face(list(reversed(idx)) if rev else idx, mat, smooth=False)


def cuff(mb: U.MeshBuilder, bone: tuple, side: int, pts: list, glove: list) -> None:
    """Краг-раструб перчатки поверх рукава (~7 см вверх от начала перчатки) и ремешок-липучка:
    сечения обнимают меш руки с зазором, к локтю расширяются. Жёстко на кости Hand."""
    fr = glove_frame(bone, side)
    wr, y, x, bk = fr
    a1 = min((p - wr).dot(y) for p in glove) + 0.014
    st = [a1 - 0.082 + 0.082 * i / 5 for i in range(6)]
    rings = []
    for a in st:
        near = [p - wr for p in pts if abs((p - wr).dot(y) - a) < 0.007]
        hw = max(abs(q.dot(x)) for q in near) + 0.004
        hb = max(abs(q.dot(bk)) for q in near) + 0.004
        rings.append([a, 0.0, hw, hb])
    for i in range(len(rings) - 2, -1, -1):    # раструб: к локтю не уже, чем ближе к кисти
        rings[i][2] = max(rings[i][2], rings[i + 1][2] - 0.001)
        rings[i][3] = max(rings[i][3], rings[i + 1][3] - 0.001)
    rings[0][2] += 0.005
    rings[0][3] += 0.005
    loft(mb, fr, [tuple(r) for r in rings], "Glove", sides=12, cap=False)
    r1, r2 = rings[1], rings[2]
    loft(mb, fr, [(r1[0] + 0.004, 0.0, r1[2] + 0.0015, r1[3] + 0.0015),
                  (r2[0] + 0.003, 0.0, r2[2] + 0.0015, r2[3] + 0.0015)], "GlovePanel", sides=12,
         cap=False)
    print("CUFF: краг от %.3f до %.3f м вдоль кисти" % (st[0], st[-1]))


def cuff_clearance(pts: list, bone: tuple) -> float:
    """Наименьшее расстояние от вершин кулака до оси трубы, м — для проверки."""
    wr, d, zr, _ = bone
    x = d.cross(zr).normalized()
    c = wr + d * D.HAND
    best = 1.0
    for p in pts:
        dv = p - c
        best = min(best, (dv - x * dv.dot(x)).length)
    return best


def surf_y(pts: list, x: float, z: float, tol: float = 0.015) -> tuple:
    """(зад, перед) поверхности тела по y в точке (x, z)."""
    ys = [p.y for p in pts if abs(p.x - x) < tol and abs(p.z - z) < tol]
    return min(ys), max(ys)


def harness(rest: dict, pts: list, reg: list, parts: list, wts: list, waist_z: float) -> None:
    """Подвеска: плечевые лямки, грудная перемычка, пояс, спинка с креплением фала, кокон, фал."""
    def part(bone):
        mb = U.MeshBuilder()
        parts.append((bone, mb))
        return mb

    h, u, f, _ = rest["Spine"]
    c, _, _, _ = rest["Chest"]
    nk = rest["Head"][0]
    m = part("Chest")
    z1 = c.z + 0.04
    z2 = nk.z - 0.05
    straps = []
    for s in (-1, 1):
        xs = 0.095 * s
        b1, f1 = surf_y(pts, xs, z1)
        b2, f2 = surf_y(pts, xs, z2)
        top = max(p.z for p in pts if abs(p.x - xs) < 0.012 and abs(p.y - nk.y) < 0.03
                  and p.z < nk.z + 0.05)
        straps.append(f1)
        m.add_tube([Vector((xs, f1 + 0.012, z1 - 0.06)), Vector((xs, f1 + 0.012, z1)),
                    Vector((xs, f2 + 0.016, z2)), Vector((xs, nk.y + 0.005, top + 0.022)),
                    Vector((xs, b2 - 0.018, z2)), Vector((xs, b1 - 0.014, z1))],
                   0.011, "Strap", sides=6, ellipse=(0.6, 2.0), up=(1, 0, 0))
    _, fc = surf_y(pts, 0.0, z1 - 0.02)
    m.add_tube([Vector((-0.095, straps[0] + 0.012, z1 - 0.02)),
                Vector((0, fc + 0.012, z1 - 0.02)),
                Vector((0.095, straps[1] + 0.012, z1 - 0.02))], 0.01, "Strap", sides=6,
               ellipse=(0.6, 2.0), up=(0, 0, 1))
    # пояс подвески по краю (закрывает переход подвеска → куртка)
    m = part("Spine")
    ring = [p for p, w in zip(pts, wts) if abs(p.z - waist_z) < 0.012 and w and not max(
        w, key=w.get).startswith(("upperarm", "lowerarm", "hand", "clavicle"))
        and region(max(w, key=w.get)) != "Glove"]
    cy = (max(p.y for p in ring) + min(p.y for p in ring)) / 2
    bx = max(abs(p.x) for p in ring) + 0.008
    by = (max(p.y for p in ring) - min(p.y for p in ring)) / 2 + 0.008
    m.add_tube([Vector((0, cy, waist_z - 0.022)), Vector((0, cy, waist_z + 0.022))], bx, "Strap",
               sides=16, ellipse=(1.0, by / bx), cap=False, up=(0, 1, 0))
    # спинка подвески (жёсткая, с креплением фала)
    m = part("Spine")
    zc = h.z + 0.2
    bk, _ = surf_y(pts, 0.0, zc, 0.03)
    wid = max(abs(p.x) for p in pts if abs(p.z - zc) < 0.02 and p.y < h.y)
    m.add_ellipsoid(Vector((0, bk - 0.02, zc)), (wid * 0.85, 0.05, 0.22), "Pod", 12, 7)
    # кокон ног: мешок, в полёте надет на ноги
    hips = [p for p, r in zip(pts, reg) if abs(p.z - h.z) < 0.03 and r == "Pod"]
    rx = max(abs(p.x) for p in hips) + 0.035
    rzz = (max(p.y for p in hips) - min(p.y for p in hips)) / 2 + 0.03
    p, d, fz, _ = rest["PodTail"]
    m = part("PodTail")
    rings = []
    prof = [(0.0, 1.0, 1.0), (0.25, 1.0, 1.06), (0.55, 0.86, 0.94), (0.75, 0.77, 0.81),
            (0.9, 0.5, 0.56), (1.0, 0.09, 0.12)]
    side = d.cross(fz).normalized()
    upv = side.cross(d).normalized()
    for t, kx, kz in prof:
        rings.append([p + d * (POD_LEN * t) + side * rx * kx * math.cos(a)
                      + upv * rzz * kz * math.sin(a)
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


# ------------------------------------------------------------------ ботинки

def _hull(pts2: list) -> list:
    """Выпуклая оболочка точек (x, y), против часовой стрелки."""
    pts2 = sorted(set(pts2))

    def half(seq):
        out = []
        for q in seq:
            while len(out) > 1 and ((out[-1][0] - out[-2][0]) * (q[1] - out[-2][1])
                                    - (out[-1][1] - out[-2][1]) * (q[0] - out[-2][0])) <= 0:
                out.pop()
            out.append(q)
        return out[:-1]
    return half(pts2) + half(reversed(pts2))


def _contour(hull: list, margin: float, n: int) -> list:
    """Оболочка, раздутая на margin, → n точек поровну по длине, с пятки (−Y), против ч. с."""
    k = len(hull)
    dense = []
    for i in range(k):
        a, b = Vector(hull[i]), Vector(hull[(i + 1) % k])
        m = max(1, int((b - a).length / 0.004))
        dense += [a.lerp(b, t / m) for t in range(m)]
    k = len(dense)
    out = []
    for i in range(k):
        t = dense[(i + 1) % k] - dense[i - 1]
        out.append(dense[i] + Vector((t.y, -t.x)).normalized() * margin)
    c = sum(out, Vector((0, 0))) / k
    i0 = min(range(k), key=lambda i: (out[i] - c).normalized().dot(Vector((0, 1))))
    out = out[i0:] + out[:i0] + [out[i0]]
    cum = [0.0]
    for i in range(1, len(out)):
        cum.append(cum[-1] + (out[i] - out[i - 1]).length)
    res, j = [], 0
    for q in range(n):
        d = cum[-1] * q / n
        while cum[j + 1] < d:
            j += 1
        t = (d - cum[j]) / ((cum[j + 1] - cum[j]) or 1.0)
        res.append(out[j].lerp(out[j + 1], t))
    return res


def boots(pts: list, rest: dict) -> list:
    """Ботинки: голенище-оболочка вокруг стопы MPFB по контурам на высотах (носок закрыт, пальцев
    нет) и резиновая подошва по контуру стопы (шире верха на 5 мм). Стопа MPFB ниже верха голенища
    удаляется (delete_feet). → [(кость, MeshBuilder, веса вершин)]."""
    g0 = -2.0
    n = 14
    # (высота кольца над землёй, полоса точек стопы для контура, запас)
    rings = [(SOLE_T, (FOOT_Z, 0.045), 0.009), (SOLE_T + 0.008, (FOOT_Z, 0.045), 0.004),
             (0.045, (0.035, 0.065), 0.005), (0.07, (0.06, 0.1), 0.005),
             (0.105, (0.09, 0.13), 0.006), (BOOT_TOP, (BOOT_TOP - 0.02, BOOT_TOP + 0.02), 0.006),
             (BOOT_TOP - 0.012, (BOOT_TOP - 0.02, BOOT_TOP + 0.02), 0.0)]
    out = []
    for s, side in (("L", -1), ("R", 1)):
        ankle = rest["Foot." + s][0].z
        mb = U.MeshBuilder()
        wts = []
        cont = []
        for h, (b0, b1), mg in rings:
            band = [(p.x, p.y) for p in pts if p.x * side > 0 and g0 + b0 <= p.z <= g0 + b1]
            cont.append([Vector((q.x, q.y, g0 + h)) for q in _contour(_hull(band), mg, n)])
        # подошва: борт (низ на 2 мм уже — скруглённое ребро) и низ; верх подошвы = первое кольцо
        c0 = sum(cont[0], Vector()) / n
        low = [Vector((q.x, q.y, g0)) - (q - c0).normalized() * 0.002 for q in cont[0]]
        mb.add_grid([low, cont[0]], "Sole", wrap=True, flip=True)
        wts += [{"Foot." + s: 1.0}] * (2 * n)
        base = len(mb.verts)
        for q in low:
            mb.add_vert(q)
        wts += [{"Foot." + s: 1.0}] * n
        mb.add_face([base + k for k in reversed(range(n))], "Sole", smooth=False)
        # верх: кольца от ранта до верха голенища и внутренний край
        mb.add_grid(cont, "Boot", wrap=True, flip=True)
        for r in cont:
            for q in r:
                t = min(max((q.z - ankle) / 0.05, 0.0), 1.0) * 0.85
                wts.append({"Foot." + s: 1.0 - t, "Shin." + s: t} if t > 0 else
                           {"Foot." + s: 1.0})
        out.append(("Foot." + s, mb, wts))
    return out


def delete_feet(ob) -> None:
    """Удалить стопы MPFB внутри ботинок (грани целиком ниже верха голенища − 2,5 см)."""
    zc = -2.0 + BOOT_TOP - 0.025
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    dead = [f for f in bm.faces if all(v.co.z < zc for v in f.verts)]
    bmesh.ops.delete(bm, geom=dead, context="FACES")
    bm.to_mesh(ob.data)
    bm.free()
    print(f"BOOTS: удалено {len(dead)} граней стоп MPFB")


def helmet(rest: dict, pts: list, reg: list, mb: U.MeshBuilder) -> None:
    """Шлем по черепу MPFB (открытое лицо) и визор, закрывающий глазницы (глаз у меша нет)."""
    n, hu, hf, _ = rest["Head"]
    eye = n + hu * D.EYE_UP + hf * (D.EYE_FWD - 0.012)
    head = [p for p, r in zip(pts, reg) if r == "Head"]
    skull = [p for p in head if p.z > eye.z + 0.02 or p.y < eye.y - 0.07]
    lo = Vector([min(p[i] for p in skull) for i in range(3)])
    hi = Vector([max(p[i] for p in skull) for i in range(3)])
    c = (lo + hi) / 2
    r = (hi - lo) / 2
    k = max(math.sqrt(sum(((p[i] - c[i]) / r[i]) ** 2 for i in range(3))) for p in skull)
    rad = Vector((r.x * k + 0.02, r.y * k + 0.02, r.z * k + 0.02))

    def on(rv: Vector, th: float, ph: float) -> Vector:
        return c + Vector((rv.x * math.sin(th) * math.sin(ph), rv.y * math.sin(th) * math.cos(ph),
                           rv.z * math.cos(th)))

    def theta(rv: Vector, z: float) -> float:
        return math.acos(min(max((z - c.z) / rv.z, -1.0), 1.0))

    th_brow = theta(rad, eye.z + 0.028)
    th_low = theta(rad, eye.z - 0.075)
    face = math.radians(52)
    nt, nph = 9, 20
    grid = [[on(rad, th_low * i / nt, 2 * math.pi * j / nph) for j in range(nph)]
            for i in range(nt + 1)]

    def keep(i, j):
        ph = 2 * math.pi * (j + 0.5) / nph
        ph = ph - 2 * math.pi if ph > math.pi else ph
        return not (abs(ph) < face and th_low * (i + 0.5) / nt > th_brow)

    shell(mb, grid, keep, c, "Helmet", wrap=True)
    # визор: полоса перед лицом от брови до кончика носа, с запасом над лицом
    band = [p for p in head if eye.z - 0.05 < p.z < eye.z + 0.035 and p.y > eye.y - 0.04]
    kv = max(math.sqrt(sum(((p[i] - c[i]) / rad[i]) ** 2 for i in range(3))) for p in band)
    rv = rad * 1.0
    rv.y = rad.y * max(kv, 1.0) + 0.008
    rv.x = rad.x * max(kv, 1.0) * 1.03
    # изогнутый щиток по сфере шлема: сверху заходит на край шлема, по центру ниже носа, к бокам
    # сужается к шарнирам (кнопки на висках)
    t0, t1 = theta(rv, eye.z + 0.05), theta(rv, eye.z - 0.068)
    ph_max = face + 0.38
    nr, nc = 4, 14
    grid = []
    for i in range(nr + 1):
        row = []
        for j in range(nc + 1):
            ph = -ph_max + 2 * ph_max * j / nc
            tb = t0 + (t1 - t0) * (0.42 + 0.58 * math.cos(abs(ph) / ph_max * math.pi / 2) ** 0.8)
            row.append(on(rv, t0 + (tb - t0) * i / nr, ph))
        grid.append(row)
    shell(mb, grid, lambda i, j: True, c, "Visor", wrap=False)
    tm = t0 + (t1 - t0) * 0.21
    for sd in (-1, 1):
        mb.add_ellipsoid(c + (on(rv * 1.02, tm, sd * ph_max) - c), (0.006, 0.013, 0.013),
                         "Strap", 6, 4)


def shell(mb: U.MeshBuilder, grid: list, keep, c: Vector, mat: str, wrap: bool) -> None:
    """Оболочка из сетки точек (общие вершины — гладкая), грани нормалью от точки c."""
    idx = {}

    def vi(i, j):
        if (i, j) not in idx:
            idx[(i, j)] = mb.add_vert(grid[i][j])
        return idx[(i, j)]

    ncol = len(grid[0])
    for i in range(len(grid) - 1):
        for j in range(ncol if wrap else ncol - 1):
            if not keep(i, j):
                continue
            j2 = (j + 1) % ncol
            q = [(i, j), (i, j2), (i + 1, j2), (i + 1, j)]
            vs = [grid[a][b] for a, b in q]
            nrm = (vs[1] - vs[0]).cross(vs[2] - vs[0]) + (vs[2] - vs[0]).cross(vs[3] - vs[0])
            if nrm.dot(sum(vs, Vector()) / 4 - c) < 0:
                q.reverse()
            mb.add_face([vi(a, b) for a, b in q], mat)


# ------------------------------------------------------------------ сборка

def split_parts(src, wts: list, groups: dict) -> dict:
    """Меш MPFB → {часть: объект} (тело, кисти, голова с шеей) с нашими весами и материалами."""
    mats = ["Pod", "Jacket", "Trousers", "Boot", "Glove", "Skin"]
    me = src.data
    me.materials.clear()
    for mn in mats:
        me.materials.append(groups["mats"][mn])
    part_of = []
    for poly in me.polygons:
        acc = {}
        for vi in poly.vertices:
            for k, w in wts[vi].items():
                acc[k] = acc.get(k, 0.0) + w
        reg = region(max(acc, key=acc.get)) if acc else "Pod"
        if sum(w for k, w in acc.items() if region(k) == "Glove") >= GLOVE_W * len(poly.vertices):
            reg = "Glove"
        elif reg in ("Pod", "Jacket", "Trousers") and not max(acc, key=acc.get).startswith(
                ("upperarm", "lowerarm", "clavicle")):
            # подвеска до пояса и до колен — ровный край (пояс закрывает шов)
            z = poly.center.z
            if max(acc, key=acc.get).startswith(("thigh", "calf")):
                reg = "Pod" if z > groups["knee_z"] else "Trousers"
            else:
                reg = "Pod" if z < groups["waist_z"] else "Jacket"
        mat = {"Head": "Skin", "Neck": "Jacket"}.get(reg, reg)
        poly.material_index = mats.index(mat)
        part_of.append("hands" if reg == "Glove" else "head" if reg in ("Head", "Neck")
                       else "body")
    # наши группы вершин
    for vg in list(src.vertex_groups):
        src.vertex_groups.remove(vg)
    vgs = {b: src.vertex_groups.new(name=b) for b in groups["bones"]}
    for vi, wd in enumerate(wts):
        acc = {}
        for k, w in wd.items():
            for b, share in MERGE.get(k, {}).items():
                acc[b] = acc.get(b, 0.0) + w * share
        top = sorted(acc.items(), key=lambda kv: -kv[1])[:4]
        tot = sum(w for _, w in top) or 1.0
        for b, w in top:
            vgs[b].add([vi], w / tot, "REPLACE")
    out = {}
    for name in ("body", "hands", "head"):
        ob = src.copy()
        ob.data = src.data.copy()
        ob.name = "part_" + name
        bpy.context.scene.collection.objects.link(ob)
        bm = bmesh.new()
        bm.from_mesh(ob.data)
        bm.faces.ensure_lookup_table()
        bmesh.ops.delete(bm, geom=[fc for fc in bm.faces if part_of[fc.index] != name],
                         context="FACES")
        bm.to_mesh(ob.data)
        bm.free()
        out[name] = ob
    bpy.data.objects.remove(src)
    return out


def tris(ob) -> int:
    return sum(len(p.vertices) - 2 for p in ob.data.polygons)


def decimate(ob, target: int) -> None:
    mod = ob.modifiers.new("Decimate", "DECIMATE")
    mod.ratio = min(1.0, target / max(tris(ob), 1))
    mod.use_symmetry = True
    mod.symmetry_axis = "X"
    bpy.context.view_layer.objects.active = ob
    bpy.ops.object.modifier_apply(modifier=mod.name)


def cap_neck(ob, nk: Vector, mb: U.MeshBuilder) -> None:
    """Закрыть горловину тела (голова — отдельный меш Helmet, в кабине он скрыт) и надеть на
    шов воротник куртки (по краю горловины, жёстко на Chest)."""
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    edges = [e for e in bm.edges if e.is_boundary and all(
        v.co.z > nk.z - 0.12 and abs(v.co.x) < 0.15 for v in e.verts)]
    ring = {v.index: v.co.copy() for e in edges for v in e.verts}.values()
    # обход края горловины по порядку → одна n-угольная крышка
    nxt = {}
    for e in edges:
        a, b = e.verts
        nxt.setdefault(a, []).append(b)
        nxt.setdefault(b, []).append(a)
    start = max(nxt, key=lambda v: v.co.z)
    loop, prev, cur = [start], None, start
    while True:
        cand = [v for v in nxt[cur] if v is not prev]
        if not cand or cand[0] is start:
            break
        prev, cur = cur, cand[0]
        loop.append(cur)
    faces = []
    if len(loop) == len(nxt):
        fc = bm.faces.new(loop)
        fc.normal_update()
        if fc.normal.z < 0:
            fc.normal_flip()
        fc.material_index = ob.data.materials.find("Jacket")
        fc.smooth = False
        faces.append(fc)
    bm.to_mesh(ob.data)
    bm.free()
    cx = (max(p.x for p in ring) + min(p.x for p in ring)) / 2
    cy = (max(p.y for p in ring) + min(p.y for p in ring)) / 2
    rx = (max(p.x for p in ring) - min(p.x for p in ring)) / 2 + 0.008
    ry = (max(p.y for p in ring) - min(p.y for p in ring)) / 2 + 0.008
    z0, z1 = min(p.z for p in ring), max(p.z for p in ring)
    mb.add_tube([Vector((cx, cy, z0 - 0.015)), Vector((cx, cy, (z0 + z1) / 2)),
                 Vector((cx, cy, z1 + 0.012))], [rx + 0.012, rx + 0.004, rx],
                "Jacket", sides=14, ellipse=(1.0, ry / rx), cap=False, up=(0, 1, 0))
    print("CAP край %d вершин, обход %d; горловина: %d граней, воротник %.3f×%.3f м, высота %.3f м"
          % (len(nxt), len(loop), len(faces), rx, ry, z1 - z0 + 0.027))


def join(objs: list, name: str):
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.object.join()
    ob = objs[0]
    ob.name = ob.data.name = name
    return ob


def build_parts(parts: list, name: str, mats: dict):
    """[(кость, MeshBuilder[, веса вершин])] → объект с группами вершин по костям."""
    mb = U.MeshBuilder()
    groups = {}
    for bone, p, *vw in parts:
        base = len(mb.verts)
        mb.verts += p.verts
        for f, uv, mat, sm in zip(p.faces, p.uvs, p.mats, p.smooth):
            mb.add_face([i + base for i in f], p.mat_names[mat], uv, sm)
        wl = vw[0] if vw else [{bone: 1.0}] * len(p.verts)
        for i, wd in enumerate(wl):
            for b, w in wd.items():
                groups.setdefault(b, []).append((base + i, w))
    ob = mb.build(name, mats)
    for bone, lst in groups.items():
        vg = ob.vertex_groups.new(name=bone)
        for i, w in lst:
            vg.add([i], w, "REPLACE")
    return ob


def skin(ob, arm) -> None:
    ob.parent = arm
    mod = ob.modifiers.new("Armature", "ARMATURE")
    mod.object = arm


REST_HIPS = Vector((0, 0.2, 0))


def main() -> None:
    global REST_HIPS
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
        "Boot": U.material("Boot", U.srgb((0.11, 0.07, 0.045)), rough=0.55),
        "Sole": U.material("Sole", U.srgb((0.03, 0.03, 0.03)), rough=0.9),
        "Helmet": U.material("Helmet", U.srgb((0.92, 0.92, 0.9)), rough=0.3),
        "Visor": U.material("Visor", U.srgb((0.45, 0.48, 0.54)), rough=0.07, metal=0.85),
        "Skin": U.material("Skin", U.srgb((0.85, 0.65, 0.52)), rough=0.6),
        "Glove": U.material("Glove", U.srgb((0.035, 0.035, 0.038)), rough=0.42),
        "GlovePanel": U.material("GlovePanel", U.srgb((0.2, 0.2, 0.21)), rough=0.6),
        "Strap": U.material("Strap", U.srgb((0.15, 0.15, 0.15)), rough=0.7),
    }
    # тело MPFB
    src, wts, joints, axes, hand = mpfb_body()
    pts = [v.co.copy() for v in src.data.vertices]
    reg = [vregion(w) for w in wts]
    REST_HIPS = joints["pelvis"].copy()
    lean, legs, hands, pole, elbow_l = fit_dims(joints, pts, reg, hand)
    grips = [axes["l"], axes["r"]]
    Pose.twist0 = [0.0, 0.0]
    rp = rest_pose((lean, legs, hands, pole, grips))
    rp.bones()
    Pose.twist0 = list(rp.twist)
    rest = rp.bones()
    print("REST локоть L: ошибка %.4f м" % (rest["Forearm.L"][0] - elbow_l).length)
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
    # меши: тело MPFB по частям, прореживание, процедурные детали
    hand_pts = {s: [p for p, r in zip(pts, reg) if r in ("Glove",) and p.x * sd > 0]
                for s, sd in (("L", -1), ("R", 1))}
    arm_pts = {s: [p for p, r in zip(pts, reg) if r in ("Glove", "Jacket") and p.x * sd > 0.2]
               for s, sd in (("L", -1), ("R", 1))}
    for s in ("L", "R"):
        print("GLOVE %s: зазор кулака до оси трубы %.4f м (штанга r 0,017, стойка r 0,019)"
              % (s, cuff_clearance(hand_pts[s], rest["Hand." + s])))
    waist_z = rest["Chest"][0].z - 0.03
    parts = split_parts(src, wts, {"mats": mats, "bones": list(rest), "waist_z": waist_z,
                                   "knee_z": rest["Shin.L"][0].z + 0.05})
    delete_feet(parts["body"])
    for nm, tgt in (("body", TRIS_BODY), ("hands", TRIS_HANDS), ("head", TRIS_HEAD)):
        before = tris(parts[nm])
        decimate(parts[nm], tgt)
        print("DECIMATE %s: %d → %d" % (nm, before, tris(parts[nm])))
    extra = []
    collar = U.MeshBuilder()
    cap_neck(parts["body"], rest["Head"][0], collar)
    extra.append(("Chest", collar))
    harness(rest, pts, reg, extra, wts, waist_z)
    extra += boots(pts, rest)
    for s, side in (("L", -1), ("R", 1)):
        mb = U.MeshBuilder()
        cuff(mb, rest["Hand." + s], side, arm_pts[s], hand_pts[s])
        extra.append(("Hand." + s, mb))
    proc = build_parts(extra, "PilotProc", mats)
    counts = {"тело": tris(parts["body"]), "кисти": tris(parts["hands"]),
              "подвеска/краги": tris(proc)}
    body = join([parts["body"], parts["hands"], proc], "PilotBody")
    skin(body, arm)
    hb = U.MeshBuilder()
    helmet(rest, pts, reg, hb)
    hob = build_parts([("Head", hb)], "HelmetProc", mats)
    counts["голова"] = tris(parts["head"])
    counts["шлем/визор"] = tris(hob)
    hob = join([parts["head"], hob], "Helmet")
    skin(hob, arm)
    # пустышки на костях (в позе покоя)
    ad.pose_position = "REST"
    bpy.context.view_layer.update()
    n, hu, hf, _ = rest["Head"]
    rest_eye = n + hu * D.EYE_UP + hf * D.EYE_FWD
    cam = rest_eye + rot_x(HEAD_PRONE) @ Vector((0, -0.25, 0.08))  # лёжа: 0,25 м сзади, 0,08 выше
    look = rot_x(HEAD_PRONE) @ hf
    marks = {"Head": ("Head", U.look_matrix(rest_eye, rest_eye + look)),
             "CockpitCamera": ("Head", U.look_matrix(cam, cam + rot_x(HEAD_PRONE + 10) @ hf))}
    for s, nm in (("L", "HandL"), ("R", "HandR")):
        w, d, _, _ = rest["Hand." + s]
        marks[nm] = ("Hand." + s, Matrix.Translation(w + d * D.HAND))
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
    all_poses = poses(cf, eye)
    for aname, frames in all_poses.items():
        act = bpy.data.actions.new(aname)
        act.use_fake_user = True
        arm.animation_data.action = act
        gap, gap_f = 0.0, 0
        for fi, pose in enumerate(frames):
            pm = {n: bone_matrix(h, d, zr, ln / ((rest[n][3]) or 1.0))
                  for n, (h, d, zr, ln) in pose.bones().items()}
            if max(pose.reach_gap) > gap:
                gap, gap_f = max(pose.reach_gap), fi + 1
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
        print("POSE %-9s руки не дотягиваются до хвата на %.3f м (кадр %d)" % (aname, gap, gap_f))
        track = arm.animation_data.nla_tracks.new()
        track.name = aname
        track.strips.new(aname, 1, act)
        track.mute = True
    arm.animation_data.action = bpy.data.actions["prone"]
    os.makedirs(U.MODELS, exist_ok=True)
    out_models = os.environ.get("PILOT_OUT") or U.MODELS
    out_source = os.environ.get("PILOT_OUT") or U.SOURCE
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(out_source, "pilot.blend"),
                                check_existing=False, compress=True)
    bpy.ops.export_scene.gltf(filepath=os.path.join(out_models, "pilot.glb"), export_format="GLB",
                              export_yup=True, export_animations=True,
                              export_animation_mode="ACTIONS", export_force_sampling=True,
                              export_skins=True, export_cameras=False, export_lights=False)
    print("TRIS " + ", ".join("%s %d" % kv for kv in counts.items()))
    print("EXPORTED pilot: %d tris (PilotBody %d, Helmet %d), eye(prone) %s (pilot_eye %s)"
          % (U.tri_count(), tris(body), tris(hob), eye_of(all_poses["prone"][0]), eye))


if __name__ == "__main__":
    main()
