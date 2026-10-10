#!/usr/bin/env python3
"""Приёмник пакетов движения Deltaplan (MR-К2): печать строкой и/или jsonl. Только stdlib.

  recv.py --port 33001 --format auto --jsonl out.jsonl --count 100 --timeout 10
  recv.py --selftest
"""
import argparse
import json
import socket
import struct
import sys
import time

SRS_SIZE = 236
GENERIC_SIZE = 64
SRS_FIELDS = ("speed_kmh", "rpm", "max_rpm")


def _cstr(b):
    return b.split(b"\0", 1)[0].decode("utf-8", "replace")


def parse_srs(data):
    if len(data) != SRS_SIZE:
        raise ValueError("srs: размер %d, ожидалось %d" % (len(data), SRS_SIZE))
    if data[0:3] != b"api":
        raise ValueError("srs: нет заголовка 'api'")
    version = struct.unpack_from("<I", data, 4)[0]
    if version != 102:
        raise ValueError("srs: версия %d, ожидалась 102" % version)
    f = lambda off, n=1: struct.unpack_from("<%df" % n, data, off)
    return {
        "format": "srs",
        "version": version,
        "game": _cstr(data[8:58]),
        "vehicle": _cstr(data[58:108]),
        "location": _cstr(data[108:158]),
        "speed_kmh": f(160)[0],
        "rpm": f(164)[0],
        "max_rpm": f(168)[0],
        "gear": struct.unpack_from("<i", data, 172)[0],
        "pitch": f(176)[0],
        "roll": f(180)[0],
        "yaw": f(184)[0],
        "lateral_velocity": f(188)[0],
        "lateral_acceleration": f(192)[0],
        "vertical_acceleration": f(196)[0],
        "longitudinal_acceleration": f(200)[0],
    }


def parse_generic(data):
    if len(data) != GENERIC_SIZE:
        raise ValueError("generic: размер %d, ожидалось %d" % (len(data), GENERIC_SIZE))
    if data[0:4] != b"DPMR":
        raise ValueError("generic: нет magic 'DPMR'")
    version, seq, flags = struct.unpack_from("<III", data, 4)
    if version != 1:
        raise ValueError("generic: версия %d, ожидалась 1" % version)
    v = struct.unpack_from("<12f", data, 16)
    names = ("t", "surge", "sway", "heave", "roll", "pitch", "yaw",
             "roll_rate", "pitch_rate", "yaw_rate", "airspeed", "air_lateral")
    d = {"format": "generic", "version": version, "seq": seq, "valid": bool(flags & 1),
         "on_ground": bool(flags & 2)}
    d.update(zip(names, v))
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


def line(d):
    skip = ("format", "version", "t_recv", "game", "vehicle")
    return d["format"] + " " + " ".join(
        "%s=%s" % (k, ("%.3f" % v) if isinstance(v, float) else v) for k, v in d.items() if k not in skip)


def selftest():
    s = bytearray(SRS_SIZE)
    s[0:3] = b"api"
    struct.pack_into("<I", s, 4, 102)
    s[8:8 + 9] = b"Deltaplan"
    s[58:58 + 11] = b"Hang glider"
    s[108:108 + 6] = b"Altai\0"
    struct.pack_into("<f", s, 160, 40.0)
    struct.pack_into("<3f", s, 176, 5.0, -10.0, 90.0)
    struct.pack_into("<4f", s, 188, 0.5, 0.25, -0.1, 0.3)
    d = parse(bytes(s), "srs")
    assert d["game"] == "Deltaplan" and d["vehicle"] == "Hang glider" and d["location"] == "Altai", d
    assert abs(d["pitch"] - 5.0) < 1e-6 and abs(d["roll"] + 10.0) < 1e-6 and abs(d["yaw"] - 90.0) < 1e-6, d
    assert abs(d["vertical_acceleration"] + 0.1) < 1e-6 and abs(d["longitudinal_acceleration"] - 0.3) < 1e-6, d
    assert parse(bytes(s), "auto")["format"] == "srs"
    g = bytearray(GENERIC_SIZE)
    g[0:4] = b"DPMR"
    struct.pack_into("<III", g, 4, 1, 7, 3)
    struct.pack_into("<12f", g, 16, 1.5, 0.1, 0.2, 9.81, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 11.0, 0.5)
    d = parse(bytes(g))
    assert d["seq"] == 7 and d["valid"] and d["on_ground"] and abs(d["heave"] - 9.81) < 1e-5, d
    assert abs(d["yaw_rate"] - 6.0) < 1e-6 and abs(d["air_lateral"] - 0.5) < 1e-6, d
    for bad in (b"", b"x" * 10, b"api" + b"\0" * 233, b"XXXX" + b"\0" * 60):
        try:
            parse(bad)
        except ValueError:
            pass
        else:
            raise AssertionError("плохой пакет принят: %r" % bad[:8])
    print("selftest OK")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=33001)
    ap.add_argument("--bind", default="127.0.0.1")
    ap.add_argument("--format", choices=("srs", "generic", "auto"), default="auto")
    ap.add_argument("--jsonl", help="писать строку json на пакет")
    ap.add_argument("--count", type=int, default=0, help="выйти после N пакетов")
    ap.add_argument("--timeout", type=float, default=0.0, help="выйти через N секунд")
    ap.add_argument("--quiet", action="store_true", help="не печатать пакеты")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        selftest()
        return 0
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((a.bind, a.port))
    sock.settimeout(0.2)
    out = open(a.jsonl, "w", buffering=1) if a.jsonl else None
    start = time.time()
    n = 0
    try:
        while True:
            if a.timeout and time.time() - start >= a.timeout:
                break
            try:
                data, _ = sock.recvfrom(4096)
            except socket.timeout:
                continue
            try:
                d = parse(data, a.format)
            except ValueError as e:
                print("ошибка: %s" % e, file=sys.stderr)
                continue
            d["t_recv"] = time.time()
            n += 1
            if not a.quiet:
                print(line(d), flush=True)
            if out:
                out.write(json.dumps(d) + "\n")
            if a.count and n >= a.count:
                break
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
