# Журнал: проверка физики и параметров крыльев (wing-physics-check)

План — `docs/plan/wing-physics-check.md`, контракты — `docs/wing-physics-check_contracts.md` (К1–К6 v1, тест `tests/contracts/test_wing_physics_contracts.gd`, 5/5 ok). Ветка `feature/wing-physics-check`, копия `~/deltaplan-wing-physics-check` (от main 3820bda).

## Задачи
| Задача | Статус | Исполнитель | Копия / ветка | Коммиты | Ключевые числа |
|---|---|---|---|---|---|
| WPC-1 паспорта против модели | в работе (01.10) | dp-researcher | `~/deltaplan-wing-physics-check-wpc1` / `wing-physics-check/wpc1` | | |
| WPC-2 ветер у склона | в работе (01.10) | dp-researcher | `~/deltaplan-wing-physics-check-wpc2` / `wing-physics-check/wpc2` | | |
| WPC-3 пачка полётов | в работе (01.10) | dp-engineer | `~/deltaplan-wing-physics-check-wpc3` / `wing-physics-check/wpc3` | | |

## Решения и события
- 01.10 — модуль заведён по отзыву пилота (1.0.0: «6 м/с — сдувает, 3 м/с — не набрать»). Контракты К1–К3 зафиксированы по коду main, К4–К6 — форматы данных волны 1. Первичный осмотр: параметры крыльев по порядку величины реальны (трим 28,5–38,8 км/ч, «на себя» 55–101 км/ч); подозрение — профиль ветра над гребнем (U10 меню + степенной профиль α 0,24 над местной землёй + множитель высоты) и/или поле воздуха на GPU. Параллельно работает `feature/control-fix` (ввод/старт) — его зону не трогаем.
