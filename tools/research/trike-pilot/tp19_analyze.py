#!/usr/bin/env python3
"""TP-19: разбор временных рядов tp19_runner.gd -> tp19_modes.json / tp19_modes.csv.

Запуск: python3 tools/research/trike-pilot/tp19_analyze.py <series.jsonl> [out_dir]
Для каждого прогона: окно установившегося режима (t >= 60 с; для толчка — после kick_t),
средняя / мин / макс скорость, период качания (по пересечениям среднего), отношение размахов
за период (затухание: < 1 — гаснет, > 1 — растёт), диапазоны alpha/theta, срыв, сила рук.
"""
import csv
import json
import math
import sys
from pathlib import Path


def crossings(t, y, m):
    """Моменты пересечения m снизу вверх (линейная интерполяция)."""
    out = []
    for i in range(1, len(y)):
        if y[i - 1] < m <= y[i]:
            f = (m - y[i - 1]) / (y[i] - y[i - 1])
            out.append(t[i - 1] + f * (t[i] - t[i - 1]))
    return out


def early_ratio(s, t0=15.0, t1=60.0):
    """Отношение размахов за период в начале (15–60 с): рост/затухание до выхода на предельный цикл."""
    t, v = s["t"], s["v"]
    idx = [i for i, x in enumerate(t) if t0 <= x <= t1]
    tt = [t[i] for i in idx]
    vv = [v[i] for i in idx]
    if len(vv) < 40:
        return None
    vm = sum(vv) / len(vv)
    cr = crossings(tt, vv, vm)
    amps = []
    for j in range(1, len(cr)):
        seg = [x for x, ti in zip(vv, tt) if cr[j - 1] <= ti < cr[j]]
        if seg:
            amps.append(max(seg) - min(seg))
    rs = [amps[j] / amps[j - 1] for j in range(1, len(amps)) if amps[j - 1] > 0.05]
    if not rs:
        return None
    return round(math.exp(sum(math.log(x) for x in rs) / len(rs)), 3)


def analyze(r):
    s = r["series"]
    sp = r["spec"]
    t = s["t"]
    kick = float(sp.get("kick_t", -1))
    t0 = kick + 0.5 if kick > 0 else 60.0
    idx = [i for i, x in enumerate(t) if x >= t0]
    if len(idx) < 40:
        return {"name": r["name"], "ok": False}
    sl = lambda k: [s[k][i] for i in idx]
    tt, v, a, th, vy, fx, st = sl("t"), sl("v"), sl("alpha"), sl("theta"), sl("vy"), sl("fx_bar"), sl("stall")
    strap = sl("strap_deg")
    # для толчка — равновесие по концу окна (последние 20 с), иначе среднее
    if kick > 0:
        tail = [x for x, ti in zip(v, tt) if ti >= tt[-1] - 20]
        vm = sum(tail) / len(tail)
    else:
        vm = sum(v) / len(v)
    cr = crossings(tt, v, vm)
    period = (cr[-1] - cr[0]) / (len(cr) - 1) if len(cr) >= 3 else None
    # размахи (макс − мин) по периодам между пересечениями
    amps = []
    for j in range(1, len(cr)):
        seg = [x for x, ti in zip(v, tt) if cr[j - 1] <= ti < cr[j]]
        if seg:
            amps.append(max(seg) - min(seg))
    ratio = None
    if len(amps) >= 2:
        rs = [amps[j] / amps[j - 1] for j in range(1, len(amps)) if amps[j - 1] > 0.05]
        if rs:
            ratio = math.exp(sum(math.log(x) for x in rs[:4]) / len(rs[:4]))
    zeta = None
    if ratio is not None and period and 0 < ratio < 1:
        ld = -math.log(ratio)
        zeta = ld / math.sqrt(4 * math.pi ** 2 + ld ** 2)
    return {
        "name": r["name"], "ok": True, "finite": r["finite"],
        "u": sp.get("u"), "g": sp.get("g"),
        "v_mean_kmh": round(sum(v) / len(v), 2), "v_min_kmh": round(min(v), 2), "v_max_kmh": round(max(v), 2),
        "v_eq_kmh": round(vm, 2),
        "period_s": round(period, 2) if period else None,
        "amp_first_kmh": round(amps[0], 2) if amps else None,
        "amp_ratio_per_period": round(ratio, 3) if ratio else None,
        "zeta": round(zeta, 3) if zeta else None,
        "amp_ratio_early_15_60s": early_ratio(s) if kick <= 0 else None,
        "loop_or_tumble": max(abs(x) for x in a) > 60.0,
        "alpha_min_deg": round(min(a), 2), "alpha_max_deg": round(max(a), 2),
        "alpha_mean_deg": round(sum(a) / len(a), 2),
        "theta_min_deg": round(min(th), 2), "theta_max_deg": round(max(th), 2),
        "vy_mean_ms": round(sum(vy) / len(vy), 2),
        "fx_bar_mean_n": round(sum(fx) / len(fx), 1),
        "strap_mean_deg": round(sum(strap) / len(strap), 2),
        "stall_max": round(max(st), 3),
    }


def main():
    src = Path(sys.argv[1])
    out = Path(sys.argv[2]) if len(sys.argv) > 2 else Path(__file__).parent
    rows = []
    with src.open() as f:
        for line in f:
            if line.strip():
                rows.append(analyze(json.loads(line)))
    (out / "tp19_modes.json").write_text(json.dumps(rows, ensure_ascii=False, indent=1))
    keys = list(rows[0].keys())
    with (out / "tp19_modes.csv").open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=keys, extrasaction="ignore")
        w.writeheader()
        for r in rows:
            w.writerow(r)
    for r in rows:
        if not r.get("ok"):
            print(r["name"], "нет данных")
            continue
        print(f"{r['name']:22s} V {r['v_mean_kmh']:6.1f} [{r['v_min_kmh']:6.1f}..{r['v_max_kmh']:6.1f}] "
              f"T {r['period_s']} ke {r['amp_ratio_early_15_60s']} loop {int(r['loop_or_tumble'])} amp {r['amp_first_kmh']} k {r['amp_ratio_per_period']} z {r['zeta']} "
              f"a [{r['alpha_min_deg']}..{r['alpha_max_deg']}] th [{r['theta_min_deg']}..{r['theta_max_deg']}] "
              f"vy {r['vy_mean_ms']} fx {r['fx_bar_mean_n']} strap {r['strap_mean_deg']} st {r['stall_max']}")


if __name__ == "__main__":
    main()
