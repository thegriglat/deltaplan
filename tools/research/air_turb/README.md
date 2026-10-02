---
type: "research"
status: "closed"
module: ""
updated: "2026-10-03"
summary: "AM-08: возмущения из поля (масштаб 3) — замеры — Описание модели — docs/guide/air-model.md → «Масштаб 3: возмущения из поля»."
related: []
conclusion: ""
data: "tools/research/air_turb/"
applied_in: ""
---
# AM-08: возмущения из поля (масштаб 3) — замеры

Описание модели — `docs/guide/air-model.md` → «Масштаб 3: возмущения из поля».

| Файл | Что |
|---|---|
| `lee_fields.py` | поля масштаба 1 у подветренных стартов базы AM-00 (эталон `air3d/air.py`, окно 100 м, 13:00, 20 км/ч с обратной стороны старта) → `fields/` (**вне git**, ~4–5 МБ на старт; пересчёт ~3 с на старт под `flock /tmp/heat_ca_gpu.lock`) |
| `turb_probe.gd` + `.tscn` | замеры: `--only=lee` (СКО w, рывки, среднее w в точке базы AM-00, с полем и без), `--only=table` (σ от ветра, у бровки, в устойчивом воздухе), `--only=spectrum` (запись u, w на прямом полёте → `out/flight_*.csv`) |
| `spectrum.py` | спектр Уэлча и наклон в инерционном интервале → `out/spectrum.png`, `out/spectrum.json` |
| `wstar_check.gd` | w* болтанки против w* источников термиков AM-07 (одна формула `WindField.deardorff_wstar`) |
| `noise_line.gd` | спектр одной октавы симплекс-шума (длина волны пика = 1,75 масштаба) |

Воспроизвести (из корня копии):
```
PY=/home/greg/deltaplan/tools/research/heat_ca/.venv/bin/python
(cd tools/research/air3d && flock /tmp/heat_ca_gpu.lock $PY ../air_turb/lee_fields.py)
for o in lee table spectrum; do XDG_DATA_HOME=$(mktemp -d) godot --headless --path . \
  res://tools/research/air_turb/turb_probe.tscn -- --only=$o; done
$PY tools/research/air_turb/spectrum.py --fmin 0.1 --fmax 1.0
godot --headless --path . -s tools/research/air_turb/wstar_check.gd -- \
  tests/atmosphere/fixtures/air_model/thermals/kayancha_w100_h12 tools/research/air_turb/fields/altai_sinyukha_west_w100_h13
```
