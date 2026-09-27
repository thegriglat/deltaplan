"""Пилот-манекен лёжа в подвеске-коконе: assets/models/pilot.glb (+ assets/source/pilot.blend).

    blender --background --python tools/blender/build_pilot.py

Контракт (docs/models.md): корневая нода Pilot, её начало = точка подвеса (карабин), голова
вперёд (+Y Blender = −Z Godot). Меши PilotBody (кокон, руки, фал) и Helmet (голова в шлеме —
отдельно, чтобы кабинная камера могла её скрыть). Пустышки: Head (глаза, для кабинной камеры; −Z Godot — взгляд
вперёд), HandL, HandR (кисти на базовой штанге), CockpitCamera (рекомендуемая точка и
направление кабинной камеры, −Z Godot — взгляд; голову Helmet при этом скрыть). Положение штанги и глаз — из
tools/blender/glider_params.json (control_frame, pilot_eye), общее для всех крыльев.
"""
import math
import os
import sys

from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bl_util as U  # noqa: E402

BODY_Z = -1.36          # ось тела под точкой подвеса, м
# сечения кокона: (y, полуширина, полувысота, dz) — от плеч к хвосту
POD = [
    (0.40, 0.11, 0.09, 0.02), (0.36, 0.20, 0.14, 0.0), (0.28, 0.25, 0.175, 0.0),
    (0.10, 0.26, 0.19, -0.01), (-0.15, 0.25, 0.2, -0.01), (-0.40, 0.24, 0.2, 0.0),
    (-0.70, 0.20, 0.16, 0.02), (-1.00, 0.17, 0.14, 0.05), (-1.25, 0.14, 0.12, 0.08),
    (-1.45, 0.10, 0.09, 0.11), (-1.60, 0.05, 0.05, 0.13), (-1.66, 0.01, 0.01, 0.14),
]


def pod(mb: U.MeshBuilder) -> None:
    seg = 16
    rings = []
    mats = []
    for y, rx, rz, dz in POD:
        ring = []
        for k in range(seg):
            a = 2 * math.pi * k / seg
            ring.append(Vector((rx * math.cos(a), y, BODY_Z + dz + rz * math.sin(a))))
        rings.append(ring)
    base = len(mb.verts)
    for ring in rings:
        for p in ring:
            mb.add_vert(p)
    for i in range(len(rings) - 1):
        for k in range(seg):
            k2 = (k + 1) % seg
            q = [base + i * seg + k, base + i * seg + k2, base + (i + 1) * seg + k2,
                 base + (i + 1) * seg + k]
            ang = 2 * math.pi * (k + 0.5) / seg
            side = abs(math.sin(ang)) < 0.3 and 2 < i < len(rings) - 3
            mat = "Jacket" if i < 2 else ("Stripe" if side else "Pod")  # плечи — куртка
            mb.add_face(q, mat)
    # закрыть хвост и перед
    tail = [base + (len(rings) - 1) * seg + k for k in range(seg)]
    mb.add_face(tail, "Pod", smooth=False)
    front = [base + k for k in reversed(range(seg))]
    mb.add_face(front, "Jacket", smooth=False)
    del mats


