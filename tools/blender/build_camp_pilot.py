"""Человек у лагеря: assets/models/world/camp_pilot.glb (+ assets/source/world/camp_pilot.blend).

    BLENDER_USER_RESOURCES=~/.cache/deltaplan/blender_user \\
        blender --background --python tools/blender/build_camp_pilot.py

Контракт SC-K4 v2 (docs/contracts/start-camp.md): тело пилота (MPFB, build_pilot.py: fit_dims, ботинки,
риг из тех же костей) без подвески, лямок, кокона, фала, воротника, шлема, визора и краг; голые
кисти MPFB, волосы, куртка, брюки, ботинки с подошвой. Сцена: Person (Armature → Skeleton3D) с одним
мешем PersonBody и AnimationPlayer. Начало — на земле между стоп, лицом к −Z (Blender +Y), рост 1,78 м.
Анимации (зациклены, без смещения корня): idle, wave, wave_both, walk.

Функции пилота берутся импортом из build_pilot.py (build_pilot.py не менялся). Руки и ноги в
анимациях — IK (two_bone), как у позы пилота.
Окружение: CAMP_OUT=<каталог> — писать не в assets; CAMP_RENDER=<каталог> — ещё и картинку
(вид спереди и сбоку в позах idle и wave).
"""
import math
import os
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bl_util as U  # noqa: E402
import build_pilot as P  # noqa: E402
import pilot_mpfb as M  # noqa: E402

D = P.D
FPS = 24
SHIFT = Vector((0, 0, 2.0))     # у пилота подошва на −2,0 м (карабин в нуле); у человека — на земле
BONES = ("Hips", "Spine", "Chest", "Head",
         "UpperArm.L", "Forearm.L", "Hand.L", "Thigh.L", "Shin.L", "Foot.L",
         "UpperArm.R", "Forearm.R", "Hand.R", "Thigh.R", "Shin.R", "Foot.R")
PARENT = {"Spine": "Hips", "Chest": "Spine", "Head": "Chest"}
for _s in ("L", "R"):
    PARENT.update({"UpperArm." + _s: "Chest", "Forearm." + _s: "UpperArm." + _s,
                   "Hand." + _s: "Forearm." + _s, "Thigh." + _s: "Hips",
                   "Shin." + _s: "Thigh." + _s, "Foot." + _s: "Shin." + _s})
TRIS_BODY = 3300        # тело, кисти и голова одним мешем (без швов)
INFLATE = {"Jacket": 0.008, "Trousers": 0.006, "Hair": 0.007}   # толщина одежды/волос над кожей, м
HAIR_LEN = 0.0
WALK_T = 1.1            # период ходьбы (два шага), с (кадров целое: 26 → 1,083 с)
WALK_STEP = 0.6         # шаг: ход лодыжки опорной ноги за один шаг, м; 2 шага / 1,083 с = 1,11 м/с
OUT_DEG = 7.0           # руки висят чуть врозь, °


class CampPose(P.Pose):
    """Поза человека: ноги — IK по целям лодыжек (ankles), кисти — с заданным поворотом ладони
    (palm), подвеска и фал не строятся."""
    palm_local = {}     # 'L'/'R' → нормаль ладони в системе кости Hand позы покоя

    def __init__(self, *a, ankles=None, foot_ang=(90.0, 90.0), palm=(None, None), **kw):
        super().__init__(*a, **kw)
        self.ankles = ankles
        self.foot_ang = foot_ang
        self.palm = palm

    def shoulder(self, i: int) -> Vector:
        side = (-1, 1)[i]
        neck = self.hips + self.u * (D.SPINE + D.CHEST)
        return neck - self.u * D.SHOULDER_DOWN + self.f * D.SHOULDER_FWD + P.X * side * D.SHOULDER_X

    def bones(self) -> dict:
        b = super().bones()
        for nm in (*P.POD_BONES, "Strap"):
            b.pop(nm)
        for i, (s, side) in enumerate((("L", -1), ("R", 1))):
            if self.ankles is not None:
                hip = b["Thigh." + s][0]
                knee, an, _ = P.two_bone(hip, self.ankles[i], D.THIGH, D.SHIN,
                                         Vector((side * 0.05, 1.0, 0.25)))
                d_th = (knee - hip).normalized()
                d_sh = (an - knee).normalized()
                d_ft = P.rot_x(self.foot_ang[i]) @ Vector((0, 0, -1))
                b["Thigh." + s] = (hip, d_th, self.f, D.THIGH)
                b["Shin." + s] = (knee, d_sh, self.f, D.SHIN)
                b["Foot." + s] = (an, d_ft, -d_sh, D.FOOT)
            if self.palm[i] is not None:
                hh, d, hz, ln = b["Hand." + s]
                n0 = P.bone_matrix(hh, d, hz).to_3x3() @ CampPose.palm_local[s]
                a = P.signed_angle(n0, self.palm[i], d)
                fh, fd, fz, fl = b["Forearm." + s]
                b["Hand." + s] = (hh, d, Matrix.Rotation(a, 3, d) @ hz, ln)
                b["Forearm." + s] = (fh, fd, Matrix.Rotation(a * 0.5, 3, fd) @ fz, fl)
        return b


