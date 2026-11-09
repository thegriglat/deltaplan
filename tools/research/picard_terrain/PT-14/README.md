---
type: "research"
status: "closed"
module: "picard-terrain"
updated: "2026-11-10"
summary: "PT-14: бисекция тестов и разложение поля — подветренная болтанка слабее из-за поля PT-9; снимок расходится из-за PT-10."
related: ["docs/plan/picard-terrain.md", "docs/contracts/picard-terrain.md", "docs/research/picard_terrain.md", "tools/research/picard_terrain/README.md"]
conclusion: "culprit PT-9, cause_kind field_physics (подветренная болтанка/опускание); снимок — PT-10, snapshot; см. out/PT-14/diagnosis.json"
data: "tools/research/picard_terrain/out/PT-14/ (diagnosis.json, tables.json, logs/, probe/, *.patch); сырых данных > 20 МБ нет"
applied_in: ""
---
# PT-14 — разбор: подветренная болтанка и опускание на срезанных клетках

Вывод и числа — `../out/PT-14/diagnosis.json` (поле `verdict`, `answers`, `proposals`) и `../out/PT-14/tables.json` (таблицы по коммитам); отчёт — `.dpcli/dpcli report PT-14`.
Источники, лицензии: данных извне нет; места и рельеф — фикстуры репозитория (`tests/fixtures/locations`, лицензии — `ASSETS.md`),
формулы болтанки — `rust/dp-air/src/terms/turb/`, литература — в `docs/guide/air-model.md` (Bell & Mehta 1990, Panofsky & Dutton 1984, Menke 2019).

## Что здесь

| файл | назначение |
|---|---|
| `build_commit.sh <sha>` | `cargo build -p dp-gd --release` в копии `picard-terrain-PT-14-<sha>`, свой `CARGO_TARGET_DIR`, `.so` → `addons/dp_air/bin/libdp_air_tune.so` |
| `run_godot.sh <sha> <имя> <фильтр или --file=res://…>` | тесты/зонды Godot в копии; лог `out/PT-14/logs/<sha>-<имя>.log` |
| `run_all.sh`, `run_ridge2.sh`, `run_starts.sh`, `run_pins.sh`, `run_patch*.sh` | пакеты запусков (под `.dpcli/dpcli job --lock cpu start …`) |
| `probe_ridge.gd` | зонд синтетического гребня (разложение по слагаемым, дисперсии, полёт с разной точкой отсчёта) |
| `probe_snap.gd` | копия `test_air_field_import` с печатью разностей по точкам |
| `probe_starts.gd` | `test_lee_zone_all_starts` только для `aushkul/aushtau_south` и `ongudai/kayancha_south` + величины снимка поля в точке (`PT14_PINS` — фиксированные точки) |
| `probe/` | отдельный cargo-проект (`dp-air` по пути копии): поле, каналы `u*, shear, U_out, desc`, `lee_f`, σ слагаемого, столбцы, линии на высоте MSL |
| `parse_probe.py`, `starts_table.py`, `cmp_ridge.py`, `build_diagnosis.py`, `finish.py` | разбор логов, таблицы, `tables.json`, `diagnosis.json` |

## Воспроизведение

Копии (по одной на коммит; `rust/`, `tests/`, `configs/` основной копии не меняются):

```bash
for s in f44c66b4a 4316db7e0 9d94bf30c; do
  git worktree add --detach ~/worktrees/deltaplan/picard-terrain-PT-14-$s $s
  .dpcli/dpcli job --lock cpu start PT-14-b$s 3000 tools/research/picard_terrain/PT-14/build_commit.sh $s   # ≈ 7 мин на 1 ядро
done
# первый запуск Godot в копии: godot --headless --path . --import  (≈ 10 мин; run_starts.sh делает сам)
for s in f44c66b4a 4316db7e0 9d94bf30c; do
  .dpcli/dpcli job --lock cpu start PT-14-g$s 3000 tools/research/picard_terrain/PT-14/run_all.sh $s        # field_import, lee_rotor, atmosphere, зонды
  .dpcli/dpcli job --lock cpu start PT-14-v$s 3000 tools/research/picard_terrain/PT-14/run_ridge2.sh $s     # разложение, полёт, дисперсии
  .dpcli/dpcli job --lock cpu start PT-14-q$s 3000 tools/research/picard_terrain/PT-14/probe/build.sh $s    # зонд крейта
  .dpcli/dpcli job --lock cpu start PT-14-r$s 3000 tools/research/picard_terrain/PT-14/probe/run.sh $s      # ridge25/ridge6/flat14/ridge25gd
done
# старты на реальном рельефе: сначала свободный выбор точки на каждом коммите, затем те же точки на всех
.dpcli/dpcli job --lock cpu start PT-14-s$s 7200 tools/research/picard_terrain/PT-14/run_starts.sh $s
PT14_PINS=…/out/PT-14/pinsA.json tools/research/picard_terrain/PT-14/run_starts.sh $s starts_pinA   # точки f44c66b4a
PT14_PINS=…/out/PT-14/pinsB.json tools/research/picard_terrain/PT-14/run_starts.sh $s starts_pinB   # точки PT-9
python3 tools/research/picard_terrain/PT-14/build_diagnosis.py && python3 tools/research/picard_terrain/PT-14/finish.py
```

Входы Rust-зонда на гребне — ровно те, что отправляет фасад GDScript: `probe_ridge.gd` пишет `out/PT-14/gdinput-250.json`
(конфиги и условия), зонд читает его через `PT14_GDINPUT`.

Патчи проверялись в отдельной копии `picard-terrain-PT-14-patch` (9d94bf30c) — `git diff` в ней и есть файлы `out/PT-14/*.patch`:
`patch_snapshot_k1.patch` (GDScript: `air_field_import.gd`, `wind_field.gd`), `patch_tests_lee.patch` (`tests/atmosphere`).
Применять в `main`/ветке модуля — решение координатора; `rust/`, `tests/`, `configs/` этой задачей не менялись.

## Допущения и границы

- Синтетический гребень — как в тестах: высота 300 м, `exp(−(x/400)²)`, ветер с 270°, ровное место 6 км, поле 400 м (окон 50/100 м в снимке нет).
  Гребень этой ширины на сетке 400 м не разрешён: числа в точке x = 350 м — интерполяция между столбцом гребня и первым подветренным.
- Зонд крейта считает σ_w по формулам `sigma.rs` из каналов поля; σ из разложения фасада — другая сводная величина (в 1,3–1,6 раза),
  поэтому сравнения «до/после» делались внутри одного источника.
- Реальный рельеф: два старта из десяти; остальные восемь — числа координатора (на всех 10 отношение упало).
- Один сид шума, один момент (12 ч, 0 с). Полёт 30 с — одна реализация, не статистика.
- Замеры не FPS, замок GPU не брался; CPU-работы — под `lock cpu` (кроме одного короткого прогона `probe_ridge` вне замка).
