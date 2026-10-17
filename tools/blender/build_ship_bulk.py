"""Сухогруз-балкер типа Supramax: assets/models/ships/ship_bulk.glb (+ assets/source/ships/ship_bulk.blend).

    blender --background --python tools/blender/build_ship_bulk.py
    SHIP_PREVIEW=<папка> blender --background --python tools/blender/build_ship_bulk.py   # + 2 кадра JPEG

Контракт S4 (docs/contracts/sea-ships.md): узлы bulk_LOD0 (≤ 4000 тр.), bulk_LOD1 (≤ 600), bulk_LOD2
(≤ 80). Оси Godot: +Y вверх, нос к −Z, начало — ватерлиния в середине длины, 1 = 1 м. В Blender строим в
его осях (X — поперёк, +Y — к носу, Z — вверх), экспорт «+Y up» переводит в оси Godot.
Образец подхода — tools/blender/build_ship_tanker.py (SEA-3); класс FlatMesh и сборка скопированы оттуда.

Размеры (configs/sea_ships.json → types.bulk): длина 225 м, ширина 32 м, осадка 12 м (гружёный),
надводный борт 8 м, бак +2,5 м. Ниже ватерлинии — только 2 м корпуса (вода непрозрачна). Обводы полнее
танкерных (балкер, коэффициент общей полноты ~0,85): короткие сужения в нос (28 м) и в корму (20 м).
Палуба: 5 трюмных люков 24 × 18 м (комингс 1,8 м + крышка с гребнем), между ними 4 палубных крана
по ДП (колонна 12 м, кабина, стрела 24 м уложена к носу на упор на крышке люка) — как у Supramax
(5 трюмов, 4 крана ~30 т). Надстройка в корме: 5 ярусов по 2,8 м + ходовой мостик с крыльями на всю
ширину, за ней машинная шахта и труба, на корме — спасательная шлюпка свободного падения.

Материал один (белый), цвет — вершинные цвета (COLOR_0) по граням, без текстур; нормали плоские
(у каждой грани свои вершины). Скрипт детерминирован (случайности нет).
"""
import math
import os
import sys

import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bl_util as U  # noqa: E402

KIND = "bulk"
OUT = os.path.join(U.MODELS, "ships")
SRC = os.path.join(U.SOURCE, "ships")

LENGTH = 225.0      # м, наибольшая длина по палубе
BEAM = 32.0         # м
FREEBOARD = 8.0     # м, палуба над ватерлинией (гружёный, 7–9 м)
UNDER = 2.0         # м корпуса ниже ватерлинии
FOC_H = 2.5         # м, бак над палубой
TIER = 2.8          # м, высота яруса надстройки

HB = BEAM / 2
Y_STERN = -LENGTH / 2
Y_BOW = LENGTH / 2
Y_FWD = 84.0        # начало сужения в нос (по палубе)
Y_AFT = -92.0       # начало сужения в корму
Y_FOC = 98.0        # передняя переборка бака

# трюмные люки: 5 штук вдоль палубы, между ними краны
N_HATCH = 5
HATCH_L = 24.0      # м, длина люка
HATCH_GAP = 11.0    # м, промежуток между люками (кран)
HATCH_Y0 = -82.0    # кормовой край первого люка
HATCH_HX = 9.0      # полуширина комингса (люк 18 м при ширине 32 м)
COAM_H = 1.8        # м, высота комингса
COVER_H = 1.0       # м, подъём гребня крышки над комингсом

# цвета sRGB 0..1 (переводятся в линейные)
C_HULL = (0.11, 0.11, 0.12)      # чёрный борт
C_BOTTOM = (0.45, 0.10, 0.08)    # красная подводная часть
C_DECK = (0.24, 0.29, 0.25)      # серо-зелёная палуба
C_HATCH = (0.50, 0.23, 0.15)     # красно-бурые крышки люков
C_SEAM = (0.30, 0.14, 0.10)      # стыки секций крышек
C_CRANE = (0.86, 0.68, 0.12)     # жёлтые краны
C_WHITE = (0.88, 0.88, 0.85)     # надстройка
C_WIN = (0.10, 0.12, 0.14)       # окна
C_PIPE = (0.62, 0.62, 0.58)      # мачты, лебёдки, вентиляторы
C_DARK = (0.08, 0.08, 0.08)      # верх трубы
C_FUNNEL = (0.14, 0.22, 0.38)    # труба (тёмно-синяя)
C_BAND = (0.88, 0.88, 0.85)      # белая полоса на трубе
C_BOAT = (0.95, 0.42, 0.05)      # шлюпка