# ------------------------------------------------------------------ тело

def camp_body():
    """Человек MPFB с открытыми кистями → (меш в наших осях, веса MPFB, суставы, нормаль ладони L).
    Как P.mpfb_body, но без кулаков."""
    h, rig = M.make_human()
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
    zmin = min(v.co.z for v in me.vertices)
    rz = Matrix.Rotation(math.pi, 4, "Z")
    p = rz @ joints["pelvis"]
    mt = Matrix.Translation((-p.x, 0.2 - p.y, -2.0 + P.FOOT_Z - zmin)) @ rz
    me.transform(mt)
    for k in joints:
        joints[k] = mt @ joints[k]
    joints["eye"] = mt @ eye
    joints["sole"] = -2.0
    P.stretch_upper_arm(me, wts, joints)
    while me.uv_layers:       # текстур нет — UV не нужны
        me.uv_layers.remove(me.uv_layers[0])
    # нормаль ладони левой руки: от пальцев (средний) и большого пальца
    def centroid(pred):
        pts = [me.vertices[i].co for i, w in enumerate(wts)
               if w and pred(max(w, key=w.get))]
        return sum(pts, Vector()) / len(pts)
    tip = centroid(lambda n: n == "middle_03_l")
    thumb = centroid(lambda n: n.startswith("thumb") and n.endswith("_l"))
    palm_c = centroid(lambda n: n.endswith("_l") and (n.startswith(("hand", "index_01", "pinky_01"))))
    wr = joints["hand_l"]
    fdir = (tip - wr).normalized()
    ts = thumb - palm_c
    ts = (ts - fdir * ts.dot(fdir)).normalized()
    n = fdir.cross(ts)
    if n.x < 0:           # левая рука на −X: ладонь смотрит к бедру (+X)
        n = -n
    print("LADON: нормаль L %s, пальцы %s, большой %s" % (
        tuple(round(x, 2) for x in n), tuple(round(x, 2) for x in fdir),
        tuple(round(x, 2) for x in ts)))
    ob = bpy.data.objects.new("PersonSrc", me)
    bpy.context.scene.collection.objects.link(ob)
    return ob, wts, joints, n


def set_groups(src, wts: list) -> None:
    """Веса MPFB → наши 16 костей, не больше 4 влияний."""
    for vg in list(src.vertex_groups):
        src.vertex_groups.remove(vg)
    vgs = {b: src.vertex_groups.new(name=b) for b in BONES}
    for vi, wd in enumerate(wts):
        acc = {}
        for k, w in wd.items():
            for b, share in P.MERGE.get(k, {}).items():
                acc[b] = acc.get(b, 0.0) + w * share
        top = sorted(acc.items(), key=lambda kv: -kv[1])[:4]
        tot = sum(w for _, w in top) or 1.0
        for b, w in top:
            vgs[b].add([vi], w / tot, "REPLACE")


def vweights(ob, v) -> dict:
    return {ob.vertex_groups[g.group].name: g.weight for g in v.groups}


def limit_influences(ob, n: int = 4) -> int:
    """После прореживания: на вершину не больше n влияний, веса нормированы. → максимум до."""
    worst = 0
    vg = ob.vertex_groups
    for v in ob.data.vertices:
        gs = sorted(((g.group, g.weight) for g in v.groups if g.weight > 1e-4), key=lambda x: -x[1])
        worst = max(worst, len(gs))
        keep = gs[:n]
        tot = sum(w for _, w in keep) or 1.0
        for gi, _ in gs[n:]:
            vg[gi].remove([v.index])
        for gi, w in keep:
            vg[gi].add([v.index], w / tot, "REPLACE")
    return worst


