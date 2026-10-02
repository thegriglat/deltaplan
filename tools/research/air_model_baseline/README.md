---
type: "research"
status: "closed"
module: "air-model"
updated: "2026-10-03"
summary: "AM-00: зонд базовых цифр до новой модели воздуха (время air_velocity_at, статистика рывков за подветренной зоной, термики за день)."
related: ["docs/archive/plan/air-model-baseline.md"]
conclusion: "air_velocity_at 14,3 мкс/вызов; полёт ongudai medium 89–117 FPS (RTX 4070 SUPER) — точка отсчёта «до/после»."
data: "tools/research/air_model_baseline/"
applied_in: "сравнение масштабов 1–3 (docs/archive/plan/air-model-baseline.md)"
---

# Базовые цифры AM-00

**Вопрос.** Что считалось и сколько стоило до масштабов 2 и 3 модели воздуха: чтобы сравнивать «до/после».

**Что лежит.** `probe.gd` + `probe.tscn` — headless-зонд (фиксированный сид; только читает `atmosphere.gd`, `thermal_field.gd`, `game.gd` через публичное API): время `air_velocity_at`, СКО вертикали и частота рывков за подветренной зоной, термики за день на двух местах. Переиспользуем для AM-07/AM-08.

**Данные.** Результаты — в `docs/archive/plan/air-model-baseline.md` (таблицы, как запускать). Каталог — только код зонда.
