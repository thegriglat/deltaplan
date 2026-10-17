"""Контейнеровоз Post-Panamax: assets/models/ships/ship_container.glb (+ assets/source/ships/ship_container.blend).

    blender --background --python tools/blender/build_ship_container.py
    SHIP_PREVIEW=<папка> blender --background --python tools/blender/build_ship_container.py   # + 2 кадра JPEG

Контракт S4 (docs/contracts/sea-ships.md): узлы container_LOD0 (≤ 4000 тр.), container_LOD1 (≤ 600),
container_LOD2 (≤ 80). Оси Godot: +Y вверх, нос к −Z, начало — ватерлиния в середине длины, 1 = 1 м.
В Blender строим в его осях (X — поперёк, +Y — к носу, Z — вверх), экспорт «+Y up» переводит в оси Godot.
Образец — build_ship_tanker.py (SEA-3): тот же класс FlatMesh и те же приёмы.

Размеры: длина 300 м, ширина 48 м, осадка 13 м, надводный борт 11 м, бак +2,5 м. Ниже ватерлинии —
только 2 м корпуса (вода непрозрачна). Надстройка-«дом» на ~3/4 длины от носа: узкая (22 м) и высокая,
10 ярусов по 2,8 м + ходовой мостик с крыльями на всю ширину; труба отдельно, ближе к корме.
Палуба: крышки трюмов и штабели контейнеров — 16 «бухт» по 40 футов (12,2 м + 1,2 м проход на
найтовочный мостик), поперёк столбцы по 2 ряда (2 × 2,54 м), 6–9 ярусов по 2,59 м (8'6"). Контейнер
не строится по одному: столбец — одна коробка своего цвета, на внешнем борту штабеля — полосы по
ярусам (контейнер — свой цвет). Цвета и высоты столбцов — детерминированный хеш (бухта, столбец, ярус).
Перед мостиком штабели не выше линии обзора (SOLAS V/22: мёртвая зона перед носом ≤ 500 м), поэтому
к носу они ниже. Бак без контейнеров, на нём волнолом, брашпили и фок-мачта.

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

KIND = "container"
OUT = os.path.join(U.MODELS, "ships")
SRC = os.path.join(U.SOURCE, "ships")

LENGTH = 300.0      # м, наибольшая длина по палубе
BEAM = 48.0         # м
FREEBOARD = 11.0    # м, палуба над ватерлинией (гружёный)
UNDER = 2.0         # м корпуса ниже ватерлинии
FOC_H = 2.5         # м, бак над палубой
TIER = 2.8          # м, высота яруса надстройки

HB = BEAM / 2
Y_STERN = -LENGTH / 2
Y_BOW = LENGTH / 2
Y_FWD = 40.0        # начало сужения в нос (по палубе): обводы острее, чем у танкера
Y_AFT = -80.0       # начало сужения в корму
Y_FOC = 122.0       # передняя граница грузовой палубы — кормовая переборка бака

# контейнеры (ISO 40 футов): длина 12,19, ширина 2,44, высота 2,59
BAY = 12.2          # м, бухта по длине
BAY_GAP = 1.2       # м, проход между бухтами (найтовочный мостик)
ROW = 2.54          # м, шаг ряда поперёк (2,44 + зазор направляющих)
COL_ROWS = 2        # рядов в столбце — одна коробка
CT = 2.59           # м, ярус
HATCH_H = 1.6       # м, крышки трюмов над палубой
MAX_COLS = 9        # 18 рядов на 48 м

# цвета sRGB 0..1 (переводятся в линейные)
C_HULL = (0.11, 0.12, 0.15)      # почти чёрный борт
C_BOTTOM = (0.45, 0.10, 0.08)    # красная подводная часть
C_DECK = (0.32, 0.34, 0.32)      # серая палуба
C_HATCH = (0.24, 0.30, 0.26)     # крышки трюмов
C_WHITE = (0.88, 0.88, 0.85)     # надстройка
C_WIN = (0.10, 0.12, 0.14)       # окна
C_PIPE = (0.62, 0.62, 0.58)      # мачты, механизмы
C_DARK = (0.08, 0.08, 0.08)      # верх трубы
C_FUNNEL = (0.85, 0.85, 0.82)    # труба (белая)
C_BAND = (0.12, 0.28, 0.52)      # полоса на трубе
# контейнеры: красный, синий, белый, оранжевый, зелёный, серый — по два оттенка
C_BOXES = [
    (0.60, 0.12, 0.09), (0.42, 0.10, 0.09),
    (0.10, 0.25, 0.52), (0.22, 0.42, 0.62),
    (0.84, 0.84, 0.80), (0.70, 0.72, 0.70),
    (0.88, 0.45, 0.10), (0.75, 0.32, 0.08),
    (0.14, 0.40, 0.20), (0.30, 0.48, 0.30),
    (0.50, 0.50, 0.50), (0.32, 0.33, 0.35),
]
C_BOX_MIX = (0.46, 0.36, 0.32)   # средний цвет штабеля для LOD2


def _hash(*a) -> int:
    """Детерминированный хеш целых (FNV-1a + перемешивание)."""
    x = 2166136261
    for v in a:
        x = ((x ^ (v & 0xFFFFFFFF)) * 16777619) & 0xFFFFFFFF
    x ^= x >> 15
    x = (x * 0x2C1B3C6D) & 0xFFFFFFFF
    x ^= x >> 12
    return x


def box_col(*a):
    return C_BOXES[_hash(*a) % len(C_BOXES)]


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
    yw = Y_FWD + s * (Y_BOW - 5.0 - Y_FWD)          # завал форштевня 5 м на надводный борт
    yb = Y_FWD + s * (Y_BOW - 8.0 - Y_FWD)
    wd = HB * max(0.0, 1.0 - s ** 2.2) ** 0.55       # сильный развал бортов в носу (палуба под штабели)
    ww = HB * max(0.0, 1.0 - s ** 1.6) ** 0.8
    wb = (HB - 0.8) * max(0.0, 1.0 - s ** 1.4) ** 0.9
    return yb, yw, yd, wb, ww, wd


def _stern(s: float):
    """Корма: s 0 → 1 от Y_AFT до транца (широкий свес кормы)."""
    yd = Y_AFT + s * (Y_STERN - Y_AFT)
    yw = Y_AFT + s * (Y_STERN + 5.0 - Y_AFT)
    yb = Y_AFT + s * (Y_STERN + 11.0 - Y_AFT)
    wd = HB * (1.0 - 0.20 * s ** 3)
    ww = HB * (1.0 - 0.45 * s ** 2.2)
    wb = (HB - 0.8) * (1.0 - 0.80 * s ** 1.8)
    return yb, yw, yd, wb, ww, wd


def hull(fm: FlatMesh, bow_s, stern_s, waterline: bool = True, foc: bool = True) -> list:
    """Корпус: станции от транца к форштевню, сечение — дно, ватерлиния, палуба (обход по кругу).
    Возвращает [(y, полуширина палубы)] станций — по ним штабели не вылезают за борт."""
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
    return [(t[2], t[5]) for t in st]


def deck_half(stations: list, y: float) -> float:
    """Полуширина палубы между станциями (линейно, как у сетки корпуса)."""
    for (ya, wa), (yb, wb) in zip(stations, stations[1:]):
        if ya <= y <= yb and yb > ya:
            return wa + (wb - wa) * (y - ya) / (yb - ya)
    return 0.0


# ---------------------------------------------------------------- надстройка (размеры нужны штабелям)

HY0, HY1 = -83.0, -69.0        # надстройка по длине (корма → нос)
HX = 11.0                      # полуширина надстройки: узкий высокий «дом»
N_TIERS = 10                   # ярусы под мостиком
Z_BRIDGE = FREEBOARD + N_TIERS * TIER
EYE = Z_BRIDGE + 1.7           # глаз вахтенного над ватерлинией
# правило обзора с мостика (SOLAS V/22): мёртвая зона перед носом ≤ min(2 L, 500 м)
BLIND = min(2.0 * LENGTH, 500.0)


# ---------------------------------------------------------------- штабели

def bays() -> list:
    """Бухты (y0, y1, перед_надстройкой): 14 от надстройки до бака, одна между надстройкой и трубой,
    одна за трубой."""
    out = []
    y = HY1 + 1.4
    for _ in range(14):
        out.append((y, y + BAY, True))
        y += BAY + BAY_GAP
    out.append((HY0 - 1.8 - BAY, HY0 - 1.8, False))
    out.append((-126.2, -126.2 + BAY, False))
    return out


def tiers(b: int, c: int, y1: float, fwd: bool) -> int:
    """Ярусов в столбце: 6–9 по хешу, перед мостиком — не выше линии обзора."""
    t = 6 + _hash(b, c, 7) % 4
    if fwd:
        slope = EYE / (Y_BOW + BLIND - HY1)
        z_max = EYE - slope * (y1 - HY1)
        t = min(t, int((z_max - FREEBOARD - HATCH_H) / CT))
    return t


def _qx(fm, x, sign, y0, y1, z0, z1, col):
    if sign > 0:
        fm.poly([(x, y0, z0), (x, y1, z0), (x, y1, z1), (x, y0, z1)], col)
    else:
        fm.poly([(x, y1, z0), (x, y0, z0), (x, y0, z1), (x, y1, z1)], col)


def _qy(fm, y, sign, x0, x1, z0, z1, col):
    if sign > 0:
        fm.poly([(x1, y, z0), (x0, y, z0), (x0, y, z1), (x1, y, z1)], col)
    else:
        fm.poly([(x0, y, z0), (x1, y, z0), (x1, y, z1), (x0, y, z1)], col)


def stacks(fm: FlatMesh, stations: list, lod: int) -> None:
    zd = FREEBOARD
    cw = COL_ROWS * ROW
    if lod == 2:
        y0, y1 = bays()[0][0], bays()[13][1] - 2 * (BAY + BAY_GAP)
        hw = min(deck_half(stations, y0), deck_half(stations, y1)) - 1.0
        fm.span(-hw, y0, zd, hw, y1, zd + HATCH_H + 7 * CT, C_BOX_MIX)
        return
    for b, (y0, y1, fwd) in enumerate(bays()):
        hw = min(deck_half(stations, y0), deck_half(stations, y1)) - 1.0
        n = min(MAX_COLS, int(2 * hw / cw))
        x_l = -n * cw / 2
        ts = [tiers(b, c, y1, fwd) for c in range(n)]
        z0 = zd + HATCH_H
        if lod == 1:
            tm = round(sum(ts) / n)
            fm.span(x_l, y0, zd, -x_l, y1, z0 + tm * CT, None,
                    cols=[box_col(b, 0, 1), box_col(b, 1, 1), box_col(b, 2), box_col(b, 3),
                          box_col(b, 4), None])
            continue
        fm.span(x_l - 0.3, y0 - 0.3, zd, -x_l + 0.3, y1 + 0.3, z0, C_HATCH)
        for c in range(n):
            xa, xb = x_l + c * cw, x_l + (c + 1) * cw
            top = z0 + ts[c] * CT
            col = box_col(b, c)
            fm.poly([(xa, y0, top), (xb, y0, top), (xb, y1, top), (xa, y1, top)], col)
            _qy(fm, y1, 1, xa, xb, z0, top, col)
            _qy(fm, y0, -1, xa, xb, z0, top, col)
            for sign, x, nb in ((-1, xa, c - 1), (1, xb, c + 1)):
                if 0 <= nb < n:
                    tn = z0 + ts[nb] * CT
                    if top > tn:
                        _qx(fm, x, sign, y0, y1, tn, top, col)
                else:
                    # внешний борт штабеля: каждый ярус — свой контейнер
                    for k in range(ts[c]):
                        _qx(fm, x, sign, y0, y1, z0 + k * CT, z0 + (k + 1) * CT,
                            box_col(b, c, k, 11))


# ---------------------------------------------------------------- бак, корма

def foc_gear(fm: FlatMesh, stations: list, lod: int) -> None:
    zf = FREEBOARD + FOC_H
    # волнолом: V-образная стенка поперёк бака, остриём в нос
    yw = Y_FOC + 4.0
    hw = deck_half(stations, yw) - 1.0
    if lod == 0:
        for sx in (-1, 1):
            ang = math.atan2(4.0, hw)
            ln = math.hypot(hw, 4.0)
            rot = Matrix.Rotation(sx * ang, 3, "Z")
            fm.box((sx * hw / 2, yw + 2.0, zf + 2.5), (ln, 0.5, 5.0), C_WHITE, rot=rot)
        # брашпили, фок-мачта
        for sx in (-1, 1):
            fm.span(sx * 6.0 - 1.8, 134.0, zf, sx * 6.0 + 1.8, 138.0, zf + 1.6, C_PIPE)
        fm.span(-0.4, 140.0, zf, 0.4, 140.8, zf + 12.0, C_PIPE)
        fm.span(-2.0, 140.0, zf + 9.0, 2.0, 140.8, zf + 9.4, C_PIPE)
        # кормовые швартовные лебёдки
        for sx in (-1, 1):
            fm.span(sx * 12.0 - 1.5, -142.0, FREEBOARD, sx * 12.0 + 1.5, -139.0, FREEBOARD + 1.4,
                    C_PIPE)
    elif lod == 1:
        fm.span(-hw, yw, zf, hw, yw + 0.6, zf + 4.0, C_WHITE)


# ---------------------------------------------------------------- надстройка

def _windows(fm: FlatMesh, z0: float, n_front: int, n_side: int) -> None:
    """Окна яруса на лобовой и бортовых стенках (чуть навыпуск)."""
    zc0, zc1 = z0 + 0.95, z0 + 2.0
    e = 0.08
    w = 2 * HX - 2.0
    for i in range(n_front):
        a = -HX + 1.0 + w * (i + 0.2) / n_front
        b = -HX + 1.0 + w * (i + 0.8) / n_front
        _qy(fm, HY1 + e, 1, a, b, zc0, zc1, C_WIN)
    L = (HY1 - HY0) - 2.0
    for i in range(n_side):
        a = HY0 + 1.0 + L * (i + 0.25) / n_side
        b = HY0 + 1.0 + L * (i + 0.75) / n_side
        for sx in (-1, 1):
            _qx(fm, sx * (HX + e), sx, a, b, zc0, zc1, C_WIN)


def house(fm: FlatMesh, lod: int) -> None:
    zd = FREEBOARD
    zb = Z_BRIDGE
    zt = zb + TIER                     # крыша мостика
    fm.span(-HX, HY0, zd, HX, HY1, zb, C_WHITE)
    if lod == 2:
        fm.span(-HB + 0.5, HY0 + 4.0, zb, HB - 0.5, HY1, zt, C_WHITE)
        return
    if lod == 0:
        for t in range(1, N_TIERS):
            _windows(fm, zd + t * TIER, 6, 3)
        # спасательные шлюпки на шлюпбалках по бортам второго яруса
        for sx in (-1, 1):
            fm.span(sx * (HX + 0.3), HY0 + 3.0, zd + 2 * TIER, sx * (HX + 3.5), HY0 + 11.0,
                    zd + 2 * TIER + 3.0, (0.95, 0.42, 0.05), bottom=True)
    else:
        e = 0.08
        for t in range(1, N_TIERS):
            z0 = zd + t * TIER
            _qy(fm, HY1 + e, 1, -HX + 1.0, HX - 1.0, z0 + 0.95, z0 + 2.0, C_WIN)
    # ходовой мостик: рубка + крылья на всю ширину, сплошное остекление
    fm.span(-HX, HY0 + 2.0, zb, HX, HY1 + 0.5, zt, C_WHITE)
    for sx in (-1, 1):
        fm.span(sx * HX, HY1 - 3.5, zb + 0.6, sx * (HB - 0.5), HY1 + 0.5, zt - 0.4, C_WHITE,
                bottom=True)
    e = 0.08
    zw0, zw1 = zb + 1.0, zb + 2.3
    _qy(fm, HY1 + 0.5 + e, 1, -HB + 0.5, HB - 0.5, zw0, zw1, C_WIN)
    if lod == 0:
        for sx in (-1, 1):
            _qx(fm, sx * (HX + e), sx, HY0 + 3.0, HY1 - 4.0, zw0, zw1, C_WIN)
        # мачта с реем, антенны радаров
        fm.span(-0.6, -77.0, zt, 0.6, -75.8, zt + 9.0, C_PIPE)
        fm.span(-5.0, -76.9, zt + 6.0, 5.0, -75.9, zt + 6.4, C_PIPE)
        fm.span(-3.0, -72.5, zt + 2.6, 3.0, -71.9, zt + 2.9, C_DARK)
        fm.span(-0.3, -72.4, zt, 0.3, -72.0, zt + 2.6, C_PIPE)
    else:
        fm.span(-0.6, -77.0, zt, 0.6, -75.8, zt + 9.0, C_PIPE)


def funnel(fm: FlatMesh, lod: int) -> None:
    """Машинная шахта и труба отдельно от надстройки, ближе к корме."""
    zd = FREEBOARD
    za = zd + 8.0
    ztop = Z_BRIDGE + TIER + 5.0
    if lod == 2:
        fm.span(-4.0, -111.0, zd, 4.0, -100.0, ztop, C_FUNNEL)   # шахта и труба одной коробкой
        return
    fm.span(-8.0, -112.5, zd, 8.0, -99.0, za, C_WHITE)
    levels = [(za, C_FUNNEL), (ztop - 7.0, C_BAND), (ztop - 4.0, C_FUNNEL), (ztop - 1.5, C_DARK),
              (ztop, C_DARK)]
    if lod == 0:
        fm.prism((0.0, -105.5), 4.2, 5.8, levels, 10, rake=0.08)
    elif lod == 1:
        fm.prism((0.0, -105.5), 4.2, 5.8, levels[:2] + [(ztop - 4.0, C_DARK), (ztop, C_DARK)],
                 6, rake=0.08)


# ---------------------------------------------------------------- сборка

Y_FOC_S = (Y_FOC - Y_FWD) / (Y_BOW - Y_FWD)


def make_lod(lod: int) -> FlatMesh:
    fm = FlatMesh()
    if lod == 0:
        stations = hull(fm, [0.0, 0.15, 0.3, 0.42, 0.53, 0.63, Y_FOC_S, 0.82, 0.88, 0.93, 0.97, 1.0],
                        [0.0, 0.25, 0.45, 0.62, 0.76, 0.88, 0.96, 1.0])
    elif lod == 1:
        stations = hull(fm, [0.0, 0.35, 0.6, Y_FOC_S, 0.9, 1.0], [0.0, 0.5, 0.8, 1.0])
    else:
        stations = hull(fm, [0.0, 0.6, 1.0], [0.0, 1.0], waterline=False, foc=False)
    stacks(fm, stations, lod)
    foc_gear(fm, stations, lod)
    house(fm, lod)
    funnel(fm, lod)
    return fm


def vc_material() -> bpy.types.Material:
    """Белый материал, цвет основы — цвет вершин (glTF: COLOR_0 × baseColor)."""
    m = U.material("ship_container", (1.0, 1.0, 1.0), rough=0.7)
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
    sea.from_pydata([(-700, -700, 0), (700, -700, 0), (700, 700, 0), (-700, 700, 0)], [],
                    [(0, 1, 2, 3)])
    sea_ob = bpy.data.objects.new("sea", sea)
    sc.collection.objects.link(sea_ob)
    obs[1].location.x = 80.0
    obs[0].location.x = -80.0
    obs[2].hide_render = True
    cam_d = bpy.data.cameras.new("cam")
    cam_d.lens = 50
    cam_d.clip_end = 5000.0
    cam = bpy.data.objects.new("cam", cam_d)
    sc.collection.objects.link(cam)
    sc.camera = cam
    for name, pos, tgt in (("front34", (400.0, 400.0, 150.0), (0.0, 0.0, 10.0)),
                           ("side", (640.0, -40.0, 70.0), (0.0, -10.0, 12.0))):
        cam.matrix_world = U.look_matrix(pos, tgt) @ Matrix.Rotation(math.pi / 2, 4, "X")
        sc.render.filepath = os.path.join(out_dir, "container_%s.jpg" % name)
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
