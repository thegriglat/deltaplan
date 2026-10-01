# Журнал модуля «control-fix»

План — `docs/plan/control-fix.md`, контракты — `docs/control-fix_contracts.md`. Ветка `feature/control-fix`, копия `~/deltaplan-control-fix` (от `main` 3820bda = v1.0.0).

## Решения
- 01.10 — модуль заведён по жалобе пилота на 1.0.0 (сам начинает полёт, крен валится, мышь не управляет). Контракты С1 (ControlInput v1), С2 (InputController v1), С3 — ссылка на start-fixes К3 v2/К4 v1; контрактный тест `tests/game/test_control_fix_contracts.gd` (2/2 ок, весь `--filter=contracts` 34/34).
- 01.10 — две задачи параллельно: CF-1 (земля/старт, `scripts/flight/*`) и CF-2 (мышь, `input_controller.gd`/UI). Стык — `ControlInput` (С1). Противоречие с решениями пользователя start-fixes — шлюз.
- 01.10 — headless поле воздуха аналитическое (нет RenderingDevice), в игре — GPU-поле: воспроизведение CF-1 должно это учитывать (окно `tools/gpu_tests.sh`/`--air-field`).

## Задачи
| Задача | Статус | Исполнитель | Копия / ветка | Коммиты | Числа / решения |
|---|---|---|---|---|---|
| CF-1 Старт с земли | в работе (01.10) | dp-engineer | `~/deltaplan-control-fix-cf1` / `control-fix/cf1` | — | — |
| CF-2 Мышь | в работе (01.10) | dp-engineer | `~/deltaplan-control-fix-cf2` / `control-fix/cf2` | — | — |
