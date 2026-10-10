"""Модели объектов мира (VR-7, VR-12): ветроуказатель, вешка с лентой. Деревья у посадки — общие assets/models/trees/.

Запуск:  blender --background --python tools/blender/world_objects/build_world_objects.py [-- имя…]
Имена: windsock streamer (по умолчанию все).
Результат: assets/models/world/<имя>.glb, исходники assets/source/world/<имя>.blend.

Оси Blender: X вправо, +Y вперёд, Z вверх → Godot: X, −Z, Y. 1 ед. = 1 м.
Ветроуказатель и вешка: пустышка Pivot — ось вращения по ветру; меш Sock/Ribbon — дочерний
к Pivot, вытянут вдоль +Y Blender (= −Z Godot, «по ветру»); его гнёт вершинный шейдер
scripts/world_objects/wind_cloth.gdshader (провисание, болтание). Полосы — отдельные материалы.
"""
import math
import os
import sys

from mathutils import Vector

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import bl_util as U  # noqa: E402

ORANGE = (1.0, 0.36, 0.04)
WHITE = (0.93, 0.93, 0.91)
RED = (0.85, 0.08, 0.06)

# Ветроуказатель (как лёгкий парапланерный конус на мачте): размеры, м.
MAST_H = 4.0
PIVOT_H = 3.85
SOCK_LEN = 2.4
SOCK_R0 = 0.25
SOCK_R1 = 0.11
SOCK_ROOT_Y = 0.32      # центр обруча от оси мачты (вертлюг)
SOCK_STRIPES = 5
SOCK_RINGS_PER_STRIPE = 6
SOCK_SIDES = 16
# Вешка с лентой.
POLE_H = 1.8
RIBBON_LEN = 1.2
RIBBON_W = 0.05
RIBBON_ROOT_Y = 0.02
RIBBON_SEG = 24


def mats(**spec) -> dict:
    return {k: U.material(k, U.srgb(v[0]), rough=v[1], double=len(v) > 2 and v[2])
            for k, v in spec.items()}


def windsock() -> None:
    m = mats(Mast=((0.72, 0.73, 0.74), 0.45), Hoop=((0.25, 0.25, 0.27), 0.4),
             SockOrange=(ORANGE, 0.8, True), SockWhite=(WHITE, 0.8, True))
    root = U.empty("Windsock", (0, 0, 0))
    mast = U.MeshBuilder()
    mast.add_tube([(0, 0, -0.3), (0, 0, MAST_H)], [0.045, 0.03], "Mast", sides=8)
    mast.build("Mast", m, parent=root)
    pivot = U.empty("Pivot", (0, 0, PIVOT_H), parent=root)
    sw = U.MeshBuilder()  # вертлюг: хомут на мачте + рычаг до обруча
    sw.add_tube([(0, 0, PIVOT_H - 0.06), (0, 0, PIVOT_H + 0.06)], 0.05, "Hoop", sides=8)
    sw.add_tube([(0, 0, PIVOT_H), (0, SOCK_ROOT_Y - SOCK_R0, PIVOT_H)], 0.012, "Hoop", sides=6)
    sw.verts = [tuple(Vector(v) - Vector((0, 0, PIVOT_H))) for v in sw.verts]
    sw.build("Swivel", m, parent=pivot)
    sock = U.MeshBuilder()
    rings = SOCK_STRIPES * SOCK_RINGS_PER_STRIPE
    for s in range(SOCK_STRIPES):
        grid = []
        for i in range(SOCK_RINGS_PER_STRIPE + 1):
            t = (s * SOCK_RINGS_PER_STRIPE + i) / rings
            y = SOCK_ROOT_Y + t * SOCK_LEN
            r = SOCK_R0 + (SOCK_R1 - SOCK_R0) * t
            grid.append([(r * math.cos(2 * math.pi * k / SOCK_SIDES), y,
                          r * math.sin(2 * math.pi * k / SOCK_SIDES))
                         for k in range(SOCK_SIDES)])
        sock.add_grid(grid, "SockOrange" if s % 2 == 0 else "SockWhite", wrap=True)
    hoop = [(SOCK_R0 * math.cos(2 * math.pi * k / 24), SOCK_ROOT_Y,
             SOCK_R0 * math.sin(2 * math.pi * k / 24)) for k in range(24)]
    sock.add_tube(hoop, 0.008, "Hoop", sides=5, closed=True, up=(0, 1, 0))
    sock.build("Sock", m, parent=pivot)
    U.export("world/windsock")


def streamer() -> None:
    m = mats(Pole=((0.55, 0.42, 0.28), 0.8), RibbonRed=(RED, 0.6, True),
             RibbonWhite=(WHITE, 0.6, True))
    root = U.empty("Streamer", (0, 0, 0))
    pole = U.MeshBuilder()
    pole.add_tube([(0, 0, -0.2), (0, 0, POLE_H)], [0.015, 0.01], "Pole", sides=6)
    pole.build("Pole", m, parent=root)
    pivot = U.empty("Pivot", (0, 0, POLE_H - 0.02), parent=root)
    rb = U.MeshBuilder()
    per = RIBBON_SEG // 6
    for s in range(6):
        grid = []
        for i in range(per + 1):
            y = RIBBON_ROOT_Y + (s * per + i) / RIBBON_SEG * RIBBON_LEN
            grid.append([(0, y, -RIBBON_W / 2), (0, y, RIBBON_W / 2)])
        rb.add_grid(grid, "RibbonRed" if s % 2 == 0 else "RibbonWhite", smooth=False)
    rb.build("Ribbon", m, parent=pivot)
    U.export("world/streamer")


BUILDERS = {f.__name__: f for f in (windsock, streamer)}


def main() -> None:
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    for name in argv or list(BUILDERS):
        U.reset_scene()
        BUILDERS[name]()


if __name__ == "__main__":
    main()
