#!/usr/bin/env python3
"""Логика вердикта ШП-2 (П3 v3) на синтетических числах metrics.json — без данных и GPU.

Проверяется `pilotnn.report.shp2_rule`: порядок «отказ → идём (правило v2 на сошедшихся) → правим подход», отказ по
медиане на ВСЕХ случаях (г) и по лучшей из двух базовых линий (регрессия air-lite не входит), несошедшиеся — строка
`nc` без влияния на вердикт, пустые группы.

  .venv/bin/python tests/test_verdict.py        # exit=0, если все сценарии дают ожидаемый вердикт
"""
from __future__ import annotations

import copy
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
from pilotnn import common as C  # noqa: E402
from pilotnn.report import shp2_rule  # noqa: E402

AGL = [25, 50, 75, 100, 150, 200, 300, 400, 600, 800, 1100, 1500, 2000]


def group(n=20, wind_ok=0.95, lift_ok=0.95, wind_med=0.1, bias=0.0, v=5.0, spread=None):
    """Результат одной группы AreaAcc: доли «ок», медиана ветра, смещение e (одинаковое по высотам), средняя |V|."""
    st = lambda med: dict(median=med, p90=2 * med, mean=med)  # noqa: E731
    area = dict(n_points=1000, n_points_m=1000, frac_wind_ok=wind_ok, frac_lift_m_ok=lift_ok, frac_lift_h_ok=lift_ok,
                frac_all_ok=lift_ok, wind=st(wind_med), lift_m=st(0.03), lift_h=st(0.03))
    ridge = dict(area, e_mean=bias, v_mean=v)
    return dict(n_cases=n, n_cases_m=n, area=area, ridge=ridge,
                bias=dict(e=[bias] * 13, v=[v] * 13, w_m=[0.0] * 13, w_h=[0.0] * 13),
                bias_bins={"0–2": dict(cases=n, e=[bias] * 13, v=[v] * 13)},
                targets_h={"final": n}, targets_m={"final": n}, **({"spread_ratio": spread} if spread else {}))


def metrics(conv=None, nc=None, al=None, inflow=1.0, mean=1.2, net_all=0.1):
    """metrics.json: сеть на (г) — группы conv/nc/all; базовые линии — только `all` (нужны для отказа) и conv."""
    conv = conv if conv is not None else group()
    al = al if al is not None else group(wind_med=net_all)
    net = dict(conv=conv, nc=nc, all=al)
    base = lambda med: dict(conv=group(wind_med=med), nc=None, all=group(wind_med=med))  # noqa: E731
    ec = dict(wind_ok_ms=0.3, wind_ok_rel=0.1, lift_ok_ms=0.1,
              shp2=dict(set="holdout_sys", frac_ok=0.9, bias_abs_ms=0.1, bias_rel=0.02, bias_max_agl_m=300,
                        bin_min_cases=3, refuse_ratio=1.0))
    return dict(agl=AGL, config_eval=ec, sets=dict(holdout_sys=dict(net=net, inflow=base(inflow), mean=base(mean))))


def verdict(M):
    return shp2_rule(M)


