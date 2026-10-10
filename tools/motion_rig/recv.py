#!/usr/bin/env python3
"""Приёмник пакетов движения Deltaplan (MR-К2): печать строкой и/или jsonl. Только stdlib.

  recv.py --port 33001 --format auto --jsonl out.jsonl --count 100 --timeout 10
  recv.py --selftest
"""
import argparse
import json
import socket
import sys
import os
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from motion_formats import GENERIC_SIZE, GENERIC_VERSION, SRS_SIZE, SRS_VERSION, parse  # noqa: E402,F401


def line(d):
    skip = ("format", "version", "t_recv", "game", "vehicle")
    return d["format"] + " " + " ".join(
        "%s=%s" % (k, ("%.3f" % v) if isinstance(v, float) else v) for k, v in d.items() if k not in skip)


def selftest():
    import motion_formats as mf
    s = mf.pack_fields(mf.SRS_FIELDS, mf.SRS_SIZE, {
        "api_mode": b"api", "version": 102, "game": b"Deltaplan", "vehicle_name": b"Hang glider",
        "location": b"Altai", "speed_kmh": 40.0, "pitch": 5.0, "roll": -10.0, "yaw": 90.0,
        "vertical_acceleration": -0.1, "longitudinal_acceleration": 0.3})
    d = parse(s, "srs")
    assert d["game"] == "Deltaplan" and d["vehicle"] == "Hang glider" and d["location"] == "Altai", d
    assert abs(d["pitch"] - 5.0) < 1e-6 and abs(d["roll"] + 10.0) < 1e-6 and abs(d["yaw"] - 90.0) < 1e-6, d
    assert abs(d["vertical_acceleration"] + 0.1) < 1e-6 and abs(d["longitudinal_acceleration"] - 0.3) < 1e-6, d
    assert parse(s, "auto")["format"] == "srs"
    g = mf.pack_fields(mf.GENERIC_FIELDS, mf.GENERIC_SIZE, {
        "magic": b"DPMR", "version": 1, "seq": 7, "flags": 3, "t": 1.5, "surge": 0.1, "sway": 0.2, "heave": 9.81,
        "roll": 1.0, "pitch": 2.0, "yaw": 3.0, "roll_rate": 4.0, "pitch_rate": 5.0, "yaw_rate": 6.0,
        "airspeed": 11.0, "air_lateral": 0.5})
    d = parse(g)
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
