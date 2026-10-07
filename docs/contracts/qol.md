---
type: "contract"
status: "active"
module: "qol"
updated: "2026-10-07"
summary: "Контракты модуля qol: номер полёта и перезапуски одиночной игры (QL-К1), снимок состояния полёта для «с наивысшей точки» и сохранения (QL-К2)."
related: ["docs/plan/qol.md"]
contracts: [{"id": "QL-К1", "version": 1}, {"id": "QL-К2", "version": 1}]
---
# Контракты модуля qol

План — `docs/plan/qol.md`. Менять — только через координатора (версия +1, что изменилось, уведомить потребителей).
Контрактный тест — `tests/contracts/test_qol_contracts.gd` (headless, без сети и GPU); каждый владелец дописывает в него свой раздел.

## QL-К1. Номер полёта и перезапуски (v1)
Владелец: QL-1. Потребители: `scenes/main.gd`, QL-2 (Q-13), QL-4 (Q-14/Q-15), будущий Q-19.
- `Game.flight_no: int` — номер текущего полёта, ≥ 0, только растёт. +1 при каждом начале нового отрезка полёта:
  `start()`, `restart(...)`, `continue_on_foot()`, а также при возобновлении из снимка (QL-К2). Пауза, итог и смена камеры номер не меняют.
- Сигнал `flight_ended(kind: String, info: Dictionary)` — без изменений сигнатуры; в `info` обязателен ключ `flight_no: int`
  — номер полёта, который закончился.
- `Main` показывает итог (и кладёт его в `_pending_result`) только если `info.flight_no == game.flight_no` в момент показа;
  иначе итог отбрасывается молча.
- `Game.restart(keep_clock: bool = false)`: `false` — как сейчас («Ещё раз»: в одиночной часы и день сбрасываются на время старта);
  `true` — «На старт» без сброса `sky.clock` и `_day` (время идёт дальше). В сети поведение `restart()`/`return_to_launch()` прежнее.
- Инвариант: после `restart`/`continue_on_foot` старый полёт не может вызвать экран итога, даже если его таймер ещё идёт.

## QL-К2. Снимок полёта (v1)
Владелец: QL-2. Потребители: `scenes/main.gd`, `scripts/ui/result_screen.gd`, `scripts/ui/pause_menu.gd`, будущий Q-19 (сохранение).
- `class_name FlightSnapshot extends RefCounted` (`scripts/game/flight_snapshot.gd`). Поля (единицы — как в `FlightModel`):
  `position: Vector3` (м, мировые координаты сцены места, Y вверх — как `FlightModel.position`),
  `velocity: Vector3` (м/с, относительно земли), `heading: float` (рад, 0 — север, по часовой), `bank: float` (рад, + вправо),
  `roll_rate: float` (рад/с), `theta: float` (рад), `alpha: float` (рад), `mode: int` (`FlightModel.Mode`),
  `sim_time_s: float` (`Game.sim_time_s`), `atmo_time_s: float` (`Atmosphere.time_s`), `hour: float` (`SunClock.hour`),
  `flight_no: int` (номер полёта, из которого снимок).
- `to_dict() -> Dictionary`: JSON-совместимый: векторы — `[x, y, z]` (float), остальное — числа; ключ `"v": 1` — версия.
  `static from_dict(d: Dictionary) -> FlightSnapshot`: `null`, если нет ключа, неверный тип или `v` ≠ 1 (без падений).
- `Game.capture_snapshot() -> FlightSnapshot` — текущее состояние.
- `Game.max_alt_snapshot: FlightSnapshot` — `null`, пока в полёте не было режима AIR; обновляется, когда `position.y`
  (высота над уровнем моря) больше, чем у прежнего снимка, только в режиме AIR. Сбрасывается в `null` при `start()` и
  `restart(...)`; при возобновлении из снимка не сбрасывается.
- `Game.resume_from_snapshot(s: FlightSnapshot, keep_time: bool = true) -> void`: пилот в воздухе (`mode` AIR) с полями
  снимка; `keep_time = true` — часы и `Atmosphere.time_s` не трогаются (Q-13: время идёт дальше), `false` — `Atmosphere.start_at(s.atmo_time_s)`
  и `SunClock.set_hour(s.hour)` (для сохранения Q-19); `flight_no` +1; статистика полёта продолжается от снимка (не обнуляется).
- Инварианты: `from_dict(to_dict(s))` совпадает с `s` до 1e-6; `resume_from_snapshot(s)` и сразу `capture_snapshot()` — поля
  состояния крыла совпадают до 1e-4 (до первого шага физики); физика полёта не меняется.

## История
- v1 (07.10.2026) — заведены до первого исполнителя.
