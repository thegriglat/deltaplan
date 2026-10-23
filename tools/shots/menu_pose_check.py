#!/usr/bin/env python3
"""MSP-К1 v2: проверка позы планера по логам кадров menu_art.py.

    tools/shots/menu_pose_check.py <каталог_с_logs> [--bank=0] [--pitch=0]   таблица и «pose ok N/M»; код 0, только если N = M
    tools/shots/menu_pose_check.py --selftest                              разбор строк-образцов

По каждому <каталог>/logs/NN.log: строка «menu_background: поза режим=… крен=… тангаж=… курс=… p=… q=… r=…» ровно одна;
режим fixed; |крен − bank| ≤ 1°, |тангаж − pitch| ≤ 1° (по умолчанию 0 и 0). Режим physics — ошибка.
"""
import re
import sys
from pathlib import Path

NUM = r"(-?\d+(?:\.\d+)?)"
LINE = re.compile(r"menu_background: поза режим=(fixed|physics) крен=%s тангаж=%s курс=%s p=%s q=%s r=%s" % ((NUM,) * 6))
TOL_DEG = 1.0
KEYS = ("mode", "bank", "pitch", "heading", "p", "q", "r")


def parse(text):
    """→ (словарь позы | None, число найденных строк)."""
    found = [m for m in (LINE.search(l) for l in text.splitlines()) if m]
    if not found:
        return None, 0
    d = dict(zip(KEYS, found[0].groups()))
    for k in KEYS[1:]:
        d[k] = float(d[k])
    return d, len(found)


def verdict(pose, n_lines, bank=0.0, pitch=0.0):
    """→ (ok, причина)."""
    if pose is None:
        return False, "строки позы нет"
    if n_lines != 1:
        return False, "строк позы %d, нужна ровно одна" % n_lines
    if pose["mode"] != "fixed":
        return False, "режим %s, нужен fixed" % pose["mode"]
    if abs(pose["bank"] - bank) > TOL_DEG:
        return False, "крен %.1f вне %.1f±%.0f" % (pose["bank"], bank, TOL_DEG)
    if abs(pose["pitch"] - pitch) > TOL_DEG:
        return False, "тангаж %.1f вне %.1f±%.0f" % (pose["pitch"], pitch, TOL_DEG)
    return True, "ok"


def selftest():
    def line(mode="fixed", bank=0.0, pitch=0.0):
        return "x\nmenu_background: поза режим=%s крен=%.1f тангаж=%.1f курс=123.0 p=0.0 q=0.0 r=0.0\n" % (mode, bank, pitch)
    cases = [
        ("годная", line(), 0.0, 0.0, True),
        ("крен вне пределов", line(bank=-70.0), 0.0, 0.0, False),
        ("тангаж вне пределов", line(pitch=-30.0), 0.0, 0.0, False),
        ("строки нет", "ничего\n", 0.0, 0.0, False),
        ("две строки", line() + line(), 0.0, 0.0, False),
        ("режим physics", line("physics"), 0.0, 0.0, False),
        ("крен и тангаж заданы", line(bank=10.2, pitch=5.0), 10.0, 5.0, True),
        ("крен 10 при bank 0", line(bank=10.2), 0.0, 0.0, False),
    ]
    bad = 0
    for name, text, bank, pitch, want in cases:
        pose, n = parse(text)
        ok, why = verdict(pose, n, bank, pitch)
        bad += ok != want
        print("%s %s: ok=%s (%s)" % ("ok    " if ok == want else "ОШИБКА", name, ok, why))
    return 1 if bad else 0


def check_dir(root, bank, pitch):
    logs = sorted(Path(root, "logs").glob("[0-9][0-9].log"))
    if not logs:
        print("нет логов в %s/logs" % root)
        return 1
    ok_n = 0
    print("NN   режим   крен  тангаж   курс     p     q     r  итог")
    for log in logs:
        pose, n = parse(log.read_text(errors="replace"))
        ok, why = verdict(pose, n, bank, pitch)
        ok_n += ok
        if pose:
            print("%s %7s %6.1f %7.1f %6.1f %5.1f %5.1f %5.1f  %s" % (
                log.stem, pose["mode"], pose["bank"], pose["pitch"], pose["heading"],
                pose["p"], pose["q"], pose["r"], "ok" if ok else "FAIL " + why))
        else:
            print("%s  FAIL %s" % (log.stem, why))
    print("pose ok %d/%d" % (ok_n, len(logs)))
    return 0 if ok_n == len(logs) else 1


def main():
    args = sys.argv[1:]
    if args == ["--selftest"]:
        return selftest()
    bank = pitch = 0.0
    rest = []
    for a in args:
        if a.startswith("--bank="):
            bank = float(a[7:])
        elif a.startswith("--pitch="):
            pitch = float(a[8:])
        else:
            rest.append(a)
    if len(rest) != 1:
        print(__doc__)
        return 2
    return check_dir(rest[0], bank, pitch)


if __name__ == "__main__":
    sys.exit(main())
