#!/usr/bin/env python3
"""Проверка отчёта пилота по контракту П3 v2: report.md — все разделы на месте, картинки по ссылкам существуют;
metrics.json — точки области/гребней/центров, смещение по 13 высотам и корзинам U10, кривая на (г) и (б), признаки
рельефа, ONNX; вердикт ШП-2 в report.md = правилу `report.shp2_rule`, пересчитанному из metrics.json.
Печатает строку «ШП-2: <вердикт>».

  .venv/bin/python tests/check_report_v2.py --latest-smoke        # последний отчёт профиля smoke
  .venv/bin/python tests/check_report_v2.py <каталог отчёта>
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
from pilotnn import common as C  # noqa: E402
from pilotnn.report import SECTIONS, VERDICTS, shp2_rule  # noqa: E402

N_AGL = 13
REQUIRED_SETS = ("holdout_sys", "holdout_place")      # П3 v2: (г) — главное, (б) — Онгудай; оба нужны и в smoke


def latest(profile="smoke"):
    cfg = C.load_config(HERE / "config.yaml", profile)
    base = C.expand(cfg["paths"]["base"], cfg) / "reports"
    reps = sorted((p.parent for p in base.glob("*/report.md")), key=lambda d: (d / "report.md").stat().st_mtime)
    if not reps:
        raise SystemExit(f"нет отчётов в {base}")
    return reps[-1]


def check(rep: Path):
    errs = []
    md = (rep / "report.md").read_text()
    M = json.loads((rep / "metrics.json").read_text())
    for s in SECTIONS:
        if s not in md:
            errs.append(f"report.md: нет раздела «{s}»")
    for img in re.findall(r"\]\((figures/[^)]+)\)", md):
        if not (rep / img).exists():
            errs.append(f"нет картинки {img}")
    if len(re.findall(r"\]\(figures/", md)) < 5:
        errs.append("меньше 5 картинок")
    agl = M.get("agl") or []
    if len(agl) != N_AGL:
        errs.append(f"agl: {len(agl)} высот")
    sets = M.get("sets") or {}
    for s in REQUIRED_SETS:
        if not sets.get(s):
            errs.append(f"metrics: нет набора {s}")
    for s, d in sets.items():
        if not d:
            continue
        for pn in ("net", "inflow", "mean"):
            x = d.get(pn) or {}
            a = x.get("area") or {}
            for k in ("frac_wind_ok", "frac_lift_m_ok", "frac_lift_h_ok", "frac_all_ok", "wind", "lift_m", "lift_h"):
                if k not in a:
                    errs.append(f"{s}/{pn}/area: нет {k}")
            r = x.get("ridge") or {}
            for k in ("frac_wind_ok", "e_mean", "v_mean"):
                if k not in r:
                    errs.append(f"{s}/{pn}/ridge: нет {k}")
            b = x.get("bias") or {}
            for k in ("e", "v", "w_m", "w_h"):
                if len(b.get(k) or []) != N_AGL:
                    errs.append(f"{s}/{pn}/bias/{k}: не 13 высот")
            if not x.get("bias_bins"):
                errs.append(f"{s}/{pn}: нет корзин U10")
        if not (M.get("centers") or {}).get(s):
            errs.append(f"centers: нет набора {s}")
    hs = sets.get("holdout_sys") or {}
    if hs and M.get("p6_systems"):
        G = hs.get("groups") or {}
        if not any(g.startswith("система ") for g in G) or not any(g.startswith("уклон ") for g in G):
            errs.append("(г): нет разбивки по системам и корзинам уклона")
    cv = M.get("curve") or []
    if len(cv) < 2:
        errs.append(f"кривая: {len(cv)} точек (< 2)")
    if cv and not cv[-1].get("is_main"):
        errs.append("кривая: последняя точка — не основная сеть (полный пул)")
    for c in cv:
        for s in REQUIRED_SETS:
            if not (c.get(s) or {}).get("area"):
                errs.append(f"кривая {c.get('n_places')}: нет оценки на {s}")
    if not (M.get("terrain") or {}).get("groups"):
        errs.append("нет таблицы признаков рельефа")
    if not (M.get("onnx") or {}).get("ort_vs_torch_ok"):
        errs.append("ONNX: ORT ↔ PyTorch не ок")
    shp = (M.get("config_eval") or {}).get("shp2") or {}
    for k in ("set", "frac_ok", "bias_abs_ms", "bias_rel", "bias_max_agl_m", "bin_min_cases", "refuse_ratio"):
        if k not in shp:
            errs.append(f"config eval.shp2: нет {k}")
    R = shp2_rule(M)
    m = re.search(r"\*\*ШП-2: ([^*]+)\*\*", md)
    got = m.group(1).strip() if m else None
    if got not in VERDICTS:
        errs.append(f"report.md: вердикт ШП-2 не найден или неизвестен: {got!r}")
    elif got != R["verdict"]:
        errs.append(f"вердикт в report.md «{got}» ≠ правилу из metrics.json «{R['verdict']}»")
    return errs, R


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("rep", nargs="?")
    ap.add_argument("--latest-smoke", action="store_true")
    a = ap.parse_args()
    rep = latest() if a.latest_smoke or not a.rep else Path(a.rep)
    errs, R = check(rep)
    print(f"отчёт: {rep}")
    for c in R["checks"]:
        print(f"  {'да ' if c['ok'] else 'НЕТ'} {c['what']}: {c['value']:.4g} (порог {c['thr']})")
    if errs:
        print("ошибки:\n  " + "\n  ".join(errs))
        print("вердикт ШП-2 не выдан: отчёт не прошёл проверку П3 v2")
        sys.exit(1)
    print(f"П3 v2: все разделы и числа на месте ({len(SECTIONS)} разделов)")
    print(f"ШП-2: {R['verdict']}")


if __name__ == "__main__":
    main()