def dress(ob, rest: dict, joints: dict, eye: Vector) -> None:
    """Материалы по областям (куртка, брюки, кожа, волосы) и толщина одежды/волос по нормалям."""
    me = ob.data
    names = [m.name for m in me.materials]
    nkz = joints["neck_01"].z
    hem_z = joints["pelvis"].z - 0.02
    wr = {s: rest["Hand." + s][0] for s in ("L", "R")}
    fdir = {s: rest["Forearm." + s][1] for s in ("L", "R")}
    cy = eye.y - 0.09
    kind = {}
    for poly in me.polygons:
        acc = {}
        for vi in poly.vertices:
            for k, w in vweights(ob, me.vertices[vi]).items():
                acc[k] = acc.get(k, 0.0) + w
        dom = max(acc, key=acc.get) if acc else "Hips"
        c = poly.center
        if c.z >= nkz:
            hair = c.z > eye.z + 0.04 or (c.z > eye.z - 0.09 and c.y < cy - 0.03)
            m = "Hair" if hair else "Skin"
        elif dom.startswith("Hand"):
            m = "Skin"
        elif dom.startswith(("UpperArm", "Forearm")):
            s = dom[-1]
            m = "Skin" if (c - wr[s]).dot(fdir[s]) > -0.006 else "Jacket"
        else:       # корпус и ноги: край куртки — по высоте (ровная линия)
            m = "Jacket" if c.z >= hem_z else "Trousers"
        poly.material_index = names.index(m)
        kind[poly.index] = m
    # толщина: вершина смещается по нормали на долю прилегающих граней одежды/волос
    fac = [0.0] * len(me.vertices)
    cnt = [0] * len(me.vertices)
    for poly in me.polygons:
        for vi in poly.vertices:
            cnt[vi] += 1
            fac[vi] += INFLATE.get(kind[poly.index], 0.0)
    for v in me.vertices:
        if cnt[v.index]:
            v.co += v.normal * (fac[v.index] / cnt[v.index])
    me.update()


def smooth_all(ob) -> None:
    for p in ob.data.polygons:
        p.use_smooth = True


# ------------------------------------------------------------------ анимации

def ease(x: float) -> float:
    x = min(max(x, 0.0), 1.0)
    return x * x * (3 - 2 * x)