class FlatMesh:
    """Грани с собственными вершинами (плоские нормали) и цветом грани."""

    def __init__(self):
        self.verts: list = []
        self.faces: list = []
        self.cols: list = []

    def poly(self, pts, col) -> None:
        clean = []
        for p in pts:
            p = Vector(p)
            if not clean or (p - clean[-1]).length > 1e-4:
                clean.append(p)
        if len(clean) > 1 and (clean[0] - clean[-1]).length <= 1e-4:
            clean.pop()
        if len(clean) < 3:
            return
        n = Vector()
        for i in range(1, len(clean) - 1):
            n += (clean[i] - clean[0]).cross(clean[i + 1] - clean[0])
        if n.length < 1e-6:
            return
        base = len(self.verts)
        self.verts.extend(tuple(p) for p in clean)
        self.faces.append(tuple(range(base, base + len(clean))))
        self.cols.append(U.srgb(col))

    def box(self, c, size, col, rot: Matrix = None, bottom: bool = False, cols=None) -> None:
        """Коробка; cols — цвета граней (+X, −X, +Y, −Y, +Z, −Z), иначе все col."""
        c = Vector(c)
        rot = rot or Matrix.Identity(3)
        h = [s * 0.5 for s in size]

        def P(sx, sy, sz):
            return c + rot @ Vector((sx * h[0], sy * h[1], sz * h[2]))
        quads = [
            [P(1, -1, -1), P(1, 1, -1), P(1, 1, 1), P(1, -1, 1)],
            [P(-1, 1, -1), P(-1, -1, -1), P(-1, -1, 1), P(-1, 1, 1)],
            [P(1, 1, -1), P(-1, 1, -1), P(-1, 1, 1), P(1, 1, 1)],
            [P(-1, -1, -1), P(1, -1, -1), P(1, -1, 1), P(-1, -1, 1)],
            [P(-1, -1, 1), P(1, -1, 1), P(1, 1, 1), P(-1, 1, 1)],
            [P(-1, 1, -1), P(1, 1, -1), P(1, -1, -1), P(-1, -1, -1)],
        ]
        for k, q in enumerate(quads):
            if k == 5 and not bottom:
                continue
            self.poly(q, cols[k] if cols else col)

    def span(self, x0, y0, z0, x1, y1, z1, col, **kw) -> None:
        """Коробка по углам."""
        self.box(((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2),
                 (abs(x1 - x0), abs(y1 - y0), abs(z1 - z0)), col, **kw)

    def prism(self, center, rx, ry, levels, sides, rake=0.0, top=True) -> None:
        """Вертикальная призма-эллипс: levels — [(z, цвет пояса над этим z)…, (z_top, цвет крышки)].
        rake — смещение по −Y на метр высоты (завал трубы в корму)."""
        cx, cy = center
        rings = []
        for z, _ in levels:
            dz = z - levels[0][0]
            rings.append([Vector((cx + rx * math.cos(2 * math.pi * k / sides),
                                  cy - rake * dz + ry * math.sin(2 * math.pi * k / sides), z))
                          for k in range(sides)])
        for i in range(len(rings) - 1):
            for k in range(sides):
                k2 = (k + 1) % sides
                self.poly([rings[i][k], rings[i][k2], rings[i + 1][k2], rings[i + 1][k]],
                          levels[i][1])
        if top:
            self.poly(rings[-1], levels[-1][1])

    def tris(self) -> int:
        return sum(len(f) - 2 for f in self.faces)

    def build(self, name: str, mat) -> bpy.types.Object:
        me = bpy.data.meshes.new(name)
        me.from_pydata(self.verts, [], self.faces)
        ca = me.color_attributes.new("Col", "FLOAT_COLOR", "CORNER")
        data = []
        for f, col in zip(me.polygons, self.cols):
            data.extend([col[0], col[1], col[2], 1.0] * f.loop_total)
        ca.data.foreach_set("color", data)
        me.color_attributes.active_color = ca
        me.color_attributes.render_color_index = 0
        me.polygons.foreach_set("use_smooth", [False] * len(me.polygons))
        me.materials.append(mat)
        me.validate()
        me.update()
        ob = bpy.data.objects.new(name, me)
        bpy.context.scene.collection.objects.link(ob)
        return ob



# ---------------------------------------------------------------- корпус

def _bow(s: float):
    """Нос: s 0 → 1 от Y_FWD до форштевня. (y_дна, y_ватерл, y_палубы, полуширины дно/ватерл/палуба)."""
    yd = Y_FWD + s * (Y_BOW - Y_FWD)
    yw = Y_FWD + s * (Y_BOW - 3.5 - Y_FWD)          # завал форштевня 3,5 м на надводный борт
    yb = Y_FWD + s * (Y_BOW - 5.0 - Y_FWD)
    wd = HB * max(0.0, 1.0 - s ** 2.4) ** 0.5        # полный нос балкера, развал бортов
    ww = HB * max(0.0, 1.0 - s ** 2.0) ** 0.65
    wb = (HB - 0.8) * max(0.0, 1.0 - s ** 1.7) ** 0.75
    return yb, yw, yd, wb, ww, wd


def _stern(s: float):
    """Корма: s 0 → 1 от Y_AFT до транца (свес кормы над пером руля)."""
    yd = Y_AFT + s * (Y_STERN - Y_AFT)
    yw = Y_AFT + s * (Y_STERN + 3.5 - Y_AFT)
    yb = Y_AFT + s * (Y_STERN + 7.5 - Y_AFT)
    wd = HB * (1.0 - 0.20 * s ** 3)
    ww = HB * (1.0 - 0.42 * s ** 2.5)
    wb = (HB - 0.8) * (1.0 - 0.72 * s ** 2)
    return yb, yw, yd, wb, ww, wd


def hull(fm: FlatMesh, bow_s, stern_s, waterline: bool = True, foc: bool = True) -> None:
    """Корпус: станции от транца к форштевню, сечение — дно, ватерлиния, палуба (обход по кругу)."""
    st = []  # (yb, yw, yd, wb, ww, wd, z_deck)
    for s in reversed(stern_s):
        st.append(_stern(s) + (FREEBOARD,))
    for s in bow_s:
        g = _bow(s)
        if foc and abs(g[2] - Y_FOC) < 1e-6:
            st.append(g + (FREEBOARD,))
            st.append(g + (FREEBOARD + FOC_H,))
        else:
            st.append(g + (FREEBOARD + (FOC_H if foc and g[2] > Y_FOC else 0.0),))

    def ring(t):
        yb, yw, yd, wb, ww, wd, zd = t
        if waterline:
            return [(-wb, yb, -UNDER), (-ww, yw, 0.0), (-wd, yd, zd),
                    (wd, yd, zd), (ww, yw, 0.0), (wb, yb, -UNDER)]
        return [(-wb, yb, -UNDER), (-wd, yd, zd), (wd, yd, zd), (wb, yb, -UNDER)]
    if waterline:
        cols = [C_BOTTOM, C_HULL, C_DECK, C_HULL, C_BOTTOM, C_BOTTOM]
    else:
        cols = [C_HULL, C_DECK, C_HULL, C_BOTTOM]
    rings = [ring(t) for t in st]
    n = len(rings[0])
    for i in range(len(rings) - 1):
        a, b = rings[i], rings[i + 1]
        for k in range(n):
            k2 = (k + 1) % n
            col = cols[k]
            if col == C_DECK and abs(st[i][6] - st[i + 1][6]) > 1e-6 and abs(st[i][2] - st[i + 1][2]) < 1e-6:
                col = C_WHITE   # передняя переборка бака
            fm.poly([a[k], a[k2], b[k2], b[k]], col)
    # транец (смотрит в −Y) и форштевень (вырождается в линию — грань отбрасывается)
    fm.poly(rings[0][::-1], C_HULL)
    fm.poly(rings[-1], C_HULL)


# ---------------------------------------------------------------- палуба: люки и краны

def hatch_spans():
    """[(y0, y1)] люков от кормы к носу."""
    return [(HATCH_Y0 + k * (HATCH_L + HATCH_GAP), HATCH_Y0 + k * (HATCH_L + HATCH_GAP) + HATCH_L)
            for k in range(N_HATCH)]


def crane_ys():
    """Колонны кранов — посередине промежутков между люками."""
    h = hatch_spans()
    return [(h[k][1] + h[k + 1][0]) / 2 for k in range(N_HATCH - 1)]


def _cover(fm: FlatMesh, y0: float, y1: float, seams: int) -> None:
    """Крышка люка: двускатная с гребнем по ДП, чуть шире комингса; поперечные стыки секций."""
    zd = FREEBOARD
    z0, z1 = zd + COAM_H, zd + COAM_H + COVER_H
    hx = HATCH_HX + 0.3
    y0, y1 = y0 - 0.3, y1 + 0.3
    zs = z0 + 0.4                                  # край крышки (боковая кромка 0,4 м)
    for sx in (-1, 1):
        # боковая кромка и скат
        side = [(sx * hx, y0, z0), (sx * hx, y1, z0), (sx * hx, y1, zs), (sx * hx, y0, zs)]
        fm.poly(side if sx > 0 else side[::-1], C_HATCH)
        slope = [(sx * hx, y0, zs), (sx * hx, y1, zs), (0.0, y1, z1), (0.0, y0, z1)]
        fm.poly(slope if sx < 0 else slope[::-1], C_HATCH)
    # торцы (пятиугольники)
    fm.poly([(hx, y1, z0), (-hx, y1, z0), (-hx, y1, zs), (0.0, y1, z1), (hx, y1, zs)], C_HATCH)
    fm.poly([(-hx, y0, z0), (hx, y0, z0), (hx, y0, zs), (0.0, y0, z1), (-hx, y0, zs)], C_HATCH)
    # стыки секций — тёмные полосы поперёк ската, чуть над крышкой
    e = 0.06
    for i in range(1, seams + 1):
        y = y0 + (y1 - y0) * i / (seams + 1)
        for sx in (-1, 1):
            pts = [(sx * hx, y - 0.25, zs + e), (sx * hx, y + 0.25, zs + e),
                   (0.0, y + 0.25, z1 + e), (0.0, y - 0.25, z1 + e)]
            fm.poly(pts if sx < 0 else pts[::-1], C_SEAM)


def hatches(fm: FlatMesh, lod: int) -> None:
    zd = FREEBOARD
    if lod == 2:
        y0, y1 = hatch_spans()[0][0], hatch_spans()[-1][1]
        fm.span(-HATCH_HX, y0, zd, HATCH_HX, y1, zd + COAM_H + COVER_H, C_HATCH)
        return
    for y0, y1 in hatch_spans():
        if lod == 0:
            fm.span(-HATCH_HX, y0, zd, HATCH_HX, y1, zd + COAM_H, C_HATCH)   # комингс
            _cover(fm, y0, y1, 3)
        else:
            fm.span(-HATCH_HX, y0, zd, HATCH_HX, y1, zd + COAM_H + COVER_H * 0.6, C_HATCH)


def cranes(fm: FlatMesh, lod: int) -> None:
    """Палубные краны по ДП: колонна, кабина, стрела уложена к носу на упор над крышкой люка."""
    if lod == 2:
        return
    zd = FREEBOARD
    z_ped = zd + 12.0          # верх колонны
    z_cab = z_ped + 3.5        # крыша кабины
    boom_len = 24.0
    for yc in crane_ys():
        piv = Vector((0.0, yc + 2.0, z_ped + 2.0))
        tip_y = yc + 2.0 + 22.5
        tip = Vector((0.0, tip_y, piv.z - math.sqrt(boom_len ** 2 - 22.5 ** 2)))
        mid = (piv + tip) / 2
        ang = math.atan2(tip.z - piv.z, tip.y - piv.y)
        rot = Matrix.Rotation(ang, 3, "X")
        if lod == 0:
            fm.span(-1.6, yc - 1.6, zd, 1.6, yc + 1.6, z_ped, C_CRANE)                  # колонна
            fm.span(-2.6, yc - 3.2, z_ped, 2.6, yc + 2.8, z_cab, C_CRANE)               # кабина/машинное
            fm.poly([(1.2, yc + 2.86, z_ped + 1.6), (-1.2, yc + 2.86, z_ped + 1.6),
                     (-1.2, yc + 2.86, z_ped + 2.9), (1.2, yc + 2.86, z_ped + 2.9)], C_WIN)
            fm.span(-0.5, yc - 2.0, z_cab, 0.5, yc - 1.0, z_cab + 3.0, C_CRANE)          # стойка шкивов
            fm.box(mid, (1.4, boom_len, 1.4), C_CRANE, rot=rot, bottom=True)            # стрела
            # упор стрелы на крышке люка
            z_top = zd + COAM_H + COVER_H
            fm.span(-0.4, tip_y - 1.8, z_top, 0.4, tip_y - 1.0, tip.z - 0.6, C_PIPE)
        else:
            fm.span(-2.2, yc - 2.4, zd, 2.2, yc + 2.4, z_cab, C_CRANE)
            fm.box(mid, (1.4, boom_len, 1.4), C_CRANE, rot=rot, bottom=True)


def deck_gear(fm: FlatMesh, lod: int) -> None:
    if lod != 0:
        return
    zd = FREEBOARD
    # грибовидные вентиляторы трюмов у бортов в промежутках между люками
    for yc in crane_ys():
        for sx in (-1, 1):
            fm.span(sx * 12.5 - 0.6, yc - 0.6, zd, sx * 12.5 + 0.6, yc + 0.6, zd + 2.2, C_PIPE)
            fm.span(sx * 12.5 - 1.0, yc - 1.0, zd + 2.2, sx * 12.5 + 1.0, yc + 1.0, zd + 2.6, C_PIPE)
    # бак: брашпили и фок-мачта
    zf = FREEBOARD + FOC_H
    for sx in (-1, 1):
        fm.span(sx * 5.0 - 1.6, 102.0, zf, sx * 5.0 + 1.6, 105.5, zf + 1.5, C_PIPE)
    fm.span(-0.4, 107.5, zf, 0.4, 108.3, zf + 11.0, C_PIPE)
    fm.span(-1.8, 107.5, zf + 8.5, 1.8, 108.3, zf + 8.9, C_PIPE)
    # кормовые швартовные лебёдки
    for sx in (-1, 1):
        fm.span(sx * 10.0 - 1.4, -110.0, zd, sx * 10.0 + 1.4, -107.2, zd + 1.3, C_PIPE)


# ---------------------------------------------------------------- надстройка

HY0, HY1 = -100.0, -87.0       # надстройка по длине (корма → нос)
HX = 12.0                      # полуширина надстройки
N_TIERS = 5                    # жилые ярусы под мостиком
CAS_Y0 = -106.0                # машинная шахта: от CAS_Y0 до надстройки
Y_FUN = -103.5                 # ось трубы


def _windows(fm: FlatMesh, z0: float, z1: float, n_front: int, n_side: int, strip: bool,
             y0: float = HY0, y1: float = HY1, hx: float = HX) -> None:
    """Окна яруса z0..z1 на лобовой и бортовых стенках (чуть навыпуск)."""
    zc0, zc1 = z0 + 0.95, z0 + 2.0
    e = 0.08
    if strip:
        fm.poly([(hx - 1.0, y1 + e, zc0), (-hx + 1.0, y1 + e, zc0),
                 (-hx + 1.0, y1 + e, zc1), (hx - 1.0, y1 + e, zc1)], C_WIN)
        for sx in (-1, 1):
            pts = [(sx * (hx + e), y0 + 1.0, zc0), (sx * (hx + e), y1 - 1.0, zc0),
                   (sx * (hx + e), y1 - 1.0, zc1), (sx * (hx + e), y0 + 1.0, zc1)]
            fm.poly(pts if sx > 0 else pts[::-1], C_WIN)
        return
    w = 2 * hx - 2.0
    for i in range(n_front):
        a = -hx + 1.0 + w * (i + 0.2) / n_front
        b = -hx + 1.0 + w * (i + 0.8) / n_front
        fm.poly([(b, y1 + e, zc0), (a, y1 + e, zc0), (a, y1 + e, zc1), (b, y1 + e, zc1)], C_WIN)
    L = (y1 - y0) - 2.0
    for i in range(n_side):
        a = y0 + 1.0 + L * (i + 0.25) / n_side
        b = y0 + 1.0 + L * (i + 0.75) / n_side
        for sx in (-1, 1):
            pts = [(sx * (hx + e), a, zc0), (sx * (hx + e), b, zc0),
                   (sx * (hx + e), b, zc1), (sx * (hx + e), a, zc1)]
            fm.poly(pts if sx > 0 else pts[::-1], C_WIN)


def house(fm: FlatMesh, lod: int) -> None:
    zd = FREEBOARD
    zb = zd + N_TIERS * TIER          # пол мостика
    zt = zb + TIER                     # крыша мостика
    if lod == 2:
        fm.span(-HX, HY0, zd, HX, HY1, zb, C_WHITE)
        fm.span(-HB + 0.5, HY0 + 3.0, zb, HB - 0.5, HY1 + 0.5, zt, C_WHITE)
        return
    # машинная шахта за надстройкой
    fm.span(-7.0, CAS_Y0, zd, 7.0, HY0 + 0.5, zd + 11.0, C_WHITE)
    if lod == 0:
        for t in range(N_TIERS):
            z0 = zd + t * TIER
            fm.span(-HX, HY0, z0, HX, HY1, z0 + TIER, C_WHITE)
            _windows(fm, z0, z0 + TIER, 7, 4, False)
    else:
        fm.span(-HX, HY0, zd, HX, HY1, zb, C_WHITE)
        for t in range(1, N_TIERS):
            z0 = zd + t * TIER
            _windows(fm, z0, z0 + TIER, 0, 0, True)
    # ходовой мостик: рубка + крылья на всю ширину, сплошное остекление
    fm.span(-HX, HY0 + 2.0, zb, HX, HY1 + 0.5, zt, C_WHITE)
    for sx in (-1, 1):
        fm.span(sx * HX, HY1 - 3.0, zb + 0.6, sx * (HB - 0.5), HY1 + 0.5, zt - 0.4, C_WHITE,
                bottom=True)
    e = 0.08
    zw0, zw1 = zb + 1.0, zb + 2.3
    yf = HY1 + 0.5 + e
    fm.poly([(HB - 0.5, yf, zw0), (-HB + 0.5, yf, zw0), (-HB + 0.5, yf, zw1), (HB - 0.5, yf, zw1)],
            C_WIN)
    for sx in (-1, 1):
        pts = [(sx * (HX + e), HY0 + 3.0, zw0), (sx * (HX + e), HY1 - 3.5, zw0),
               (sx * (HX + e), HY1 - 3.5, zw1), (sx * (HX + e), HY0 + 3.0, zw1)]
        fm.poly(pts if sx > 0 else pts[::-1], C_WIN)
    # мачта на крыше мостика, рей и антенны радаров
    fm.span(-0.6, -96.0, zt, 0.6, -94.8, zt + 8.0, C_PIPE)
    if lod == 0:
        fm.span(-4.5, -95.9, zt + 5.5, 4.5, -94.9, zt + 5.9, C_PIPE)
        fm.span(-2.6, -92.0, zt + 2.4, 2.6, -91.4, zt + 2.7, C_DARK)
        fm.span(-0.3, -91.9, zt, 0.3, -91.5, zt + 2.4, C_PIPE)
        fm.span(-HX + 1.0, HY0 + 2.5, zt, -HX + 3.5, HY0 + 5.0, zt + 1.0, C_PIPE)


def funnel(fm: FlatMesh, lod: int) -> None:
    zd = FREEBOARD
    zt = zd + (N_TIERS + 1) * TIER
    za = zd + 11.0
    levels = [(za, C_FUNNEL), (zt + 3.0, C_BAND), (zt + 4.5, C_FUNNEL), (zt + 7.0, C_DARK),
              (zt + 8.5, C_DARK)]
    if lod == 0:
        fm.prism((0.0, Y_FUN), 3.0, 4.2, levels, 10, rake=0.12)
        # шлюпка свободного падения на наклонных салазках за машинной шахтой
        rot = Matrix.Rotation(math.radians(30.0), 3, "X")
        fm.box((0.0, -109.0, zd + 6.5), (3.2, 9.0, 3.0), C_BOAT, rot=rot, bottom=True)
        fm.box((0.0, -108.6, zd + 4.8), (4.6, 10.0, 0.4), C_PIPE, rot=rot, bottom=True)
    elif lod == 1:
        fm.prism((0.0, Y_FUN), 3.0, 4.2, levels[:2] + [(zt + 4.5, C_DARK), (zt + 8.5, C_DARK)],
                 6, rake=0.12)
    else:
        fm.span(-3.0, Y_FUN - 4.0, zd, 3.0, Y_FUN + 4.0, zt + 8.5, C_FUNNEL)


# ---------------------------------------------------------------- сборка

Y_FOC_S = (Y_FOC - Y_FWD) / (Y_BOW - Y_FWD)


def make_lod(lod: int) -> FlatMesh:
    fm = FlatMesh()
    if lod == 0:
        hull(fm, [0.0, 0.2, 0.35, Y_FOC_S, 0.6, 0.7, 0.78, 0.85, 0.91, 0.96, 1.0],
             [0.0, 0.25, 0.45, 0.62, 0.76, 0.88, 0.96, 1.0])
    elif lod == 1:
        hull(fm, [0.0, 0.3, Y_FOC_S, 0.75, 0.9, 1.0], [0.0, 0.5, 0.8, 1.0])
    else:
        hull(fm, [0.0, 0.6, 1.0], [0.0, 1.0], waterline=False, foc=False)
    hatches(fm, lod)
    cranes(fm, lod)
    deck_gear(fm, lod)
    house(fm, lod)
    funnel(fm, lod)
    return fm


def vc_material() -> bpy.types.Material:
    """Белый материал, цвет основы — цвет вершин (glTF: COLOR_0 × baseColor)."""
    m = U.material("ship_bulk", (1.0, 1.0, 1.0), rough=0.7)
    nt = m.node_tree
    attr = nt.nodes.new("ShaderNodeVertexColor")
    attr.layer_name = "Col"
    nt.links.new(attr.outputs["Color"], nt.nodes["Principled BSDF"].inputs["Base Color"])
    return m


def preview(obs, out_dir: str) -> None:
    """Два кадра Workbench: LOD0 и LOD1 рядом, 3/4 спереди и сбоку."""
    os.makedirs(out_dir, exist_ok=True)
    sc = bpy.context.scene
    sc.render.engine = "BLENDER_WORKBENCH"
    sc.display.shading.light = "STUDIO"
    sc.display.shading.color_type = "VERTEX"
    sc.display.shading.show_shadows = True
    sc.render.resolution_x, sc.render.resolution_y = 1600, 800
    sc.render.image_settings.file_format = "JPEG"
    sc.render.image_settings.quality = 88
    world = bpy.data.worlds.new("w")
    world.color = (0.35, 0.5, 0.65)
    sc.world = world
    sea = bpy.data.meshes.new("sea")
    sea.from_pydata([(-600, -600, 0), (600, -600, 0), (600, 600, 0), (-600, 600, 0)], [],
                    [(0, 1, 2, 3)])
    sea_ob = bpy.data.objects.new("sea", sea)
    sc.collection.objects.link(sea_ob)
    obs[1].location.x = 55.0
    obs[0].location.x = -55.0
    obs[2].hide_render = True
    cam_d = bpy.data.cameras.new("cam")
    cam_d.lens = 50
    cam_d.clip_end = 5000.0
    cam = bpy.data.objects.new("cam", cam_d)
    sc.collection.objects.link(cam)
    sc.camera = cam
    for name, pos, tgt in (("front34", (290.0, 290.0, 105.0), (0.0, 0.0, 5.0)),
                           ("side", (460.0, -30.0, 55.0), (0.0, -8.0, 8.0))):
        cam.matrix_world = U.look_matrix(pos, tgt) @ Matrix.Rotation(math.pi / 2, 4, "X")
        sc.render.filepath = os.path.join(out_dir, "bulk_%s.jpg" % name)
        bpy.ops.render.render(write_still=True)


def main() -> None:
    U.reset_scene()
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(SRC, exist_ok=True)
    mat = vc_material()
    obs = []
    for lod in range(3):
        fm = make_lod(lod)
        obs.append(fm.build("%s_LOD%d" % (KIND, lod), mat))
        print("SHIP %s_LOD%d: %d tris" % (KIND, lod, fm.tris()))
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(SRC, "ship_%s.blend" % KIND),
                                check_existing=False, compress=True)
    bpy.ops.export_scene.gltf(filepath=os.path.join(OUT, "ship_%s.glb" % KIND), export_format="GLB",
                              export_yup=True, use_selection=False, export_apply=True,
                              export_extras=False, export_vertex_color="ACTIVE",
                              export_cameras=False, export_lights=False)
    print("EXPORTED ship_%s" % KIND)
    out = os.environ.get("SHIP_PREVIEW", "")
    if out:
        preview(obs, out)


main()