def main() -> None:
    params = U.load_json("tools/blender/glider_params.json")
    cf = params["control_frame"]
    eye = Vector(params["pilot_eye"])
    y_bb = cf["basebar_forward_m"]
    z_bb = cf["keel_z_m"] - cf["basebar_drop_m"]
    U.reset_scene()
    mats = {
        "Pod": U.material("Pod", U.srgb((0.10, 0.13, 0.22)), rough=0.7),
        "Stripe": U.material("PodStripe", U.srgb((0.95, 0.55, 0.05)), rough=0.6),
        "Jacket": U.material("Jacket", U.srgb((0.22, 0.24, 0.27)), rough=0.8),
        "Helmet": U.material("Helmet", U.srgb((0.92, 0.92, 0.9)), rough=0.3),
        "Visor": U.material("Visor", U.srgb((0.05, 0.05, 0.07)), rough=0.1, metal=0.3),
        "Skin": U.material("Skin", U.srgb((0.85, 0.65, 0.52)), rough=0.6),
        "Glove": U.material("Glove", U.srgb((0.06, 0.06, 0.06)), rough=0.7),
        "Strap": U.material("Strap", U.srgb((0.15, 0.15, 0.15)), rough=0.7),
    }
    root = U.empty("Pilot", (0, 0, 0), size=0.3)
    mb = U.MeshBuilder()
    pod(mb)
    # подвесной фал с карабином: от точки подвеса к спине подвески
    mb.add_tube([(0, 0, -0.03), (0, 0.02, BODY_Z + 0.14)], 0.012, "Strap", sides=6,
                ellipse=(2.0, 0.6), up=(0, 1, 0))
    mb.add_ellipsoid((0, 0, -0.045), (0.012, 0.04, 0.03), "Visor", 8, 5)
    # шея и голова в шлеме (голова поднята, взгляд вперёд)
    head_c = eye + Vector((0, -0.15, 0.03))  # глаза — у визора, камера вне шлема
    mb.add_tube([(0, 0.36, BODY_Z + 0.06), head_c + Vector((0, -0.04, -0.06))], 0.055,
                "Jacket", sides=8)
    # голова со шлемом — отдельный меш Helmet (кабинная камера может его прятать)
    hb = U.MeshBuilder()
    hb.add_ellipsoid(head_c, (0.115, 0.14, 0.12), "Helmet", 14, 9)
    hb.add_ellipsoid(head_c + Vector((0, 0.06, -0.06)), (0.075, 0.07, 0.07), "Skin", 10, 6)
    rot = Matrix.Rotation(math.radians(-20), 3, "X")
    hb.add_ellipsoid(head_c + Vector((0, 0.1, 0.0)), (0.1, 0.045, 0.035), "Visor", 12, 6, rot)
    # руки: плечо → локоть → кисть на штанге
    hands = {}
    for s, nm in ((-1, "HandL"), (1, "HandR")):
        sh = Vector((s * 0.2, 0.3, BODY_Z + 0.05))
        hand = Vector((s * 0.33, y_bb, z_bb + 0.035))
        elbow = Vector((s * 0.34, (sh.y + hand.y) / 2 - 0.02, (sh.z + hand.z) / 2 - 0.1))
        mb.add_ellipsoid(sh, (0.075, 0.09, 0.07), "Jacket", 10, 6)
        mb.add_tube([sh, elbow, hand - (hand - elbow).normalized() * 0.05],
                    [0.05, 0.043, 0.038], "Jacket", sides=12)
        mb.add_ellipsoid(hand, (0.05, 0.055, 0.045), "Glove", 10, 6)
        hands[nm] = hand
    body = mb.build("PilotBody", mats, parent=root)
    body.name = "PilotBody"
    hb.build("Helmet", mats, parent=root).name = "Helmet"
    head = U.empty("Head", None, parent=root,
                   matrix=U.look_matrix(eye, eye + Vector((0, 1, 0))))
    head.name = "Head"
    # рекомендуемая кабинная камера: 0,25 м позади и 0,08 м выше глаз, взгляд на 10° вверх
    # (Helmet при этом скрыть) — видны стойки, штанга, руки, приборы и нос паруса
    cam_pos = eye + Vector((0, -0.25, 0.08))
    pitch = math.radians(10)
    U.empty("CockpitCamera", None, parent=root, matrix=U.look_matrix(
        cam_pos, cam_pos + Vector((0, math.cos(pitch), math.sin(pitch)))))
    for nm, pos in hands.items():
        U.empty(nm, pos, parent=root)
    U.export("pilot")


if __name__ == "__main__":
    main()
