"""Машинки для трафика OSM (OsmTraffic): assets/models/osm/{car,van,truck}.glb
(+ assets/source/osm/*.blend).

    blender --background --python tools/blender/build_osm_traffic.py

Единицы — м; оси Blender (+Z вверх, нос машины к −Y Blender = +Z Godot). Начало — центр кузова
на уровне земли (колёса касаются плоскости y=0 Godot). В каждом .glb одна нода-меш с материалами:
  paint — красится цветом экземпляра MultiMesh (у грузовика — только кабина), белый;
  cargo — кузов грузовика (светло-серый, не красится); glass — стёкла; dark — колёса, низ, бамперы.
car — легковушка ~4,2 м, van — фургон ~5,5 м, truck — грузовик ~9 м (кабина + кузов-фура).
"""
import math
import os
import sys

import bpy

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bl_util as U  # noqa: E402

OUT = os.path.join(U.MODELS, "osm")


def mats() -> dict:
    return {
        "paint": U.material("paint", (0.9, 0.9, 0.9), rough=0.35, metal=0.1, double=True),
        "cargo": U.material("cargo", U.srgb((0.78, 0.79, 0.8)), rough=0.6, double=True),
        "glass": U.material("glass", U.srgb((0.08, 0.1, 0.13)), rough=0.1, metal=0.3, double=True),
        "dark": U.material("dark", U.srgb((0.06, 0.06, 0.07)), rough=0.8, double=True),
    }


def prism(mb: U.MeshBuilder, prof, hw: float, mat: str, hw_top: float = None) -> None:
    """Призма: профиль [(y, z), ...] (по кругу) выдавлен по X на ±hw (hw_top — верхние точки уже)."""
    zmax = max(p[1] for p in prof)
    zmin = min(p[1] for p in prof)
    def w(z):
        if hw_top is None:
            return hw
        return hw + (hw_top - hw) * (z - zmin) / max(zmax - zmin, 1e-6)
    r = [mb.add_vert((w(z), y, z)) for y, z in prof]
    l = [mb.add_vert((-w(z), y, z)) for y, z in prof]
    mb.add_face(r, mat, smooth=False)
    mb.add_face(list(reversed(l)), mat, smooth=False)
    n = len(prof)
    for i in range(n):
        j = (i + 1) % n
        mb.add_face([r[i], r[j], l[j], l[i]], mat, smooth=False)


def box(mb, y0, y1, z0, z1, hw, mat):
    mb.add_box(((0.0), (y0 + y1) / 2, (z0 + z1) / 2), (2 * hw, y1 - y0, z1 - z0), mat)


def wheels(mb, axles, hw, r, w=0.25):
    for y in axles:
        for sx in (-1, 1):
            x = sx * (hw - w * 0.4)
            mb.add_tube([(x - w / 2, y, r), (x + w / 2, y, r)], r, "dark", sides=8, smooth=False)


def build_car():
    mb = U.MeshBuilder()
    L = 4.2
    hw = 0.88
    # кузов: нос к −Y
    prism(mb, [(-2.1, 0.32), (-2.1, 0.78), (-1.5, 0.9), (-0.55, 0.95), (1.3, 0.95), (2.1, 0.85), (2.1, 0.32)], hw, "paint")
    prism(mb, [(-0.75, 0.94), (-0.25, 1.42), (1.0, 1.42), (1.55, 0.94)], 0.76, "glass", hw_top=0.68)
    box(mb, -0.3, 0.95, 1.41, 1.46, 0.66, "paint")
    box(mb, -2.13, -2.0, 0.3, 0.55, hw, "dark")
    box(mb, 2.0, 2.13, 0.3, 0.55, hw, "dark")
    wheels(mb, [-1.35, 1.3], hw, 0.31)
    return mb, L


def build_van():
    mb = U.MeshBuilder()
    hw = 0.97
    prism(mb, [(-2.75, 0.36), (-2.75, 0.95), (-2.0, 1.3), (-1.2, 2.2), (2.5, 2.2), (2.75, 2.0), (2.75, 0.36)], hw, "paint")
    prism(mb, [(-1.95, 1.34), (-1.3, 2.05), (-0.3, 2.05), (-0.3, 1.34)], hw + 0.01, "glass")
    box(mb, -2.78, -2.6, 0.3, 0.6, hw, "dark")
    box(mb, 2.6, 2.78, 0.3, 0.6, hw, "dark")
    box(mb, -2.6, 2.6, 0.3, 0.5, hw - 0.05, "dark")
    wheels(mb, [-1.75, 1.75], hw, 0.36, 0.28)
    return mb, 5.5


def build_truck():
    mb = U.MeshBuilder()
    hw = 1.2
    # кабина (красится)
    prism(mb, [(-4.5, 0.6), (-4.5, 2.1), (-4.0, 2.8), (-2.9, 2.8), (-2.9, 0.6)], hw, "paint")
    prism(mb, [(-4.48, 1.5), (-4.48, 2.15), (-4.05, 2.7), (-3.2, 2.7), (-3.2, 1.5)], hw + 0.01, "glass")
    # рама и кузов-фура
    box(mb, -4.5, 4.5, 0.55, 0.95, 1.0, "dark")
    box(mb, -2.75, 4.5, 0.95, 3.5, 1.28, "cargo")
    box(mb, -4.55, -4.4, 0.45, 0.8, hw, "dark")
    wheels(mb, [-3.5, 2.4, 3.7], 1.15, 0.5, 0.32)
    return mb, 9.0


def main() -> None:
    os.makedirs(OUT, exist_ok=True)
    for stem, fn in (("car", build_car), ("van", build_van), ("truck", build_truck)):
        U.reset_scene()
        m = mats()
        mb, _ = fn()
        mb.build(stem, m)
        print("TRIS", stem, U.tri_count())
        U.export("osm/" + stem)


main()
