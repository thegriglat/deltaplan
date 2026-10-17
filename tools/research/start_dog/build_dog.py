"""DOG-1: Quaternius ShibaInu (CC0) -> assets/easter_eggs/start_dog/dog.glb по DOG-K2.

Запуск (из корня копии):
  blender --background <ShibaInu.blend> --python tools/research/start_dog/build_dog.py -- <out_dir> [<renders_dir>]

Что делает (геометрию не меняет):
  - снимает NLA-дорожки (иначе они подмешиваются к действию);
  - 6 материалов -> атрибут цвета вершин (по углам граней) + 1 материал «Dog»;
  - клипы: gallop<-Gallop, walk<-Walk, idle<-Idle, sniff<-Idle_2_HeadLow (переименование);
    trot  — Walk, ноги переставлены в диагональные пары (LF+RH, RF+LH), цикл 12 кадров;
    bark  — поза покоя + два рывка шеи/головы вверх-вперёд (челюсти в модели нет);
    lie   — тело опущено, передние лапы вперёд, задние поджаты (IK), дыхание;
    sit   — тело повёрнуто задом вниз, задние лапы под тазом (IK), дыхание;
    остальные действия удаляются;
  - масштаб под холку WITHERS_M, морда в -Z Godot (поворот 180° вокруг Z Blender), начало — между лапами;
  - замер speed_ms/cycle_s по концам стоп в опоре -> measure.json рядом со скриптом (MEASURE_JSON);
  - экспорт GLB (Y вверх, цвета вершин, только деформирующие кости).
"""
import bpy, sys, os, json, math
from mathutils import Matrix, Quaternion, Vector

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
OUT = argv[0] if argv else "assets/easter_eggs/start_dog"
RENDERS = argv[1] if len(argv) > 1 else ""
HERE = os.path.dirname(os.path.abspath(__file__))
MEASURE_JSON = os.path.join(HERE, "measure.json")
FPS = 30
WITHERS_U = 2.30        # верх спины над лопатками в покое, единицы модели (профиль measure_rest.py)
WITHERS_M = 0.52        # целевая высота в холке, м (DOG-K2: 0,50–0,65)
S = WITHERS_M / WITHERS_U
FEET_MID_Y = -0.48      # середина между передними (y≈-1.36) и задними (y≈+0.40) стопами в покое/шаге, ед.

sc = bpy.context.scene
sc.render.fps = FPS
arm = next(o for o in bpy.data.objects if o.type == 'ARMATURE')
mesh = next(o for o in bpy.data.objects if o.type == 'MESH')
ad = arm.animation_data
for t in list(ad.nla_tracks):
    ad.nla_tracks.remove(t)
pbs = arm.pose.bones

# ---------- материалы -> цвета вершин ----------
me = mesh.data
cols = [tuple(m.diffuse_color) for m in me.materials]
attr = me.color_attributes.new("Col", "FLOAT_COLOR", "CORNER")
for poly in me.polygons:
    c = cols[poly.material_index]
    for li in poly.loop_indices:
        attr.data[li].color = c
me.color_attributes.active_color = attr
me.materials.clear()
mat = bpy.data.materials.new("Dog")
mat.use_nodes = True
nt = mat.node_tree
bsdf = next(n for n in nt.nodes if n.type == 'BSDF_PRINCIPLED')
vc = nt.nodes.new("ShaderNodeVertexColor")
vc.layer_name = "Col"
nt.links.new(vc.outputs["Color"], bsdf.inputs["Base Color"])
bsdf.inputs["Roughness"].default_value = 0.9
me.materials.append(mat)


# ---------- утилиты действий ----------
def bone_of(fc):
    return fc.data_path.split('"')[1] if '"' in fc.data_path else None


def leg_of(bone):
    """LF/RF/LH/RH для костей ноги, иначе None (уши .L/.R — не ноги)."""
    if bone is None or not (bone.endswith(".L") or bone.endswith(".R")):
        return None
    side = "L" if bone.endswith(".L") else "R"
    if bone.startswith(("Back", "IKBack", "FFB", "PoleTargetBack")):
        return side + "H"
    if bone.startswith(("Front", "IKFront", "FF.", "PoleTarget.")):
        return side + "F"
    return None


def new_action(name):
    a = bpy.data.actions.new(name)
    a.use_fake_user = True
    return a


