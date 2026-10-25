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
Расчёт ячеек и масштабирование времени `picard_rs` (линейно по ячейкам); замеров окон на CPU нет — крейт не умеет `nest`. Нижняя граница = верхняя × 0,58 (отношение итераций tol 5 / tol 1 на области, для окон не измерено).

## Источники и лицензии
Только файлы репозитория (код, конфиги, документы проекта); внешних данных нет. Данные запечённых полей `data/locations/*/air/` читались только по заголовкам.
