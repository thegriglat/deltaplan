#!/usr/bin/env python3
"""Проверка вывода замера против контракта SH5: python3 check_schema.py <папка out/<метка>>.
Обязательные поля — по `dp plan surface-heat --contracts SH5`; null допустим только там, где
контракт разрешает (вода: t_water_c, h_mean_wm2 до SH-4). Exit 0 — всё в порядке."""
import csv
import json
import sys
from pathlib import Path


def num(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool)


def check(d, errs, name):
    def need(path, cond, msg=None):
        if not cond:
            errs.append(f"{name}: {path}{' — ' + msg if msg else ''}")

    for k in ("location", "hour", "commit"):
        need(k, k in d)
    if "error" in d:
        errs.append(f"{name}: замер не удался: {d['error']}")
        return
    h = d.get("h_wm2")
    need("h_wm2", isinstance(h, dict) and all(num(h.get(k)) for k in ("mean", "p10", "p50", "p90")))
    bc = d.get("h_by_class")
    need("h_by_class", isinstance(bc, dict) and len(bc) > 0)
    if isinstance(bc, dict):
        for c, v in bc.items():
            need(f"h_by_class.{c}", isinstance(v, dict) and num(v.get("area_frac")) and num(v.get("mean")))
        s = sum(v.get("area_frac", 0) for v in bc.values())
        need("h_by_class: сумма area_frac", abs(s - 1.0) < 0.01, f"{s:.3f}")
    so = d.get("sources")
    need("sources", isinstance(so, dict) and num(so.get("n")) and num(so.get("density_km2")))
    if isinstance(so, dict) and so.get("n", 0) > 0:
        st = so.get("strength_ms")
        need("sources.strength_ms", isinstance(st, dict) and all(num(st.get(k)) for k in ("mean", "p10", "p90")))
        c = d.get("ceiling_agl_m")
        need("ceiling_agl_m", isinstance(c, dict) and all(num(c.get(k)) for k in ("p10", "p50", "p90")))
    sl = d.get("slope_lift")
    need("slope_lift", isinstance(sl, list) and len(sl) > 0)
    if isinstance(sl, list):
        for e in sl:
            need("slope_lift[].w_ms", "start" in e and num(e.get("w_ms")))
    lee = d.get("lee")
    need("lee", isinstance(lee, list))
    if isinstance(lee, list):
        for e in lee:
            if "error" in e:
                errs.append(f"{name}: lee: {e['error']}")
            else:
                need("lee[]", "site" in e and num(e.get("w_min_ms")) and num(e.get("sigma_w_ms")))
    w = d.get("water")
    need("water", isinstance(w, dict) and num(w.get("area_frac")) and "t_water_c" in w and "t_air_c" in w and "h_mean_wm2" in w)
    if isinstance(w, dict):  # null допустим, если нечем заполнить; число — только числом
        for k in ("t_water_c", "t_air_c", "h_mean_wm2"):
            need(f"water.{k}", w.get(k) is None or num(w.get(k)))


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    p = Path(sys.argv[1])
    files = sorted(p.glob("*_h*.json"))
    if not files:
        print(f"нет файлов *_h*.json в {p}")
        return 1
    errs = []
    for f in files:
        check(json.loads(f.read_text()), errs, f.name)
    s = p / "summary.csv"
    if not s.exists():
        errs.append("нет summary.csv")
    else:
        rows = list(csv.DictReader(s.open()))
        if len(rows) != len(files):
            errs.append(f"summary.csv: {len(rows)} строк, файлов {len(files)}")
    for e in errs:
        print("ОШИБКА", e)
    print(f"{len(files)} файлов, ошибок {len(errs)}")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
