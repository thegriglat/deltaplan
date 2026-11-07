"""WF-2: сверка нового кода (один проход, k = 1) с прежним режимом inflow (WF-1, до правки).
Читает summary.json (u_start10_inflow, umax_100m_inflow до правки) и after.json (прогон
`run.sh after`: rows[] с u_start10 и umax_100; рядом или out/after.json), печатает по местам
сравнение и `max_rel=<число>` — максимум |after − before| / before по U10 у старта и max100
всех мест. Ожидаемо ≈ 0: тот же путь (k = 1); summary.json округлён (U10 — 3 знака, max100 — 2),
округляем так же after. Запуск: python3 -I tools/research/wind_forecast/compare_after.py"""
import json
import os
import sys

H = os.path.dirname(os.path.abspath(__file__))


def load_after():
    for p in (os.path.join(H, "after.json"), os.path.join(H, "out", "after.json")):
        if os.path.exists(p):
            return json.load(open(p))["rows"]
    sys.exit("нет after.json: .dpcli/dpcli job --lock cpu start wf2-after 3600 tools/research/wind_forecast/run.sh after")


before = {p["place"]: p for p in json.load(open(os.path.join(H, "summary.json")))["places"]}
after = {r["name"]: r for r in load_after()}
max_rel = 0.0
for name, b in before.items():
    a = after.get(name)
    if a is None or "error" in a:
        print(f"{name}: нет результата ({a and a.get('error')})")
        max_rel = float("inf")
        continue
    pairs = [("U10", b["u_start10_inflow"], round(a["u_start10"], 3)), ("max100", b["umax_100m_inflow"], round(a["umax_100"], 2))]
    for what, was, now in pairs:
        rel = abs(now - was) / was
        max_rel = max(max_rel, rel)
        print(f"{name:18s} {what:7s} до {was:8.3f}  после {now:8.3f}  отн. {rel:.2e}")
    print(f"{name:18s} проходов {a.get('passes_run')}, загрузка {a.get('ready_s', 0):.1f} с")
print(f"max_rel={max_rel:.6f}")
