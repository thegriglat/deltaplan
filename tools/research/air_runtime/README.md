---
type: "research"
status: "closed"
module: "air-model"
updated: "2026-10-03"
summary: "AM-06Б: ход среднего поля в точке при пересчёте поля в полёте (плавная подмена уровней, AirRuntime)."
related: ["docs/guide/air-model.md"]
conclusion: ""
data: "tools/research/air_runtime/out/"
applied_in: "scripts/atmosphere (AirRuntime, подмена поля)"
---

# Пересчёт поля в полёте (AM-06Б)

**Вопрос.** Как меняется среднее поле в точке при пересчёте в полёте и плавна ли подмена.

**Что лежит.** `plot_blend.py` — график хода поля; вход — CSV из GPU-теста `AirRuntime` (переменная `AIR_RUNTIME_TRACE`). `out/blend_trace.csv`, `out/blend_trace.png` — данные и рисунок.

**Данные.** `tools/research/air_runtime/out/`. Описание — `docs/guide/air-model.md` (пересчёт и подмена, контракт C8).
