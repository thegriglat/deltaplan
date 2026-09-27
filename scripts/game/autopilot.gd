class_name Autopilot
extends RefCounted
## Синтетический пилот для тестов, smoke-режима и скриншотов (--autopilot):
## жмёт те же действия InputMap, что и клавиатура (Input.action_press), поэтому проверяет
## всю цепочку ввод → InputController → планер. Не для игрока.
## Сценарий: стоит stand_s → разбег (Shift) → в полёте держит курс старта, крыло ровно.

const ACTIONS: Array[String] = ["run", "pitch_pull_in", "pitch_push_out", "roll_left", "roll_right"]

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

var _time: float = 0.0
var _heading: float = -1.0
var _prev_bank: float = 0.0
var _bank_rate: float = 0.0


func reset() -> void:
	_time = 0.0
	_heading = hold_heading_deg
	release_all()


## Вызывать каждый шаг физики ДО InputController.update().
func drive(t: Telemetry, dt: float) -> void:
	_time += dt
	if dt > 0.0:
		_bank_rate = lerpf(_bank_rate, (t.bank_deg - _prev_bank) / dt, 0.2)
	_prev_bank = t.bank_deg
	_press("run", false)
	_press("pitch_pull_in", false)
	_press("pitch_push_out", false)
	match t.phase:
		"standing", "walking", "running":
			_press("run", _time >= stand_s)
			_level_roll(t.bank_deg, 0.0)
		"flying":
			if _heading < 0.0:
				_heading = t.heading_deg
			var err := wrapf(_heading - t.heading_deg, -180.0, 180.0)
			var want := clampf(err * bank_per_deg, -max_bank_deg, max_bank_deg)
			_level_roll(t.bank_deg, want)
		_:
			_press("roll_left", false)
			_press("roll_right", false)


func release_all() -> void:
	for a in ACTIONS:
		if InputMap.has_action(a):
			Input.action_release(a)


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
