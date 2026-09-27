class_name Autopilot
extends RefCounted
## Синтетический пилот для тестов, smoke-режима и скриншотов (--autopilot):
## жмёт те же действия InputMap, что и клавиатура (Input.action_press), поэтому проверяет
## всю цепочку ввод → InputController → планер. Не для игрока.
## Сценарий: стоит stand_s → разбег (W+Shift, как клавиатура: W = walk_forward + pitch_pull_in)
## → после отрыва держит W+Shift ещё hold_after_takeoff_s (проверка защёлки) → держит курс.
## Техника разбега (docs/flight.md): стоя, пилот чувствует ветер в лицо; в сильный ветер
## (≥ strong_wind_ms) разбегается с носом ниже — держит угол атаки не выше strong_alpha_deg
## стрелками ↑/↓. Крыло «обмякло» (срыв на разбеге) — сразу опускает нос.

const ACTIONS: Array[String] = [
	"run",
	"walk_forward",
	"pitch_pull_in",
	"pitch_push_out",
	"roll_left",
	"roll_right",
	"nose_up",
	"nose_down",
]

## Сколько стоять перед разбегом, с.
var stand_s: float = 0.5
## Курс, который держать в полёте (−1 — курс в момент отрыва).
var hold_heading_deg: float = -1.0
## Предельный крен при доворотах, °.
var max_bank_deg: float = 15.0
## Крен на 1° ошибки курса.
var bank_per_deg: float = 0.5
## Мёртвая зона по крену, °.
var bank_tol_deg: float = 2.0
## Упреждение по скорости крена, с (крыло доворачивает с запаздыванием).
var lead_s: float = 0.8

## Сколько секунд после отрыва не отпускать W+Shift (проверка защёлки клавиш), с.
var hold_after_takeoff_s: float = 0.0
## Ветер в лицо стоя (воздушная скорость), с которого разбег — с опущенным носом, м/с.
var strong_wind_ms: float = 3.5
## Угол атаки киля на разбеге в сильный ветер, ° (нейтраль носа ~22–23° — у самого срыва).
var strong_alpha_deg: float = 18.0
## Мёртвая зона по углу атаки, °.
var alpha_tol_deg: float = 1.0
## Через столько секунд после отрыва — кружить с креном circle_bank_deg (< 0 — держать курс):
## кадры «оглянуться на старт» (--autopilot-circle), пилот остаётся недалеко от склона.
var circle_after_s: float = -1.0
## Крен кружения, ° (+ вправо).
var circle_bank_deg: float = 15.0

var _time: float = 0.0
var _air_time: float = 0.0
var _heading: float = -1.0
var _prev_bank: float = 0.0
var _bank_rate: float = 0.0
var _wind_ms: float = 0.0


func reset() -> void:
	_time = 0.0
	_air_time = 0.0
	_wind_ms = 0.0
	_prev_bank = 0.0
	_bank_rate = 0.0
	_heading = hold_heading_deg
	release_all()


## Вызывать каждый шаг физики ДО InputController.update().
func drive(t: Telemetry, dt: float) -> void:
	_time += dt
	if dt > 0.0:
		_bank_rate = lerpf(_bank_rate, (t.bank_deg - _prev_bank) / dt, 0.2)
	_prev_bank = t.bank_deg
	_press("pitch_push_out", false)
	var hold_w := false
	var nose := 0
	match t.phase:
		"standing", "walking", "running":
			hold_w = _time >= stand_s
			if t.phase == "standing":
				_wind_ms = maxf(_wind_ms, t.airspeed)
			nose = _nose_dir(t)
			_level_roll(t.bank_deg, 0.0)
		"flying":
			_air_time += dt
			hold_w = _air_time < hold_after_takeoff_s
			if _heading < 0.0:
				_heading = t.heading_deg
			var err := wrapf(_heading - t.heading_deg, -180.0, 180.0)
			var want := clampf(err * bank_per_deg, -max_bank_deg, max_bank_deg)
			if circle_after_s >= 0.0 and _air_time >= circle_after_s:
				want = circle_bank_deg
			_level_roll(t.bank_deg, want)
		_:
			_press("roll_left", false)
			_press("roll_right", false)
	_press("walk_forward", hold_w)
	_press("pitch_pull_in", hold_w)
	_press("run", hold_w)
	_press("nose_down", nose < 0)
	_press("nose_up", nose > 0)


func release_all() -> void:
	for a in ACTIONS:
		if InputMap.has_action(a):
			Input.action_release(a)


## Подстройка носа на земле: −1 — опустить, +1 — поднять (не выше нейтрали), 0 — держать.
func _nose_dir(t: Telemetry) -> int:
	if t.stalled:
		return -1
	if _wind_ms < strong_wind_ms or t.airspeed < 1.0:
		return 0
	# Угол атаки киля: тангаж минус угол набегающего потока.
	var flow := rad_to_deg(asin(clampf(t.air_velocity.y / t.airspeed, -1.0, 1.0)))
	var alpha := t.pitch_deg - flow
	if alpha > strong_alpha_deg + alpha_tol_deg:
		return -1
	if alpha < strong_alpha_deg - alpha_tol_deg:
		return 1
	return 0


func _level_roll(bank: float, want: float) -> void:
	bank += _bank_rate * lead_s
	_press("roll_right", bank < want - bank_tol_deg)
	_press("roll_left", bank > want + bank_tol_deg)


func _press(action: String, on: bool) -> void:
	if not InputMap.has_action(action):
		return
	if on:
		Input.action_press(action)
	else:
		Input.action_release(action)
