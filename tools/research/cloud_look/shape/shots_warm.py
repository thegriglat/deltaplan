#!/usr/bin/env python3
"""Кадры меню с другим числом прогревочных кадров — вторая выборка дрожания луча для меры шума
(measure_frames.py: «шум между кадрами»). Обёртка над tools/shots/menu_art.py (он не меняется):

    .dpcli/dpcli lock cpu <имя> -- python3 shots_warm.py --root=<копия> --warm=44 --only=09,34 \
        --size=1920x1080 --out=<каталог> [--xdg=<кеш мест>] [--cfg=<json clouds…>]

Начало луча в марше дрожит по пикселям и по кадрам (IGN, сдвиг frame % 64 по золотому сечению):
кадры с прогревом 40 и 44 — один мир, одна камера, разные фазы дрожания. --cfg — JSON поверх
atmosphere.json (кладётся в <xdg>/<место>/Deltaplan/configs/atmosphere.json на время съёмки).
"""
import argparse
import importlib.util
import json
import sys
import tempfile
from pathlib import Path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--warm", type=int, default=44)
    ap.add_argument("--only", default="")
    ap.add_argument("--size", default="1920x1080")
    ap.add_argument("--out", required=True)
    ap.add_argument("--xdg", default="/home/greg/deltaplan/build/menu_art_xdg")
    ap.add_argument("--cfg", default="")
    a = ap.parse_args()
    root = Path(a.root).resolve()
    spec = importlib.util.spec_from_file_location("menu_art", root / "tools/shots/menu_art.py")
    ma = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ma)
    data = json.loads((root / "tools/shots/menu_art.json").read_text())
    shots = ma.expand(data)
    only = set(x for x in a.only.split(",") if x)
    out = Path(a.out)
    (out / "logs").mkdir(parents=True, exist_ok=True)
    xdg = Path(a.xdg)
    with tempfile.TemporaryDirectory() as tmp:
        for s in shots:
            if only and s["n"] not in only:
                continue
            s["cfg"]["warmup_frames"] = a.warm
            if s["xdg"]:
                d = xdg / s["xdg"] / "Deltaplan" / "configs"
                d.mkdir(parents=True, exist_ok=True)
                (d / "atmosphere.json").write_text(a.cfg or "{}")
            ma.run_shot(s, a.size, out, "jpg", xdg, tmp)


if __name__ == "__main__":
    sys.exit(main())
