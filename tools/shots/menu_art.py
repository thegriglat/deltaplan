#!/usr/bin/env python3
"""Кадры-кандидаты для фона меню и экранов загрузки — пачкой через tools/shots/menu_background.sh.

    tools/shots/menu_art.py [--size=1920x1080] [--out=каталог] [--only=01,07,…] [--jobs=3]

Сюжеты — tools/shots/menu_art.json: места (каталог стартов или --latlon у знаковых гор), ракурсы
камеры (от третьего лица, планер не по центру), время суток и облачность. Номер кадра стабилен:
черновики снимаются 1920×1080 JPEG, выбранные номера переснимаются тем же скриптом с
--size=3840x2160 --only=… (PNG). Места по координатам сперва собираются в свой кеш (--prefetch),
кадры одного места идут подряд в общем кеше, разные места и каталог — параллельно (--jobs).
Пишет <out>/NN_<сюжет>.jpg|png и <out>/index.md; лог каждого кадра — <out>/logs/NN.log.
"""
import argparse
import json
import math
import os
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SHOT = ROOT / "tools/shots/menu_background.sh"


def bearing(a, b):
    """Азимут из точки a на точку b (градусы, 0 — север)."""
    la1, lo1, la2, lo2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    y = math.sin(lo2 - lo1) * math.cos(la2)
    x = math.cos(la1) * math.sin(la2) - math.sin(la1) * math.cos(la2) * math.cos(lo2 - lo1)
    return (math.degrees(math.atan2(y, x)) + 360.0) % 360.0


def center(location):
    loc = json.loads((ROOT / "configs/locations" / ("%s.json" % location)).read_text())
    return [loc["center_lat"], loc["center_lon"]]


def expand(spec):
    """Список кадров: место × вариант (время, небо, ракурс). Номера — по порядку в файле."""
    shots = []
    for place in spec["places"]:
        for v in place["variants"]:
            light = spec["light"][v["light"]]
            cam = dict(spec["cameras"][v["camera"]])
            cam.update(v.get("camera_patch", {}))
            flags = ["--autostart", "--autopilot", "--bots=0", "--seed=%d" % v.get("seed", 20260927)]
            flags += ["--sky=%s" % light["sky"], "--temp=%d" % light["temp"], "--hour=%d" % light["hour"]]
            flags += ["--wing=%s" % v.get("wing", place.get("wing", "sport"))]
            flags += ["--air-start=%s" % v.get("air_start", place.get("air_start", "1000,300"))]
            xdg = None
            if "latlon" in place:
                ll = place["latlon"]
                flags += ["--latlon=%.5f,%.5f" % tuple(ll)]
                # ветер с горы: планер идёт против ветра, гора — за ним в кадре сзади
                frm = bearing(ll, place["peak"]) if "peak" in place else place.get("from", 270)
                flags += ["--wind=4", "--from=%d" % round(frm)]
                xdg = place["id"]
                if "peak" in place:
                    cam["peak"] = place["peak"]
            else:
                flags += ["--location=%s" % place["location"], "--site=%s" % place["site"]]
                # кеш места — общий на локацию каталога, собирается заранее по её центру
                xdg = place["location"]
                if "circle" in v or "circle" in place:
                    flags += ["--autopilot-circle=%s" % v.get("circle", place.get("circle"))]
            shots.append({
                "slug": "%s_%s" % (place["id"], v["name"]),
                "place": place["title"],
                "light": v["light"],
                "camera": v["camera"],
                "desc": v.get("desc", ""),
                "xdg": xdg,
                "latlon": place.get("latlon") or center(place["location"]),
                "cfg": {
                    "flags": flags,
                    "clock_hour": light["clock_hour"],
                    "graphics": spec.get("graphics", "high"),
                    "sim_time_s": v.get("sim_time_s", 8.0),
                    "warmup_frames": spec.get("warmup_frames", 30),
                    "camera": cam,
                    "jpeg_quality": 0.92,
                },
            })
    for i, s in enumerate(shots, 1):
        s["n"] = "%02d" % i
        s["name"] = "%s_%s" % (s["n"], s["slug"])
    return shots


