"""Вариометр в стиле 1990-х на нижней перекладине трапеции (обобщённый: коробочка со стрелочной
шкалой, без брендов): assets/models/vario_90s.glb (+ assets/source/vario_90s.blend).

    blender --background --python tools/blender/build_vario90s.py

Контракт (docs/guide/models.md): ноды Body (корпус, кнопки, хомут) и Screen (круглый циферблат,
UV 0..1 по описанному квадрату — туда идёт текстура циферблата из SubViewport; при взгляде
спереди u слева направо, v сверху вниз в Godot). Начало координат — ось базовой штанги
(маркер VarioMount крыла, A3.3 v9): хомут охватывает штангу вдоль X, корпус на ножке LIFT (0,10 м
< 0,15) вдоль +Z. Экран смотрит в +Y Blender = −Z Godot (на глаза), верх — +Z Blender = +Y Godot
(маркер повёрнут так, что верх экрана — вперёд, ножка идёт от штанги вперёд-вниз).
"""
import math
import os
import sys

from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bl_util as U  # noqa: E402

W, H, D = 0.086, 0.125, 0.036      # корпус, м
CORNER = 0.018
DIAL = 0.066                       # диаметр циферблата
DIAL_UP = 0.018                    # центр циферблата выше центра корпуса
TUBE_R = 0.019                     # базовая штанга
LIFT = 0.10                        # центр корпуса над осью штанги вдоль ножки, м
Y0 = 0.0                           # задняя стенка корпуса


def case(mb: U.MeshBuilder) -> None:
    prof = U.rounded_rect(W, H, CORNER)
    yf, yb = Y0 + D, Y0
    rings = [[Vector((x * k, y, LIFT + z * k)) for x, z in prof]
             for y, k in ((yf, 0.96), (yf - 0.004, 1.0), (yb, 1.0))]
    mb.add_grid(rings, "Case", wrap=True, flip=True)
    front = [mb.add_vert(p) for p in rings[0]]
    mb.add_face(list(reversed(front)), "Case", smooth=False)
    back = [mb.add_vert(p) for p in rings[-1]]
    mb.add_face(back, "Case", smooth=False)
    # хромированное кольцо-оправа циферблата
    ring = [(0.5 * DIAL * 1.08 * math.cos(a), yf + 0.003, LIFT + DIAL_UP + 0.5 * DIAL * 1.08 * math.sin(a))
            for a in [2 * math.pi * k / 32 for k in range(32)]]
    mb.add_tube(ring, 0.0035, "Chrome", sides=6, closed=True, up=(0, 1, 0))
    # блок круглых кнопок под шкалой (2×2 серые + красная — звук)
    for x, z, mat in ((-0.018, -0.03, "Key"), (0.018, -0.03, "Key"), (-0.018, -0.047, "Key"),
                      (0.018, -0.047, "Key"), (0.0, -0.0385, "Button")):
        mb.add_tube([(x, yf - 0.002, LIFT + z), (x, yf + 0.004, LIFT + z)], 0.0065, mat, sides=10)


def clamp(mb: U.MeshBuilder) -> None:
    # хомут вокруг штанги (ось X) с барашком + ножка к пластине на спинке корпуса
    for x in (-0.025, 0.025):
        ring = [(x, (TUBE_R + 0.004) * math.cos(a), (TUBE_R + 0.004) * math.sin(a))
                for a in [2 * math.pi * k / 14 for k in range(14)]]
        mb.add_tube(ring, 0.004, "Clamp", sides=6, closed=True)
    mb.add_box((0, 0, TUBE_R + 0.008), (0.05, 0.03, 0.012), "Clamp")
    mb.add_tube([(0, 0, TUBE_R + 0.012), (0, Y0 - 0.006, LIFT - 0.02)], 0.007, "Clamp", sides=8)
    mb.add_box((0, Y0 - 0.004, LIFT), (0.04, 0.008, 0.07), "Clamp")


def main() -> None:
    U.reset_scene()
    mats = {
        "Case": U.material("VarioCase", U.srgb((0.1, 0.1, 0.1)), rough=0.5),
        "Chrome": U.material("VarioChrome", U.srgb((0.8, 0.8, 0.82)), rough=0.2, metal=1.0),
        "Button": U.material("VarioButton", U.srgb((0.75, 0.1, 0.08)), rough=0.5),
        "Key": U.material("VarioKey", U.srgb((0.3, 0.31, 0.33)), rough=0.6),
        "Clamp": U.material("VarioClamp", U.srgb((0.25, 0.25, 0.27)), rough=0.5, metal=0.6),
        "Screen": U.material("VarioDial", U.srgb((0.92, 0.92, 0.88)), rough=0.3),
    }
    mb = U.MeshBuilder()
    case(mb)
    clamp(mb)
    mb.build("Body", mats)
    U.screen_quad((DIAL, DIAL), Y0 + D + 0.001, LIFT + DIAL_UP, circle_seg=32).build("Screen", mats)
    U.export("vario_90s")


if __name__ == "__main__":
    main()