class Maker:
    """Фабрика поз: размеры и покой берутся с меша."""

    def __init__(self, rest0: dict, lean: float, legs: list, hips0: Vector, hands: list, pole):
        self.rest0, self.lean, self.legs, self.hips0 = rest0, lean, legs, hips0
        self.hands0, self.pole0 = hands, pole
        self.a0 = {s: rest0["Foot." + s][0] for s in ("L", "R")}
        self.reach = D.UPPER + D.FORE + D.HAND

    def pose(self, hips=None, ankles=None, foot=(90.0, 90.0), arms=None, pole=None, palm=(None, None)):
        """arms — [(целевая точка | None)] для L, R; None — рука висит."""
        hips = Vector(hips) if hips is not None else self.hips0.copy()
        p = CampPose(hips, self.lean, 0, self.legs, self.hands0, pole or Vector((0, -1, -0.15)),
                     grips=[Vector((-1, 0, 0)), Vector((1, 0, 0))], ankles=ankles, foot_ang=foot,
                     palm=palm)
        return p

    def hang(self, p: CampPose, i: int, pitch: float, out: float = OUT_DEG, reach: float = 0.975):
        side = (-1, 1)[i]
        d = P.rot_x(pitch) @ Vector((side * math.sin(math.radians(out)), 0, -math.cos(math.radians(out))))
        p.hands[i] = p.shoulder(i) + d * (self.reach * reach)

    def stand_ankles(self, lift=(0.0, 0.0), fwd=(0.0, 0.0), dx=(0.0, 0.0)):
        return [self.a0["L"] + Vector((dx[0], fwd[0], lift[0])),
                self.a0["R"] + Vector((dx[1], fwd[1], lift[1]))]

    # --- idle: стоит, переносит вес с ноги на ногу, руки опущены (4 с)
    def idle(self, t: float) -> CampPose:
        s = math.sin(2 * math.pi * t)
        sx = 0.028 * s                               # таз уходит на опорную ногу
        unl_r = ease(-s * 1.6)                       # правая разгружена при s<0
        unl_l = ease(s * 1.6)
        ank = self.stand_ankles(lift=(0.012 * unl_l, 0.012 * unl_r),
                                fwd=(0.025 * unl_l, 0.025 * unl_r),
                                dx=(-0.015 * unl_l, 0.015 * unl_r))
        h = self.hips0 + Vector((sx, 0.004 * math.sin(4 * math.pi * t), -0.012 - 0.006 * abs(s)))
        p = self.pose(h, ank, (90 - 6 * unl_l, 90 - 6 * unl_r))
        for i in (0, 1):
            self.hang(p, i, 3.0 * math.sin(2 * math.pi * t + (0.6 if i else 0.0)) - 2.0)
        return p

    # --- wave: правая рука поднята и машет; левая висит (1,2 с)
    def wave(self, t: float, both: bool = False) -> CampPose:
        sw = math.sin(2 * math.pi * 2 * t)
        h = self.hips0 + Vector((0.006 * math.sin(2 * math.pi * t), 0, -0.01))
        p = self.pose(h, self.stand_ankles(), pole=Vector((0, -0.3, -1.0)),
                      palm=(Vector((0, 1, 0)) if both else None, Vector((0, 1, 0))))
        for i in (0, 1):
            side = (-1, 1)[i]
            if i == 0 and not both:
                self.hang(p, 0, 2.0 * math.sin(2 * math.pi * t))
            else:
                p.hands[i] = p.shoulder(i) + Vector((side * (0.17 + 0.08 * sw * 1.0), 0.09, 0.40))
        return p

    # --- walk: шаг на месте, руки в такт (WALK_T = 1,1 с, шаг 0,6 м → ~1,09 м/с)
    def walk(self, t: float) -> CampPose:
        amp = WALK_STEP / 2
        ank, ang = [], []
        for i, ph0 in enumerate((0.0, 0.5)):          # L, R
            ph = (t + ph0) % 1.0
            a0 = self.a0["LR"[i]]
            if ph < 0.6:                              # опора: лодыжка уходит назад
                u = ph / 0.6
                y = amp * (1 - 2 * u)
                z = 0.015 * ease((u - 0.65) / 0.35)
                fa = 90 + 16 * (1 - ease(u / 0.25)) - 38 * ease((u - 0.6) / 0.4)
            else:                                     # перенос: вперёд с подъёмом
                u = (ph - 0.6) / 0.4
                e = ease(u)
                y = -amp + 2 * amp * e
                z = 0.03 * (1 - ease(u * 2.5)) + 0.085 * math.sin(math.pi * e)
                fa = 52 + 56 * ease(u * 1.6) - 0 * u
            ank.append(a0 + Vector((0, y, z)))
            ang.append(fa)
        bob = 0.03 * math.sin(2 * math.pi * t) ** 2
        h = self.hips0 + Vector((0.012 * math.sin(2 * math.pi * t + math.pi / 2), 0, -0.05 + bob))
        p = self.pose(h, ank, tuple(ang))
        for i in (0, 1):
            ph = (t + (0.5 if i == 0 else 0.0)) % 1.0     # руки против ног
            sw = math.sin(2 * math.pi * ph)
            self.hang(p, i, 22.0 * sw - 4, out=OUT_DEG + 2, reach=0.93 + 0.04 * (1 + sw) / 2)
        return p


def build_anims(arm, rest: dict, rest_m: dict, mk: Maker) -> dict:
    specs = {"idle": (96, mk.idle, 4.0), "wave": (29, mk.wave, 1.2),
             "wave_both": (29, lambda t: mk.wave(t, True), 1.2),
             "walk": (int(round(WALK_T * FPS)), mk.walk, WALK_T)}
    lens = {}
    arm.animation_data_create()
    for aname, (n, fn, length) in specs.items():
        act = bpy.data.actions.new(aname)     # зацикливание — в camp_pilot.glb.import (settings/loop_mode)
        act.use_fake_user = True
        arm.animation_data.action = act
        err = 0.0
        for fi in range(n + 1):
            pose = fn((fi % n) / n)           # последний кадр = первому — цикл без шва
            bn = pose.bones()
            for k, (hh, d, zr, ln) in list(bn.items()):
                bn[k] = (hh + SHIFT, d, zr, ln)
            pm = {k: P.bone_matrix(h, d, zr, ln / (rest[k][3] or 1.0)) for k, (h, d, zr, ln) in bn.items()}
            for name, m in pm.items():
                rm = rest_m[name]
                rmn = P.bone_matrix(rest[name][0], rest[name][1], rest[name][2])
                corr = rmn.inverted() @ rm
                mp = m @ corr
                par = PARENT.get(name)
                if par:
                    basis = (rest_m[par].inverted() @ rm).inverted() @ (
                        pm[par] @ (P.bone_matrix(rest[par][0], rest[par][1], rest[par][2])
                                   .inverted() @ rest_m[par])).inverted() @ mp
                else:
                    basis = rm.inverted() @ mp
                pb = arm.pose.bones[name]
                pb.rotation_mode = "QUATERNION"
                loc, rot, sc = basis.decompose()
                pb.location, pb.rotation_quaternion, pb.scale = loc, rot, sc
                for path in ("location", "rotation_quaternion", "scale"):
                    pb.keyframe_insert(path, frame=fi + 1)
            if pose.ankles is not None:
                for i, s in enumerate("LR"):      # ошибка достижимости цели лодыжки
                    err = max(err, (pose.ankles[i] + SHIFT - bn["Foot." + s][0]).length)
        lens[aname] = (n / FPS)
        print("ANIM %-9s %d кадров, %.3f с, недотяг ног %.3f м" % (aname, n, n / FPS, err))
        track = arm.animation_data.nla_tracks.new()
        track.name = aname
        track.strips.new(aname, 1, act)
        track.mute = True
    return lens