def set_key(act, path, idx, frame, value, group):
    fc = act.fcurves.find(path, index=idx) or act.fcurves.new(path, index=idx, action_group=group)
    fc.keyframe_points.insert(frame, value, options={'FAST'})


def resample(src, dst, n_frames, src_len, shift=None, step=1):
    """dst: кадр k (0..n_frames) = src в t = (k*src_len/n_frames + shift[leg]) mod src_len."""
    shift = shift or {}
    for fc in src.fcurves:
        b = bone_of(fc)
        sh = shift.get(leg_of(b), 0.0)
        for k in range(0, n_frames + 1, step):
            t = (k * src_len / n_frames + sh) % src_len
            if k == n_frames:
                t = (0 + sh) % src_len
            set_key(dst, fc.data_path, fc.array_index, k, fc.evaluate(t), b or "misc")


def static_from(src, dst, frame, n_frames):
    for fc in src.fcurves:
        v = fc.evaluate(frame)
        for k in (0, n_frames):
            set_key(dst, fc.data_path, fc.array_index, k, v, bone_of(fc) or "misc")


def key_pose(act, bone, frame, loc=None, quat=None):
    pb = pbs[bone]
    if loc is not None:
        for i in range(3):
            set_key(act, 'pose.bones["%s"].location' % bone, i, frame, loc[i], bone)
    if quat is not None:
        for i in range(4):
            set_key(act, 'pose.bones["%s"].rotation_quaternion' % bone, i, frame, quat[i], bone)


def local_from_arm(bone, m_arm):
    """Матрица в пространстве арматуры (с позой родителя = как в кадре) -> location, quaternion позы."""
    pb = pbs[bone]
    loc_basis = arm.convert_space(pose_bone=pb, matrix=m_arm, from_space='POSE', to_space='LOCAL')
    l, q, _s = loc_basis.decompose()
    return l, q


def rest_arm(bone):
    return arm.data.bones[bone].matrix_local.copy()


def finish(act):
    for fc in act.fcurves:
        for kp in fc.keyframe_points:
            kp.interpolation = 'BEZIER'
        fc.update()


acts = bpy.data.actions
walk_src, gallop_src, idle_src = acts["Walk"], acts["Gallop"], acts["Idle"]
sniff_src = acts["Idle_2_HeadLow"]
L_WALK = walk_src.frame_range[1] - walk_src.frame_range[0]

# ---------- trot: шаг -> диагональные пары ----------
# касания в шаге (кадры, по foot_tracks.py): LF 0, RH ~9.5, RF 16, LH ~27 из 32 -> RH к 0, LH к 16.
trot = new_action("trot")
TROT_N = 12
resample(walk_src, trot, TROT_N, L_WALK, shift={"RH": 9.5, "LH": 11.0})
finish(trot)

# ---------- bark: стоит, два рывка шеи/головы ----------
BARK_N = 36
BARK_AT = [0.25, 0.70]  # с, пик рывка = «гав»
bark = new_action("bark")
static_from(idle_src, bark, 0, BARK_N)
ax = Vector((1, 0, 0))
for bone, ang in (("Neck1", -0.10), ("Neck2", -0.12), ("Neck3", -0.10), ("Head", 0.22),
                  ("Ear1.L", -0.25), ("Ear1.R", -0.25)):
    for t in BARK_AT:
        f = t * FPS
        for df, w in ((-4, 0.0), (-1, 0.6), (0, 1.0), (3, 0.35), (6, 0.0)):
            q = Quaternion(ax, ang * w)
            key_pose(bark, bone, f + df, quat=q)
    key_pose(bark, bone, 0, quat=Quaternion())
    key_pose(bark, bone, BARK_N, quat=Quaternion())
# грудь чуть вперёд-вверх при гавке
for t in BARK_AT:
    f = t * FPS
    for df, w in ((-4, 0.0), (0, 1.0), (6, 0.0)):
        key_pose(bark, "Torso3", f + df, quat=Quaternion(ax, -0.06 * w))
finish(bark)


# ---------- lie / sit через IK ----------
def pose_static(act, frame, body_m, ik):
    """body_m — матрица Body в пространстве арматуры; ik — {кость: Vector головы в пр-ве арматуры}."""
    l, q = local_from_arm("Body", body_m)
    key_pose(act, "Body", frame, loc=l, quat=q)
    for bone, head in ik.items():
        m = rest_arm(bone)
        m.translation = head
        l, q = local_from_arm(bone, m)
        key_pose(act, bone, frame, loc=l, quat=q)