def run_shot(s, size, out, ext, xdg_root, tmp):
    cfg = Path(tmp) / ("%s.json" % s["n"])
    cfg.write_text(json.dumps(s["cfg"], ensure_ascii=False))
    env = dict(os.environ)
    if s["xdg"]:
        env["MB_XDG"] = str(xdg_root / s["xdg"])
    env["MB_TIMEOUT"] = "400"
    log = out / "logs" / ("%s.log" % s["n"])
    dst = out / ("%s.%s" % (s["name"], ext))
    cmd = ["systemd-run", "--user", "--scope", "-q", "-p", "MemoryMax=10G",
           str(SHOT), "--size=%s" % size, "--out=%s" % dst, "--config=%s" % cfg]
    with open(log, "w") as f:
        code = subprocess.call(cmd, cwd=ROOT, env=env, stdout=f, stderr=subprocess.STDOUT)
    ok = code == 0 and dst.exists() and dst.stat().st_size > 50_000
    print("%s %s %s" % (s["n"], "ok" if ok else "FAIL(%d)" % code, dst.name), flush=True)
    return ok


def prefetch(place_id, latlon, xdg_root):
    xdg = xdg_root / place_id
    xdg.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, XDG_DATA_HOME=str(xdg))
    cmd = ["timeout", "1200", "godot", "--headless", "--path", ".", "--",
           "--prefetch=%.5f,%.5f" % tuple(latlon)]
    code = subprocess.call(cmd, cwd=ROOT, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print("prefetch %s: код %d" % (place_id, code), flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--size", default="1920x1080")
    ap.add_argument("--out", default="/home/greg/deltaplan/build/screenshots/menu_art")
    ap.add_argument("--only", default="")
    ap.add_argument("--jobs", type=int, default=3)
    ap.add_argument("--xdg", default="/home/greg/deltaplan/build/menu_art_xdg")
    a = ap.parse_args()
    spec = json.loads((ROOT / "tools/shots/menu_art.json").read_text())
    shots = expand(spec)
    if a.only:
        keep = {"%02d" % int(x) for x in a.only.split(",")}
        shots = [s for s in shots if s["n"] in keep]
    big = int(a.size.split("x")[0]) > 2000
    ext = "png" if big else "jpg"
    out = Path(a.out)
    (out / "logs").mkdir(parents=True, exist_ok=True)
    xdg_root = Path(a.xdg)
    places = {}
    for s in shots:
        if s["xdg"]:
            places.setdefault(s["xdg"], s["latlon"])
    with ThreadPoolExecutor(a.jobs) as ex:
        list(ex.map(lambda kv: prefetch(kv[0], kv[1], xdg_root), places.items()))
    # группы: кадры одного места по координатам — подряд (общий кеш), остальное — по одному
    groups = {}
    for s in shots:
        groups.setdefault(s["xdg"] or s["n"], []).append(s)
    with tempfile.TemporaryDirectory() as tmp:
        def run_group(g):
            return [run_shot(s, a.size, out, ext, xdg_root, tmp) for s in g]
        with ThreadPoolExecutor(a.jobs) as ex:
            res = [r for rs in ex.map(run_group, groups.values()) for r in rs]
    lines = ["# Кандидаты фона меню (%s)\n" % a.size,
             "Переснять: `tools/shots/menu_art.py --size=3840x2160 --only=NN,…`\n",
             "| № | место | свет | ракурс | описание |", "|---|---|---|---|---|"]
    for s in shots:
        lines.append("| %s | %s | %s | %s | %s |" % (s["n"], s["place"], s["light"], s["camera"], s["desc"]))
    idx = out / ("index.md" if not big else "index_%s.md" % a.size)
    idx.write_text("\n".join(lines) + "\n")
    print("готово: %d из %d, %s" % (sum(res), len(res), out))
    return 0 if all(res) else 1


if __name__ == "__main__":
    sys.exit(main())