# ------------------------------------------------------------------ картинка

def render(arm, outdir: str, mk_frames: dict) -> None:
    sc = bpy.context.scene
    sc.render.engine = "BLENDER_WORKBENCH"
    sc.display.shading.light = "STUDIO"
    sc.display.shading.color_type = "MATERIAL"
    sc.render.resolution_x, sc.render.resolution_y = 420, 640
    sc.render.film_transparent = False
    sc.world = bpy.data.worlds.new("w")
    sc.world.color = (0.8, 0.82, 0.85)
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    cam.data.type = "ORTHO"
    cam.data.ortho_scale = 2.0
    bpy.context.scene.collection.objects.link(cam)
    sc.camera = cam
    os.makedirs(outdir, exist_ok=True)
    tiles = []
    for aname, frame in mk_frames.items():
        arm.animation_data.action = bpy.data.actions[aname]
        sc.frame_set(frame)
        for view, pos in (("front", (0, 6, 0.95)), ("side", (6, 0, 0.95))):
            cam.location = pos
            tgt = Vector((0, 0, 0.95))
            cam.rotation_euler = (tgt - Vector(pos)).to_track_quat("-Z", "Y").to_euler()
            fp = os.path.join(outdir, "tmp_%s_%s.png" % (aname, view))
            sc.render.filepath = fp
            bpy.ops.render.render(write_still=True)
            tiles.append(fp)
    import numpy as np
    imgs = []
    for fp in tiles:
        im = bpy.data.images.load(fp)
        w, h = im.size
        imgs.append(np.array(im.pixels[:]).reshape(h, w, 4))
    row = lambda a: np.concatenate(a, axis=1)
    out = np.concatenate([row(imgs[:2] + imgs[2:4])], axis=0)
    res = bpy.data.images.new("montage", out.shape[1], out.shape[0], alpha=False)
    res.pixels = out.flatten().tolist()
    res.filepath_raw = os.path.join(outdir, "camp_pilot.png")
    res.file_format = "PNG"
    res.save()
    for fp in tiles:
        os.remove(fp)
    print("RENDER " + res.filepath_raw)


# ------------------------------------------------------------------ сборка

