#!/usr/bin/env python3
"""Сверка раскладки пакетов: motion_generic.h (cc: offsetof/sizeof) = motion_formats.py; фикстуры пакетов игры
(tests/motion_rig/fixtures/*.bin, их пишет и сверяет GDScript-тест) разбираются motion_formats.py и дают
известный сэмпл. Успех — «layout OK», код 0."""
import os
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import motion_formats as mf  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(HERE))
FIX = os.path.join(ROOT, "tests", "motion_rig", "fixtures")
KNOWN_GENERIC = {"t": 7.5, "surge": 1.5, "sway": -2.0, "heave": 11.0, "roll": 12.5, "pitch": -3.25, "yaw": 270.0,
                 "roll_rate": 4.0, "pitch_rate": -5.0, "yaw_rate": 6.0, "airspeed": 12.0, "air_lateral": 0.5,
                 "seq": 42, "valid": True, "on_ground": False}
G = 9.80665
KNOWN_SRS = {"game": "Deltaplan", "vehicle": "Hang glider", "location": "Altai", "speed_kmh": 43.2,
             "pitch": -3.25, "roll": 12.5, "yaw": -90.0, "lateral_velocity": 0.5,
             "lateral_acceleration": -2.0 / G, "vertical_acceleration": 11.0 / G - 1.0,
             "longitudinal_acceleration": 1.5 / G}


def struct_layout(fields):
    """Смещения полей по struct (проверка, что offset + размер не пересекаются)."""
    end = 0
    for name, code, off in fields:
        if off < end:
            raise SystemExit("layout FAIL: поле %s пересекается (смещение %d < %d)" % (name, off, end))
        end = off + struct.calcsize("<" + code)
    return end


def check_header():
    names = [n for n, _, _ in mf.GENERIC_FIELDS]
    cdecl = {"f": "float", "I": "uint32_t", "4s": "char"}
    src = ['#include <stdio.h>', '#include "motion_generic.h"', 'int main(void){',
           'printf("size %zu\\n", sizeof(dpmr_packet_t));']
    for n in names:
        src.append('printf("%s %%zu\\n", offsetof(dpmr_packet_t, %s));' % (n, "magic" if n == "magic" else n))
    src.append("return 0;}")
    cc = None
    for c in ("cc", "gcc", "clang"):
        if subprocess.call(["which", c], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) == 0:
            cc = c
            break
    if cc is None:
        print("layout: cc не найден — сверка .h пропущена")
        return
    with tempfile.TemporaryDirectory() as d:
        c_file, exe = os.path.join(d, "t.c"), os.path.join(d, "t")
        open(c_file, "w").write("\n".join(src))
        r = subprocess.run([cc, "-std=c11", "-I", HERE, c_file, "-o", exe], capture_output=True, text=True)
        if r.returncode != 0:
            raise SystemExit("layout FAIL: .h не компилируется:\n" + r.stderr)
        out = subprocess.run([exe], capture_output=True, text=True).stdout.split("\n")
    got = {l.split()[0]: int(l.split()[1]) for l in out if l.strip()}
    if got.get("size") != mf.GENERIC_SIZE:
        raise SystemExit("layout FAIL: sizeof в .h = %s, в py %d" % (got.get("size"), mf.GENERIC_SIZE))
    for n, _, off in mf.GENERIC_FIELDS:
        if got.get(n) != off:
            raise SystemExit("layout FAIL: смещение %s: .h %s, py %d" % (n, got.get(n), off))
    print("layout: motion_generic.h == motion_formats.py (%d полей, %d байт)" % (len(mf.GENERIC_FIELDS), mf.GENERIC_SIZE))


def near(a, b, tol=1e-4):
    return abs(a - b) <= tol


def check_fixture():
    for fmt, known in (("generic", KNOWN_GENERIC), ("srs", KNOWN_SRS)):
        path = os.path.join(FIX, "known_%s.bin" % fmt)
        if not os.path.exists(path):
            raise SystemExit("layout FAIL: нет фикстуры " + path)
        d = mf.parse(open(path, "rb").read(), fmt)
        for k, v in known.items():
            ok = d[k] == v if isinstance(v, (str, bool, int)) else near(d[k], v)
            if not ok:
                raise SystemExit("layout FAIL: %s.%s = %r, ожидалось %r" % (fmt, k, d[k], v))
    print("layout: пакеты игры (фикстуры) разбираются motion_formats.py")


def main():
    if struct_layout(mf.SRS_FIELDS) != mf.SRS_SIZE:
        raise SystemExit("layout FAIL: srs %d != %d" % (struct_layout(mf.SRS_FIELDS), mf.SRS_SIZE))
    if struct_layout(mf.GENERIC_FIELDS) != mf.GENERIC_SIZE:
        raise SystemExit("layout FAIL: generic %d != %d" % (struct_layout(mf.GENERIC_FIELDS), mf.GENERIC_SIZE))
    check_header()
    check_fixture()
    print("layout OK")


if __name__ == "__main__":
    main()
