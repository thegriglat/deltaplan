"""Единственное место раскладок пакетов движения Deltaplan на Python (MR-К2). Только stdlib.

Каждое поле: (имя, struct-код little-endian, смещение). Строки — 's' с длиной в коде (например '50s').
Раскладку берут recv.py, check_layout.py и проверки петли; таблица в docs/contracts/motion-rig.md и
tools/motion_rig/motion_generic.h сверяются с ней командой check_layout.py.
"""
import struct

SRS_SIZE = 236
SRS_VERSION = 102
SRS_FIELDS = [
    ("api_mode", "3s", 0),
    ("version", "I", 4),
    ("game", "50s", 8),
    ("vehicle_name", "50s", 58),
    ("location", "50s", 108),
    ("speed_kmh", "f", 160),
    ("rpm", "f", 164),
    ("max_rpm", "f", 168),
    ("gear", "i", 172),
    ("pitch", "f", 176),
    ("roll", "f", 180),
    ("yaw", "f", 184),
    ("lateral_velocity", "f", 188),
    ("lateral_acceleration", "f", 192),
    ("vertical_acceleration", "f", 196),
    ("longitudinal_acceleration", "f", 200),
    ("suspension_travel", "4f", 204),
    ("wheel_terrain", "4I", 220),
]

GENERIC_SIZE = 64
GENERIC_VERSION = 1
GENERIC_MAGIC = b"DPMR"
GENERIC_FIELDS = [
    ("magic", "4s", 0),
    ("version", "I", 4),
    ("seq", "I", 8),
    ("flags", "I", 12),
    ("t", "f", 16),
    ("surge", "f", 20),
    ("sway", "f", 24),
    ("heave", "f", 28),
    ("roll", "f", 32),
    ("pitch", "f", 36),
    ("yaw", "f", 40),
    ("roll_rate", "f", 44),
    ("pitch_rate", "f", 48),
    ("yaw_rate", "f", 52),
    ("airspeed", "f", 56),
    ("air_lateral", "f", 60),
]


def pack_fields(fields, size, values):
    """Собрать пакет из словаря значений (отсутствующие поля — нули); для selftest и проверок."""
    b = bytearray(size)
    for name, code, off in fields:
        v = values.get(name)
        if v is None:
            continue
        if not isinstance(v, (list, tuple)):
            v = (v,)
        struct.pack_into("<" + code, b, off, *v)
    return bytes(b)


def _decode(data, fields):
    out = {}
    for name, code, off in fields:
        v = struct.unpack_from("<" + code, data, off)
        out[name] = v[0] if len(v) == 1 else list(v)
    return out


def _cstr(b):
    return b.split(b"\0", 1)[0].decode("utf-8", "replace")


def parse_srs(data):
    if len(data) != SRS_SIZE:
        raise ValueError("srs: размер %d, ожидалось %d" % (len(data), SRS_SIZE))
    d = _decode(data, SRS_FIELDS)
    if d["api_mode"] != b"api":
        raise ValueError("srs: нет заголовка 'api'")
    if d["version"] != SRS_VERSION:
        raise ValueError("srs: версия %d, ожидалась %d" % (d["version"], SRS_VERSION))
    for k in ("game", "vehicle_name", "location"):
        d[k] = _cstr(d[k])
    d["vehicle"] = d.pop("vehicle_name")
    d["format"] = "srs"
    del d["api_mode"]
    return d


def parse_generic(data):
    if len(data) != GENERIC_SIZE:
        raise ValueError("generic: размер %d, ожидалось %d" % (len(data), GENERIC_SIZE))
    d = _decode(data, GENERIC_FIELDS)
    if d["magic"] != GENERIC_MAGIC:
        raise ValueError("generic: нет magic 'DPMR'")
    if d["version"] != GENERIC_VERSION:
        raise ValueError("generic: версия %d, ожидалась %d" % (d["version"], GENERIC_VERSION))
    d["format"] = "generic"
    d["valid"] = bool(d["flags"] & 1)
    d["on_ground"] = bool(d["flags"] & 2)
    del d["magic"]
    return d


def parse(data, fmt="auto"):
    if fmt == "auto":
        if len(data) == SRS_SIZE:
            fmt = "srs"
        elif len(data) == GENERIC_SIZE:
            fmt = "generic"
        else:
            raise ValueError("размер %d не srs (%d) и не generic (%d)" % (len(data), SRS_SIZE, GENERIC_SIZE))
    return parse_srs(data) if fmt == "srs" else parse_generic(data)