def main() -> None:
    ra = U.load_json("configs/pilot.json")["visual"]["run_anim"]
    D.LEG_SPLAY = float(ra["leg_splay_deg"])
    U.reset_scene()
    bpy.context.scene.render.fps = FPS
    mats = {
        "Jacket": U.material("Jacket", U.srgb((0.30, 0.38, 0.50)), rough=0.85),
        "Trousers": U.material("Trousers", U.srgb((0.20, 0.20, 0.22)), rough=0.85),
        "Skin": U.material("Skin", U.srgb((0.85, 0.65, 0.52)), rough=0.6),
        "Hair": U.material("Hair", U.srgb((0.22, 0.15, 0.10)), rough=0.8),
        "Boot": U.material("Boot", U.srgb((0.11, 0.07, 0.045)), rough=0.55),
        "Sole": U.material("Sole", U.srgb((0.03, 0.03, 0.03)), rough=0.9),
    }
    src, wts, joints, palm_l = camp_body()
    pts = [v.co.copy() for v in src.data.vertices]
    reg = [P.vregion(w) for w in wts]
    P.REST_HIPS = joints["pelvis"].copy()
    hand_len = 0.10
    lean, legs, hands, pole, elbow_l = P.fit_dims(joints, pts, reg, hand_len)
    Pose = P.Pose
    Pose.twist0 = [0.0, 0.0]
    grips = [Vector((-1, 0, 0)), Vector((1, 0, 0))]
    rp = P.rest_pose((lean, legs, hands, pole, grips))
    rp.bones()
    Pose.twist0 = list(rp.twist)
    rest0 = {k: v for k, v in rp.bones().items() if k in BONES}
    for s, sd in (("L", 1), ("R", 1)):
        pass
    CampPose.palm_local = {}
    for s in ("L", "R"):
        hh, d, hz, _ = rest0["Hand." + s]
        n = palm_l if s == "L" else Vector((-palm_l.x, palm_l.y, palm_l.z))
        CampPose.palm_local[s] = P.bone_matrix(hh, d, hz).to_3x3().inverted() @ n
    print("REST локоть L: ошибка %.4f м" % (rest0["Forearm.L"][0] - elbow_l).length)
    rest = {k: (h + SHIFT, d, zr, ln) for k, (h, d, zr, ln) in rest0.items()}
    # скелет
    ad = bpy.data.armatures.new("Person")
    arm = bpy.data.objects.new("Person", ad)
    bpy.context.scene.collection.objects.link(arm)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode="EDIT")
    for name, (h, d, zr, ln) in rest.items():
        eb = ad.edit_bones.new(name)
        m = P.bone_matrix(h, d, zr)
        eb.head = h
        eb.tail = h + d.normalized() * ln
        eb.align_roll(Vector(m.col[2][:3]))
    for name, par in PARENT.items():
        ad.edit_bones[name].parent = ad.edit_bones[par]
    bpy.ops.object.mode_set(mode="OBJECT")
    rest_m = {b.name: b.matrix_local.copy() for b in ad.bones}
    # меш: один на всё тело
    src.data.materials.clear()
    for mn in ("Jacket", "Trousers", "Skin", "Hair"):
        src.data.materials.append(mats[mn])
    set_groups(src, wts)
    P.delete_feet(src)
    before = P.tris(src)
    P.decimate(src, TRIS_BODY)
    print("DECIMATE: %d → %d" % (before, P.tris(src)))
    infl = limit_influences(src)
    print("ВЛИЯНИЯ: максимум после прореживания %d (обрезано до 4)" % infl)
    eye_pt = joints["eye"]
    dress(src, rest0, joints, eye_pt)
    smooth_all(src)
    extra = P.boots(pts, rest0)
    proc = P.build_parts(extra, "CampBoots", mats)
    body = P.join([src, proc], "PersonBody")
    body.data.transform(Matrix.Translation(SHIFT))
    P.skin(body, arm)
    # анимации
    ad.pose_position = "POSE"
    mk = Maker(rest0, lean, legs, P.REST_HIPS.copy(), hands, pole)
    lens = build_anims(arm, rest, rest_m, mk)
    arm.animation_data.action = bpy.data.actions["idle"]
    bpy.context.scene.frame_set(1)
    bpy.context.view_layer.update()
    zs = [(body.matrix_world @ v.co).z for v in body.data.vertices]
    print("РОСТ %.3f м, низ %.3f" % (max(zs) - min(zs), min(zs)))
    out_models = os.environ.get("CAMP_OUT") or os.path.join(U.MODELS, "world")
    out_source = os.environ.get("CAMP_OUT") or os.path.join(U.SOURCE, "world")
    os.makedirs(out_models, exist_ok=True)
    os.makedirs(out_source, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(out_source, "camp_pilot.blend"),
                                check_existing=False, compress=True)
    bpy.ops.export_scene.gltf(filepath=os.path.join(out_models, "camp_pilot.glb"),
                              export_format="GLB", export_yup=True, export_animations=True,
                              export_animation_mode="ACTIONS", export_force_sampling=True,
                              export_skins=True, export_cameras=False, export_lights=False)
    print("EXPORTED camp_pilot: %d tris (PersonBody %d) anim %s" % (
        U.tri_count(), P.tris(body), lens))
    if os.environ.get("CAMP_RENDER"):
        render(arm, os.environ["CAMP_RENDER"], {"idle": 24, "wave": 4})


if __name__ == "__main__":
    main()
