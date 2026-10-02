---
type: "research"
status: "closed"
module: "air-model"
updated: "2026-10-03"
summary: "AM-07: термики из поля — замеры — Описание модели — docs/guide/air-model.md → «Масштаб 2: термики из поля»."
related: []
conclusion: ""
data: "tools/research/air_thermals/"
applied_in: ""
---
# AM-07: термики из поля — замеры

Описание модели — `docs/guide/air-model.md` → «Масштаб 2: термики из поля». Здесь — как получены числа.

## Поля (эталон AM-01, вне git: `fields/`, ~45 МБ)
```bash
cd tools/research/air_thermals
PY=/home/greg/deltaplan/tools/research/heat_ca/.venv/bin/python
flock /tmp/heat_ca_gpu.lock $PY make_fields.py        # h12, h15, h09: область 400 м + окно 100 м, с нагревом и без
$PY make_fields.py --fixture                          # фикстура тестов (32×32×40 у старта) — tests/atmosphere/fixtures/air_model/thermals/
```
Онгудай, ветер 3 м/с со 150°, ясно, типичный июль (weather.py). В `.json` поля кроме каналов:
`heat` (массив в `.bin`), `h_bl`, `z_i`, `gam`, `u10`, `z_lcl` (кромка погоды).

## Замеры и картинки
```bash
cd ../../..
XDG_DATA_HOME=$(mktemp -d) godot --headless --path . res://tools/research/air_thermals/probe.tscn   # ~1 ч; -- --quick — окно 12:00
cd tools/research/air_thermals && $PY figs.py
```
- `out/sources_<поле>.json` — источники и карты столбцов (H, W̄, F̄, Φ, водосбор); области 400 м — вне git;
- `out/fig_sources_<поле>.png` — H, W̄, Φ и источники (∝ силе) поверх рельефа;
- `out/stats.json` — термики за 4 ч в круге 6 км у Каянчи, с полем и аналитикой (как база AM-00);
- `out/flux.json` — поток массы: по площади на ξ 0,25/0,5/0,75, по 12 водосборам, по термикам;
- `out/net.json` — сколько столбцов-источников расходится без ведущего при шуме поля 1e-3/1e-4·|u₀|;
- `fields/probe_full.log` — лог полного прогона (вне git).
- `out/fig_before_after_<поле>.png` — было/стало (AM-07 → AM-07б): `$PY figs.py --compare OLD NEW OUT`,
  OLD — `sources_*.json` до AM-07б (`git show <коммит>:tools/research/air_thermals/out/sources_kayancha_w100_h12.json`).
