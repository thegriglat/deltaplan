---
type: "research"
status: "active"
module: "rust-wind"
area: "air"
updated: "2026-10-26"
summary: "RW-6a: расчёт размера окон 100/50 м и времени picard_rs на CPU, приложение с таблицами шагов и задач RW-6"
conclusion: "Окна 0,56× и 0,99× области; пара mech+heat сдвиг 50 м — 2,7–4,7 с на 8 потоках, 8–14 с на 2 (расчёт, не замер)"
data: "window_estimate.json"
applied_in: ""
related: ["docs/research/rust-wind-field-path.md", "tools/research/rust_wind/field-path-tables.md"]
---

# tools/research/rust_wind — RW-6a

Разбор — `docs/research/rust-wind-field-path.md`; таблицы шагов и задач — `field-path-tables.md`.

## Воспроизведение
```
python3 tools/research/rust_wind/window_estimate.py   # пишет window_estimate.json; CPU не нагружает
```
Входы: `tests/atmosphere/fixtures/air_model/window/ongudai_w{100,50}_h12.json` (сетки окон), мс/итерацию из `rust/picard_rs/out/final/README.md`, итерации окон из `docs/guide/air-model-gpu/clipmap.md`.

## Что это и чем не является
Расчёт ячеек и масштабирование времени `picard_rs` (линейно по ячейкам); замеров окон на CPU нет (RW-6n умеет `nest`, но решатель ещё не принимает границу окна целиком). Нижняя граница = верхняя × 0,58 (отношение итераций tol 5 / tol 1 на области, для окон не измерено).

## RW-6n: дамп окон 100/50 м (`dump_window.*`)
```
.dpcli/dpcli lock gpu <имя> -- tools/research/rust_wind/dump_window.sh            # снять и записать в rust/dp-air/tests/data/window
.dpcli/dpcli lock gpu <имя> -- tools/research/rust_wind/dump_window.sh --verify   # пересъёмка и сравнение
```
Нужен настоящий RenderingDevice (Godot не headless, как `tools/gpu_tests.sh`). Цепочка как в игре: область 400 м на GPU (Онгудай, условия `ongudai_medium`, место-фикстура `tests/fixtures/wind/places`) → окно 100 м у стартовой площадки → окно 50 м (родитель — окно 100 м; `z_i` столбцов — от поля области, как в клипмапе) → окно 100 м, сдвинутое на 16 клеток к востоку (тёплый старт от окна 100 м). Выход: `inputs.{json,bin}` (вход окон, плоскости `prepare` пар mech/heat — CPU, воспроизводится побитно) и `gpu.{json,bin.zst}` (результат GPU: родитель, обрезанный до нужного окну, типы клеток, граница после поправки потока по срезу плоскостей, поток и площадь граничных граней, итерации пары, коробки итогового поля, для сдвига — прошлое окно и состояние сразу после `K_BC(init) + K_SHIFT`). `--verify`: `inputs.*` — побитно (`cmp`), GPU-часть — в допусках (итерации ±max(20, iters/10), массивы ≤ 1e-4 от масштаба; сравнивает сам дампер). Объём `tests/data/window` ≈ 15 МБ (GPU-часть сжата zstd; несжатая 27 МБ).

Тесты — `rust/dp-air/tests/window.rs`, `tests/level.rs`; код — `rust/dp-air/src/field/window.rs`, `src/level.rs` (`nest`, `shift_warm`).

## Источники и лицензии
Только файлы репозитория (код, конфиги, документы проекта); внешних данных нет. Данные запечённых полей `data/locations/*/air/` читались только по заголовкам.