def main():
    ok = True

    def expect(name, got, want):
        nonlocal ok
        good = got == want
        ok &= good
        print(f"{'ok  ' if good else 'FAIL'} {name}: {got!r}" + ("" if good else f" (ожидалось {want!r})"))

    # 1. хорошая сеть на сошедших, не хуже базы -> идём
    R = verdict(metrics())
    expect("идём: правило v2 на сошедшихся выполнено", R["verdict"], "идём в волну 0")
    expect("  все проверки выполнены", all(c["ok"] for c in R["checks"]), True)

    # 2. отказ: сеть не лучше лучшей базы на ВСЕХ случаях, даже если на сошедшихся всё отлично
    R = verdict(metrics(net_all=1.0, inflow=1.0, mean=1.2))
    expect("отказ: медиана сети (все) = лучшая база", R["verdict"], "отказ от направления")
    expect("  отношение", round(R["refuse"]["ratio"], 6), 1.0)
    R = verdict(metrics(net_all=1.1, inflow=1.5, mean=1.0))
    expect("отказ: лучшая база — среднее", (R["verdict"], R["refuse"]["base"]), ("отказ от направления", "mean"))
    # отказ идёт раньше правила v2, а не после
    R = verdict(metrics(conv=group(wind_ok=0.5), net_all=2.0, inflow=1.0))
    expect("отказ раньше «правим подход»", R["verdict"], "отказ от направления")

    # 3. не отказ, но правило v2 на сошедшихся не выполнено -> правим подход
    for name, conv in (("доля ок ветра 80 %", group(wind_ok=0.8)), ("доля ок подъёма 85 %", group(lift_ok=0.85)),
                       ("смещение 0,3 м/с при |V| = 5", group(bias=0.3))):
        R = verdict(metrics(conv=conv))
        expect(f"правим: {name}", R["verdict"], "правим подход")
    # порог смещения max(0,1; 2 % |V|): |V| = 10 -> 0,2
    expect("идём: смещение 0,15 при |V| = 10 (порог 0,2)", verdict(metrics(conv=group(bias=0.15, v=10.0)))["verdict"],
           "идём в волну 0")

    # 4. несошедшиеся не влияют на вердикт (ни плохие, ни хорошие)
    bad_nc = group(n=8, wind_ok=0.1, lift_ok=0.2, bias=1.0, spread=dict(n=8, median=1.3, p90=2.0))
    R = verdict(metrics(nc=bad_nc))
    expect("идём при плохих несошедшихся", R["verdict"], "идём в волну 0")
    expect("  строка nc: правило не выполнено", (R["nc"]["applicable"], R["nc"]["ok"]), (True, False))
    expect("  строка nc: отношение к разбросу", R["nc"]["spread_ratio"]["median"], 1.3)
    R = verdict(metrics(conv=group(wind_ok=0.8), nc=group(n=8)))
    expect("правим при хороших несошедшихся", R["verdict"], "правим подход")
    expect("  строка nc: выполнено", R["nc"]["ok"], True)
    R = verdict(metrics())
    expect("нет несошедших: строка nc не применима", R["nc"]["applicable"], False)

    # 5. нет сошедшихся в (г) -> не к чему применить, правим (отказ по всем случаям всё равно проверяется)
    M = metrics(); M["sets"]["holdout_sys"]["net"]["conv"] = None
    R = verdict(M)
    expect("нет сошедшихся: правим подход", R["verdict"], "правим подход")
    M["sets"]["holdout_sys"]["net"]["all"] = group(wind_med=3.0)
    expect("нет сошедшихся, но сеть хуже базы: отказ", verdict(M)["verdict"], "отказ от направления")

    # 6. нет набора (г) -> правим подход
    M = metrics(); M["sets"] = {}
    expect("нет (г): правим подход", verdict(M)["verdict"], "правим подход")

    # 7. порог refuse_ratio из конфига
    M = metrics(net_all=0.8, inflow=1.0, mean=1.2)
    expect("отношение 0,8 при пороге 1,0: не отказ", verdict(M)["verdict"], "идём в волну 0")
    M["config_eval"]["shp2"]["refuse_ratio"] = 0.75
    expect("отношение 0,8 при пороге 0,75: отказ", verdict(M)["verdict"], "отказ от направления")

    # 8. исходные metrics не мутируются правилом
    M = metrics(); M0 = copy.deepcopy(M); verdict(M)
    expect("shp2_rule не меняет metrics", M == M0, True)
    cfg = C.load_config(HERE / "config.yaml")
    expect("config.yaml: refuse_ratio = 1,0", cfg["eval"]["shp2"]["refuse_ratio"], 1.0)

    print(f"exit={0 if ok else 1}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
