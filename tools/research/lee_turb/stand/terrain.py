"""Рельеф места Онгудай (tests/fixtures/wind/places/ongudai.bin) и поиск гребней поперёк ветра."""
import json, math, os
import numpy as np

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../../.."))
PLACE = os.path.join(ROOT, "tests/fixtures/wind/places/ongudai")


def load():
    h = json.load(open(PLACE + ".json"))
    g = h["grid"]
    n = g["width"]
    a = np.fromfile(PLACE + ".bin", dtype="<i2", count=n * g["height"]).reshape(g["height"], n)
    return a * h["h_scale"] + h["h_offset"], g


A, G = load()


def ground(x, z):
    """Высота рельефа, билинейно, как dp_air::field::runtime::ground_height."""
    fx = np.clip((np.asarray(x) - G["origin_x"]) / G["spacing"], 0, G["width"] - 1.0001)
    fz = np.clip((np.asarray(z) - G["origin_z"]) / G["spacing"], 0, G["height"] - 1.0001)
    i, j = fx.astype(int), fz.astype(int)
    tx, tz = fx - i, fz - j
    return (A[j, i] * (1 - tx) * (1 - tz) + A[j, i + 1] * tx * (1 - tz)
            + A[j + 1, i] * (1 - tx) * tz + A[j + 1, i + 1] * tx * tz)


def wind_dir(wdir_from_deg):
    """Единичный вектор (x, z) «куда дует»; север = −z, восток = +x."""
    a = math.radians(wdir_from_deg)
    return (-math.sin(a), math.cos(a))  # east = −sin, north = −cos → z = −north = +cos