def breathe(act, n, amp):
    for k in range(0, n + 1, 10):
        a = amp * math.sin(2 * math.pi * k / n)
        key_pose(act, "Torso2", k, quat=Quaternion(ax, a))
        key_pose(act, "Torso", k, quat=Quaternion(ax, -a))
        key_pose(act, "Tail1", k, quat=Quaternion(Vector((0, 0, 1)), 0.08 * math.sin(4 * math.pi * k / n)))


def body_matrix(drop, pitch, pivot):
    piv = Vector(pivot)
    return (Matrix.Translation(Vector((0, 0, -drop))) @ Matrix.Translation(piv) @
            Matrix.Rotation(pitch, 4, 'X') @ Matrix.Translation(-piv) @ rest_arm("Body"))


LIE_N = 60
lie = new_action("lie")
static_from(idle_src, lie, 0, LIE_N)
ad.action = lie
lie_body = body_matrix(drop=0.88, pitch=0.0, pivot=(0, 0, 0.47))
lie_ik = {
    "IKFrontLeg.L": Vector((0.30, -2.05, 0.21)), "IKFrontLeg.R": Vector((-0.30, -2.05, 0.21)),
    "IKBackLeg.L": Vector((0.62, 0.05, 0.20)), "IKBackLeg.R": Vector((-0.62, 0.05, 0.20)),
}
for fr in (0, LIE_N):
    pose_static(lie, fr, lie_body, lie_ik)
breathe(lie, LIE_N, 0.025)
finish(lie)

SIT_N = 60
sit = new_action("sit")
static_from(idle_src, sit, 0, SIT_N)
ad.action = sit
sit_body = body_matrix(drop=0.55, pitch=-0.55, pivot=(0, 0.75, 1.0))
sit_ik = {
    "IKBackLeg.L": Vector((0.45, -0.05, 0.20)), "IKBackLeg.R": Vector((-0.45, -0.05, 0.20)),
}
for fr in (0, SIT_N):
    pose_static(sit, fr, sit_body, sit_ik)
breathe(sit, SIT_N, 0.02)
finish(sit)

# ---------- переименование и чистка ----------
gallop_src.name, walk_src.name, idle_src.name, sniff_src.name = "gallop", "walk", "idle", "sniff"
KEEP = ["gallop", "trot", "walk", "idle", "bark", "lie", "sit", "sniff"]
for a in list(acts):
    if a.name not in KEEP:
        acts.remove(a)
for a in acts:
    a.use_fake_user = True

# ---------- масштаб, морда в -Z (Godot), начало между лапами ----------
arm.rotation_euler = (0, 0, math.pi)
arm.scale = (S, S, S)
arm.location = (0, FEET_MID_Y * S, 0)   # после поворота y модели -> -y мира
bpy.context.view_layer.update()

# ---------- замер скорости без проскальзывания ----------
FEET = ["FF.L", "FF.R", "FFB.L", "FFB.R"]


def track(act):
    ad.action = act
    f0, f1 = int(act.frame_range[0]), int(act.frame_range[1])
    out = {n: [] for n in FEET}
    for f in range(f0, f1):          # последний кадр = первый (цикл)
        sc.frame_set(f)
        for n in FEET:
            p = arm.matrix_world @ pbs[n].tail
            out[n].append((p.y, p.z))
    return out, f1 - f0


def stance_speed(act):
    """Опора: z стопы <= z_low + 0,006 ед. модели и движение назад (z_low — 30-й перцентиль z по циклу).
    Смещение в опоре считаем только назад (-Y мира после поворота = от морды), рывки вперёд не в счёт."""
    tr, n = track(act)
    tot_sweep, tot_t, per = 0.0, 0.0, {}
    tol = 0.006 * S
    for foot, pts in tr.items():
        zs = sorted(z for _, z in pts)
        zlow = zs[int(0.3 * (n - 1))]
        st = [z <= zlow + tol for _, z in pts]
        sweep = 0.0; frames = 0
        for i in range(n):
            j = (i + 1) % n
            if st[i] and st[j] and pts[i][0] - pts[j][0] > 1e-4:
                sweep += pts[i][0] - pts[j][0]; frames += 1
        dur = frames / FPS
        per[foot] = {"sweep_m": round(sweep, 3), "stance_s": round(dur, 3),
                     "speed_ms": round(sweep / dur, 3) if dur else None, "duty": round(sum(st) / n, 2)}
        tot_sweep += sweep; tot_t += dur
    return {"cycle_s": round(n / FPS, 3), "frames": n,
            "speed_ms": round(tot_sweep / tot_t, 3) if tot_t else None, "feet": per}


