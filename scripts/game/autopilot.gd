class_name Autopilot
extends RefCounted
## Синтетический пилот для тестов, smoke-режима и скриншотов (--autopilot):
## жмёт те же действия InputMap, что и клавиатура (Input.action_press), поэтому проверяет
## всю цепочку ввод → InputController → планер. Не для игрока.
## Сценарий: стоит, пока не замерит ветер в лицо (шаг телеметрии стоя), → разбег (Shift) → после отрыва держит Shift ещё hold_after_takeoff_s
## → держит курс.
## Техника разбега (docs/guide/flight.md): трапеция — те же действия, что в полёте (С2 v2): нос крыла
## держит по углу атаки киля — в слабый ветер calm_alpha_deg, в сильный (≥ strong_wind_ms, замер
## стоя) — strong_alpha_deg; крыло «обмякло» (срыв на разбеге) — сразу опускает нос. Крен на
## разбеге — ровно (крен руки к горизонту), курс — прямо.

const ACTIONS: Array[String] = [
	"run",
	"pitch_pull_in",
	"pitch_push_out",
	"roll_left",
	"roll_right",
]

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

## Сколько секунд после отрыва не отпускать Shift, с.
var hold_after_takeoff_s: float = 0.0
## Ветер в лицо стоя (воздушная скорость), с которого разбег — с опущенным носом, м/с.
var strong_wind_ms: float = 3.5
## Угол атаки киля на разбеге в слабый ветер, °: ближе к срыву (нужна большая Cy на малой
## скорости), но ниже срыва самых «тупых» крыльев (≈ 21°).
var calm_alpha_deg: float = 19.5
## Угол атаки киля на разбеге в сильный ветер, ° (нейтраль носа ~22–23° — у самого срыва).
var strong_alpha_deg: float = 18.0
## Мёртвая зона по углу атаки, °.
var alpha_tol_deg: float = 1.0
## Через столько секунд после отрыва — кружить с креном circle_bank_deg (< 0 — держать курс):
## кадры «оглянуться на старт» (--autopilot-circle), пилот остаётся недалеко от склона.
var circle_after_s: float = -1.0
## Крен кружения, ° (+ вправо).
var circle_bank_deg: float = 15.0

## Ждать (сеть, NET-43: не первый в очереди на старт или идёт к своему месту): ничего не жать,
## замер ветра стоя — заново, когда ожидание кончится.
var hold := false

var _time: float = 0.0
var _air_time: float = 0.0
var _heading: float = -1.0
var _prev_bank: float = 0.0
var _bank_rate: float = 0.0
var _wind_ms: float = 0.0
var _wind_seen := false  ## стоя уже замерил ветер в лицо — можно бежать


func reset() -> void:
	_time = 0.0
	_air_time = 0.0
	_wind_ms = 0.0
	_wind_seen = false
	_prev_bank = 0.0
	_bank_rate = 0.0
	_heading = hold_heading_deg
	release_all()


## Вызывать каждый шаг физики ДО InputController.update().
func drive(t: Telemetry, dt: float) -> void:
	if hold and t.phase in ["standing", "walking"]:
		release_all()
		_time = 0.0
		_wind_seen = false
		return
	_time += dt
	if dt > 0.0:
		_bank_rate = lerpf(_bank_rate, (t.bank_deg - _prev_bank) / dt, 0.2)
	_prev_bank = t.bank_deg
	var hold_w := false
	var nose := 0
	match t.phase:
		"standing", "walking", "running":
			hold_w = _wind_seen
			if t.phase == "standing":
				_wind_ms = maxf(_wind_ms, t.airspeed)
				_wind_seen = true
			nose = _nose_dir(t)
			_level_roll(t.bank_deg, 0.0)
		"flying":
			_air_time += dt
			# пока ступни не выше takeoff.upright_clear_m, пилот ещё на ногах — бежит дальше
			var clear := float(Config.value("flight", "takeoff.upright_clear_m", 1.0))
			hold_w = t.altitude_agl < clear or _air_time < hold_after_takeoff_s
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
	_press("run", hold_w)
	# на земле — нос по углу атаки, в полёте — трапеция в триме (клавиши отпущены)
	_press("pitch_pull_in", nose < 0)
	_press("pitch_push_out", nose > 0)


func release_all() -> void:
	for a in ACTIONS:
		if InputMap.has_action(a):
			Input.action_release(a)


## Нос на разбеге: −1 — опустить (на себя), +1 — поднять (от себя), 0 — отпустить (трапеция
## сама возвращается к нейтрали). Стоя — не трогает.
func _nose_dir(t: Telemetry) -> int:
	if t.phase != "running":
		return 0
	if t.stalled:
		return -1
	if t.airspeed < 1.0:
		return 0
	var target := strong_alpha_deg if _wind_ms >= strong_wind_ms else calm_alpha_deg
	# Угол атаки киля: тангаж минус угол набегающего потока.
	var flow := rad_to_deg(asin(clampf(t.air_velocity.y / t.airspeed, -1.0, 1.0)))
	var alpha := t.pitch_deg - flow
	if alpha > target + alpha_tol_deg:
		return -1
	if alpha < target - alpha_tol_deg:
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
