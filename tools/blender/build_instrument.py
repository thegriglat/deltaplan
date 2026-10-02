"""Полётный компьютер-планшет на центре базовой штанги (e-reader с XCSoar / телефон с XCTrack
в защитном чехле на кронштейне): assets/models/instrument.glb (+ assets/source/instrument.blend).

    blender --background --python tools/blender/build_instrument.py

Контракт (docs/guide/models.md): ноды Body (чехол, кнопка, кронштейн, хомут) и Screen (квад экрана,
UV 0..1 на весь экран: в Godot u слева направо, v сверху вниз — туда идёт ViewportTexture).
Начало координат — ось базовой штанги (маркер InstrumentMount крыла): хомут охватывает штангу
вдоль X, планшет стоит на ножке над штангой. Экран смотрит в +Y Blender = −Z Godot (маркер
повёрнут так, что −Z смотрит на глаза пилота), верх экрана — +Z Blender = +Y Godot.
"""
import math
import os
import sys

from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bl_util as U  # noqa: E402

W, H, D = 0.122, 0.168, 0.02       # чехол: ширина, высота, толщина, м (6" e-reader)
CORNER = 0.012
SCREEN = (0.092, 0.123)            # экран 3:4 портрет (6"), м
SCREEN_UP = 0.008                  # экран чуть выше центра (снизу — кнопка/поле чехла)
LIFT = 0.115                       # центр планшета над осью штанги, м
BAR_R = 0.019                      # радиус базовой штанги


def case(mb: U.MeshBuilder) -> None:
    prof = U.rounded_rect(W, H, CORNER)
    yf, yb = D * 0.5, -D * 0.5
    rings = [[Vector((x * k, y, LIFT + z * k)) for x, z in prof]
             for y, k in ((yf, 0.985), (yf - 0.003, 1.0), (yb + 0.004, 1.0), (yb, 0.96))]
    mb.add_grid(rings, "Case", wrap=True, flip=True)
    front = [mb.add_vert(p) for p in rings[0]]
    mb.add_face(list(reversed(front)), "Case", smooth=False)
    back = [mb.add_vert(p) for p in rings[-1]]
    mb.add_face(back, "Case", smooth=False)
    # стекло-рамка экрана и кнопка снизу
    mb.add_box((0, yf + 0.0006, LIFT + SCREEN_UP), (SCREEN[0] + 0.008, 0.0012,
                                                     SCREEN[1] + 0.008), "Glass")
    zb = LIFT - H / 2 + 0.012
    mb.add_tube([(0, yf - 0.001, zb), (0, yf + 0.0025, zb)], 0.006, "Button", sides=10)


def bracket(mb: U.MeshBuilder) -> None:
    # хомут вокруг штанги (ось X) с барашком
    for x in (-0.02, 0.02):
        ring = [(x, (BAR_R + 0.004) * math.cos(a), (BAR_R + 0.004) * math.sin(a))
                for a in [2 * math.pi * k / 14 for k in range(14)]]
        mb.add_tube(ring, 0.005, "Clamp", sides=6, closed=True, up=(1, 0, 0))
    mb.add_box((0, 0, BAR_R + 0.008), (0.05, 0.03, 0.012), "Clamp")
    mb.add_tube([(0.025, 0, BAR_R + 0.008), (0.045, 0, BAR_R + 0.008)], 0.006, "Button",
                sides=8)
    # ножка с шаровым шарниром к задней пластине чехла
    top = Vector((0, -D * 0.5 - 0.012, LIFT - 0.02))
    mb.add_tube([(0, 0, BAR_R + 0.012), top], 0.008, "Clamp", sides=8)
    mb.add_ellipsoid(top, (0.013, 0.013, 0.013), "Clamp", 10, 6)
    mb.add_box((0, -D * 0.5 - 0.004, LIFT - 0.005), (0.06, 0.008, 0.08), "Clamp")


def main() -> None:
    U.reset_scene()
    mats = {
        "Case": U.material("InstrumentCase", U.srgb((0.12, 0.13, 0.14)), rough=0.8),
        "Glass": U.material("InstrumentBezel", U.srgb((0.03, 0.03, 0.035)), rough=0.15),
        "Button": U.material("InstrumentButton", U.srgb((0.95, 0.45, 0.05)), rough=0.5),
        "Clamp": U.material("InstrumentClamp", U.srgb((0.35, 0.36, 0.38)), rough=0.4, metal=0.7),
        "Screen": U.material("InstrumentScreen", U.srgb((0.78, 0.8, 0.76)), rough=0.35),
    }
    mb = U.MeshBuilder()
    case(mb)
    bracket(mb)
    mb.build("Body", mats)
    U.screen_quad(SCREEN, D * 0.5 + 0.0014, LIFT + SCREEN_UP).build("Screen", mats)
    U.export("instrument")


if __name__ == "__main__":
    main()
