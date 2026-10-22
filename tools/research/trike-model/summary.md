---
type: "research"
status: "active"
module: "trike-model"
area: "game"
updated: "2026-10-22"
summary: "TK-1: краткий итог размеров трайка и точки глаз"
related: ["docs/plan/trike-model.md", "docs/contracts/trike-model.md"]
conclusion: "Размеры Airborne XT912/Tanarg, глаза сидячей позы (0, 0.352, -1.144) от подвески, seat по замеру; Δ с реальной посадкой < 0.3 м"
data: "tools/research/trike-model/"
applied_in: "tools/blender/trike_params.json"
---

# TK-1: итог
- `tools/blender/trike_params.json` создан по TK-K1: прототип Airborne XT912 (+ Tanarg), 4+ источника (Airborne, BMAA HADS, DULV, Wikipedia).
- Глаза «Сидячей позы» относительно подвески (Blender, м): training (0, 0.352, -1.144), apogee (0, 0.390, -1.122) (x принят 0, измерено -0.06/-0.09 от крена).
- seat: hip (0, 0.409, -1.856), подушка на 0.544 м над землёй, спинка 15 град, подошвы (+-0.15, 1.174, -2.231).
- Расхождение с реальной посадкой: Δz < 0.04 м, Δy -0.25...+0.05 м, Δx 0 — меньше 0.3 м.
- Не найдено: ширина шин, высота двигателя, ось винта, направление вращения (оценки в src).

# TK-6: итог (модель v2)
- Кадры: 4 без пилота, 5 с пилотом и 3 крупных посадки (PNG, `build/screenshots/trike-model`), Cycles/CUDA ~1 мин; видео не делалось.
- Посадка после TK-9 (`fit.json`, см): проникание max 1.15, седалище 0.58, спинка 0.06, подножки 2.00/2.53, глаза 0.05, бёдра 1.31 — все критерии проходят.