measure = {"scale": round(S, 4), "withers_m": WITHERS_M, "fps": FPS,
           "method": "конец кости стопы (FF.*/FFB.*) в мире по кадрам; опора — z <= p30(z) + 0,006 ед. модели (~1,4 мм) и стопа движется назад; "
                     "speed = сумма смещений стоп назад в опоре / сумма времени опоры по 4 лапам; "
                     "воспроизведение 1,0, масштаб модели scale",
           "clips": {}}
for name in ("gallop", "trot", "walk"):
    measure["clips"][name] = stance_speed(acts[name])
for name in ("idle", "bark", "lie", "sit", "sniff"):
    a = acts[name]
    measure["clips"][name] = {"cycle_s": round((a.frame_range[1] - a.frame_range[0]) / FPS, 3)}
measure["clips"]["bark"]["bark_at_s"] = BARK_AT

# габариты в позе idle (кадр 0) и кадрах остальных клипов: низ меша (утопание/подъём)
dg = bpy.context.evaluated_depsgraph_get()
bounds = {}
for name in KEEP:
    ad.action = acts[name]
    a = acts[name]
    zs = []
    for f in (int(a.frame_range[0]), int((a.frame_range[0] + a.frame_range[1]) / 2)):
        sc.frame_set(f)
        ev = mesh.evaluated_get(bpy.context.evaluated_depsgraph_get())
        m = ev.to_mesh()
        vs = [mesh.matrix_world @ v.co for v in m.vertices]
        zs.append((round(min(v.z for v in vs), 3), round(max(v.z for v in vs), 3)))
        if f == int(a.frame_range[0]) and name == "idle":
            bounds["idle_size_m"] = [round(max(v.x for v in vs) - min(v.x for v in vs), 3),
                                     round(max(v.z for v in vs) - min(v.z for v in vs), 3),
                                     round(max(v.y for v in vs) - min(v.y for v in vs), 3)]
        ev.to_mesh_clear()
    bounds[name] = zs
measure["zmin_zmax_m"] = bounds
tris = sum(len(p.vertices) - 2 for p in me.polygons)
measure["triangles"] = tris
with open(MEASURE_JSON, "w") as fh:
    json.dump(measure, fh, ensure_ascii=False, indent=1)
print("MEASURE", json.dumps(measure, ensure_ascii=False))

# ---------- кадры для самопроверки (workbench, вид сбоку) ----------
if RENDERS:
    os.makedirs(RENDERS, exist_ok=True)
    cam_d = bpy.data.cameras.new("cam"); cam_d.type = 'ORTHO'; cam_d.ortho_scale = 1.4
    cam = bpy.data.objects.new("cam", cam_d); sc.collection.objects.link(cam)
    cam.location = (2.5, 0, 0.35); cam.rotation_euler = (math.pi / 2, 0, math.pi / 2)
    sc.camera = cam
    sc.render.engine = 'BLENDER_WORKBENCH'
    sc.display.shading.color_type = 'VERTEX'
    sc.render.resolution_x, sc.render.resolution_y = 480, 320
    for name in KEEP:
        a = acts[name]; ad.action = a
        for k, fr in enumerate((a.frame_range[0], (a.frame_range[0] + a.frame_range[1]) / 2)):
            sc.frame_set(int(fr))
            sc.render.filepath = os.path.join(RENDERS, "%s_%d.png" % (name, k))
            bpy.ops.render.render(write_still=True)
    sc.collection.objects.unlink(cam)

# ---------- экспорт ----------
ad.action = acts["idle"]
sc.frame_set(0)
os.makedirs(OUT, exist_ok=True)
for o in bpy.data.objects:
    o.select_set(o in (arm, mesh))
bpy.context.view_layer.objects.active = arm
bpy.ops.export_scene.gltf(
    filepath=os.path.join(OUT, "dog.glb"), export_format="GLB", export_yup=True, use_selection=True,
    export_apply=True, export_vertex_color="ACTIVE", export_animations=True,
    export_animation_mode="ACTIONS", export_def_bones=True, export_force_sampling=True,
    export_frame_range=False, export_anim_slide_to_zero=True, export_optimize_animation_size=True,
    export_materials="EXPORT")
print("EXPORTED", os.path.join(OUT, "dog.glb"), "tris", tris)
