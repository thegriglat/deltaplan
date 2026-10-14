---
type: "guide"
status: "active"
module: "flight"
area: "flight"
updated: "2026-10-15"
summary: "Параметры (конфиги крыла, пилота, полёта) и каталог из 48 крыльев по группам и классам ветра."
related: ["docs/guide/flight.md"]
---
# Параметры и крылья

## Параметры
- `configs/wings/<id>.json` — площадь, размах, масса крыла, диапазон и эталон массы пилота, поляра
  (точки), скорости трима/«на себя»/«от себя», наклон CL(α), крен, сваливание, разбег, визуал.
  `reference` — ориентиры поляры для тестов.
- `configs/pilot.json` — масса пилота, ходьба, разбег, визуал пилота.
- `configs/flight.json` — плотность воздуха, инерция от массы, демпфирование фугоиды, опрос
  воздуха, разбег и ошибки, крен крыла на земле, оценка посадки, визуал.

## Крылья
48 крыльев с реальными прототипами (план и источники — `docs/archive/plan/wings-lineup.md`, паспорта —
`docs/research/wings_config_sources.md`). Группы — `configs/wing_groups.json` (порядок в меню «Полёт…»: по
возрастанию качества и ветра), крыло входит в группу полем `group`; модели в группе упорядочены по
`reference.best_glide`, затем по верхнему пределу ветра класса (`WingCatalog`, `scripts/game/wing_catalog.gd`).
Состав на момент 1.5.15 (из `configs/wings/*.json`):

| Группа | Крыльев | Качество `best_glide` | Класс ветра | Примеры (id) |
|---|---|---|---|---|
| `soviet` — советские 1980-х | 3 | 6,2 … 8,4 | 1, 2 | `slavutich_ut`, `apogee` («Апогей» Мысенко), `atlas` |
| `trainer` — учебные | 11 | 7,3 … 9 | 1 | `target`, `training` (Wills Wing Falcon), `aeros_fox`, `moyes_malibu2`, `icaro_piuma`, `ww_spectrum` |
| `kingpost` — мачтовые | 19 | 10,6 … 16 | 2, 3 | `magic`, `laminar`, `ww_sport3`, `ww_u2`, `aeros_discus`, `icaro_mastr` |
| `topless` — безмачтовые | 15 | 15 … 16 | 4 | `sport` (Moyes Litespeed RS 4), `combat` (Aeros Combat GT), `ww_t3`, `ww_t2c`, `air_c4` |

Поля крыла для меню (у каждого есть `_doc`): `group`, `wind_class`, `prototype`, `era`, `kingpost`,
`double_surface_pct`. Класс ветра `wind_class` (1–4, по поперечине) задаёт подсказку «комфортный ветер на старте»
из `configs/wing_classes.json`: 1 — 7–10 м/с, 2 — 10–12, 3 — 12–15, 4 — 20–25 (со слов пилота). Это ветер меню
(на 10 м над стартом), подсказка в меню, не запрет и не параметр физики; верх слайдера ветра меню — наибольший из
пределов (`WingCatalog.wind_menu_range`). Управляемость задаётся параметрами самого крыла: «Апогей» — самый
устойчивый и лёгкий в крене, мягкое сваливание (слова пилота). Wills Wing Sport 2 убран из игры 28.09.2026.

Тесты: `tests/flight/test_wings.gd`, `tests/flight/test_wing_passports.gd`, `tests/game/test_wing_catalog.gd`,
`tests/game/test_wing_models_contract.gd`; поляра и сваливание проверяются для всех крыльев из
`Config.list_configs("wings")`.
