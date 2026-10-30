---
type: "research"
status: "active"
module: "rust-wind"
area: "air"
updated: "2026-10-30"
summary: "RW-29: smoke собранной игры явно проверяет место, dp_air api 6, ветер ≠ 0 и фазу flying по строкам журнала; smoke.gd на API 6"
conclusion: "Linux и Windows под wine: game rc=0, dp_air api_version=6, READY, строка «game: фаза flying, ветер у крыла 2.19 м/с», addons/dp_air/smoke.tscn даёт ветер у земли 3.60 м/с; tools/smoke/export_smoke.sh падает с кодом 1 при любом непройденном признаке"
data: ""
applied_in: ""
---

# RW-29 — smoke собранной игры

Что сделано:
* `addons/dp_air/smoke.gd`: ожидаемая версия API берётся из `Atmosphere.WIND_API_VERSION` (6), не дублируется; убран вызов `set_field_enabled` (удалён в API 5, поле считается всегда) — именно он ронял smoke после api_version.
* `scripts/game/game.gd`: одна строка в журнал на полёт, когда фаза `flying` и воздух готов: `game: фаза flying, ветер у крыла X м/с, t=…` (ветер — `mean_wind_at` в точке крыла).
* `tools/smoke/export_smoke.sh`: признаки проверяются явно, итог `EXPORT_SMOKE OK` / код 1: rc игры 0; `dp_air: расширение загружено, api_version=6`; `dp_air: READY`; нет `FAILED`/`SCRIPT ERROR`; строка «фаза flying» с ветром > 0,1 м/с; дымовая сцена расширения `DP_AIR_SMOKE OK`; кадр снят. Каталог результатов `build/smoke/RW-29/<os>`.

Результат (training_island, thermal_plain, `--air-start`, 20 игровых с):

| платформа | ветер у крыла | ветер у земли (smoke.tscn) | READY smoke.tscn |
|---|---|---|---|
| Linux | 2,19 м/с | 3,60 м/с (σ 1,74) | 3,6 с |
| Windows (wine) | 2,19 м/с | 3,60 м/с (σ 1,74) | 16,0 с |

## Границы

* Ветер у крыла — `mean_wind_at` на первом кадре фазы flying (t=0,0 с игровых при старте в воздухе), не динамика полёта; «ветер ≠ 0» означает > 0,1 м/с.
* Одно место, без ботов; wine — не нативная Windows.
* Строка в журнал игры добавлена для всех запусков (раз за полёт).
