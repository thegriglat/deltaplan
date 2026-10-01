# Журнал модуля «ускорение расчёта ветра» (air-speed)

План — `docs/plan/air-speed.md`; контракты — `docs/air_speed_contracts.md` (S1 v1, S2 v1) поверх
`docs/air_model_contracts.md` (C2 v5, C7 v2, C9 v2). Ветка `feature/air-speed`, копия `~/deltaplan-air-speed` (от `main`
a554502).

## Решения
- 01.10 — модуль заведён; решения пользователя: п. 2 — загрузка одним блокирующим проходом (UI замирает после кадра
  этапа «ветер»); п. 3 — подготовка на CPU через шейдер и/или `Image`, результат в допуске; п. 1 — сначала
  исследование и шлюз. Физика и поле не меняются.
- 01.10 — контракты до исполнителей: S1 v1 (сигнатуры подготовки без изменений, рабочий поток без RD, допуски), S2 v1
  (блокирующая загрузка, `LOAD_BLOCK_MS` = INF, `AirClipmap.run_blocking`, разбивка времени в `last_info`); тест
  `tests/contracts/test_air_speed_contracts.gd` — `test_s2_blocking_api` до SP-2 падает намеренно.
- 01.10 — стык с air-start (C2 v6, C7 v3, C9 v3 в его ветке): наши изменения C7/C9 держим в `air_speed_contracts.md`,
  номера версий в `air_model_contracts.md` — при слиянии после air-start. Файлы пересекаются (`air_runtime.gd`,
  `air_clipmap.gd`, `air_place.gd`, `air_case.gd`) — сообщено главной сессии.

## Задачи
| Задача | Статус | Исполнитель | Копия / ветка | Коммиты | Числа / решения |
|---|---|---|---|---|---|
| SP-3 Подготовка без циклов GDScript | в работе (01.10) | dp-engineer | `~/deltaplan-air-speed-sp3` / `air-speed/sp3` | — | — |
| SP-2 Загрузка одним проходом | в работе (01.10) | dp-engineer | `~/deltaplan-air-speed-sp2` / `air-speed/sp2` | — | — |
| SP-1 Пересчёт в полёте: исследование | в работе (01.10) | dp-researcher | `~/deltaplan-air-speed-sp1` / `air-speed/sp1` | — | — |
