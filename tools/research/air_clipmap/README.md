---
type: "research"
status: "closed"
module: "air-model"
updated: "2026-10-03"
summary: "Стык уровней клипмапа AM-04: профиль поля вдоль линии через края окон 50 и 100 м, выборка игры против отдельных уровней."
related: ["docs/guide/air-model.md", "docs/contracts/air-model.md"]
conclusion: ""
data: "tools/research/air_clipmap/out/"
applied_in: "scripts/atmosphere (AirClipmap, AirFieldSet), контракт C7"
---

# Клипмап: стык уровней (AM-04)

**Вопрос.** Нет ли разрыва поля воздуха на границе окон 50 м и 100 м (смешение уровней с весом края).

**Что лежит.**
- `seam_plot.py` — график профиля вдоль линии на восток от старта Каянча (Онгудай, 12:00, 3 м/с) через края окон: выборка игры (`AirFieldSet`) и каждый уровень отдельно, на 50 и 300 м над землёй. Вход — CSV GPU-теста.
- `out/seam_kayancha_h12_U3.csv`, `out/seam_kayancha_h12_U3.png` — данные и рисунок.

**Данные.** `tools/research/air_clipmap/out/`. Выводов в каталоге нет — описание клипмапов в `docs/guide/air-model.md`, контракт C7 — `docs/contracts/air-model.md`.
