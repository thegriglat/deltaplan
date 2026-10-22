class_name Autopilot
extends RefCounted
## Синтетический пилот для тестов, smoke-режима и скриншотов (--autopilot):
## бег — действием run (Input.action_press, как Shift); тангаж и крен трапеции — в ControlInput напрямую
## (pitch_command, roll_command → InputController._apply_autopilot): клавиш трапеции нет (У1 v5). Не для игрока.
## Сценарий: стоит, пока не замерит ветер в лицо (шаг телеметрии стоя), → разбег (Shift) → после отрыва держит Shift ещё hold_after_takeoff_s
## → держит курс.
## Техника разбега (docs/guide/flight.md): трапеция — та же, что в полёте (С2 v4): нос крыла
## держит по углу атаки киля — в слабый ветер calm_alpha_deg, в сильный (≥ strong_wind_ms, замер
## стоя) — strong_alpha_deg; крыло «обмякло» (срыв на разбеге) — сразу опускает нос. Крен на
## разбеге — ровно (крен руки к горизонту), курс — прямо.

const ACTIONS: Array[String] = [
	"run",
	"walk_forward",
]
## Ход ручки автопилота, доля полного в секунду: к цели и к нейтрали (прежний клавиатурный ход, У1 v4:
## тангаж 1,5/1,0) — поведение автопилота не меняется.
const PITCH_RATE := 1.5
const PITCH_RETURN := 1.0

## Курс, который держать в полёте (−1 — курс в момент отрыва).
var hold_heading_deg: float = -1.0
## Предельный крен при доворотах, °.
var max_bank_deg: float = 15.0
## Крен на 1° ошибки курса.
var bank_per_deg: float = 0.5

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

## Положение пилота поперёк, −1…1 (+ вправо): выход ПИД крена (игрок на «Маятнике», R7).
var roll_command := 0.0
## Тангаж трапеции −1…1 (ControlInput.pitch): нос крыла на разбеге, в полёте — трим (0).
var pitch_command := 0.0
## Коэффициенты ПИД крена (как BankHold прототипа): на рад ошибки, на рад/с, на рад·с.
var pid_kp := 1.5
var pid_kd := 0.8
var pid_ki := 0.3

## Удержание воздушной скорости в полёте (SpeedHold, буксировка), м/с; ≤ 0 — выключено (трапеция в триме).
## Только режим pendulum: тангаж трапеции в этом режиме — ввод ControlInput.pitch.
var hold_airspeed_ms := 0.0
var speed_hold := SpeedHold.new()

## Ждать (сеть, NET-43: не первый в очереди на старт или идёт к своему месту): ничего не жать,
## замер ветра стоя — заново, когда ожидание кончится.
var hold := false

## Старт с лебёдки (TW-К7): трос запускает W (walk_forward), Shift его не запускает (TW-10) — вместо бега
## жмёт W, пока стоит на земле; после отрыва W отпущен. Нос на земле не трогает (тянет трос).
var tow_start := false

var _time: float = 0.0
var _air_time: float = 0.0
var _heading: float = -1.0
var _prev_bank: float = 0.0
var _prev_basis := Basis.IDENTITY
var _bank_rate: float = 0.0
var _wind_ms: float = 0.0
var _pid_i := 0.0
var _dt := 0.0
var _wind_seen := false  ## стоя уже замерил ветер в лицо — можно бежать


func reset() -> void:
	_time = 0.0
	_air_time = 0.0
	_wind_ms = 0.0
	_wind_seen = false
	_prev_bank = 0.0
	_prev_basis = Basis.IDENTITY
	_bank_rate = 0.0
	_pid_i = 0.0
	speed_hold.reset()
	roll_command = 0.0
	pitch_command = 0.0
	_heading = hold_heading_deg
	release_all()


## Вызывать каждый шаг физики ДО InputController.update().
func drive(t: Telemetry, dt: float) -> void:
	if hold and t.phase in ["standing", "walking"]:
		release_all()
		pitch_command = 0.0
		roll_command = 0.0
		_time = 0.0
		_wind_seen = false
		return
	_time += dt
	_dt = dt
	if dt > 0.0:
		# скорость крена — угловая скорость корпуса вокруг оси вперёд (из поворота basis за шаг), как
		# BankHold на модели: производная угла крена и фильтр lerp 0,2 отставали на ~4 шага и
		# врали на 30 % (угол крена ≠ проекция угловой скорости), а sport в болтанке на границе
		# устойчивости ПИД
		var dr := _prev_basis.orthonormalized().inverse() * t.basis.orthonormalized()
		# поворот вокруг оси Z basis (вперёд = −Z) — антисимметричная часть dr (малый угол точнее кватерниона)
		var rz := (dr.x.y - dr.y.x) * 0.5
		_bank_rate = rad_to_deg(-rz / dt) if _time > 1.5 * dt else 0.0  # первый шаг: prev ещё нет
	_prev_basis = t.basis
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
			_pid_roll(t.bank_deg, 0.0)
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
			_pid_roll(t.bank_deg, want)
		_:
			roll_command = 0.0
	if tow_start:
		var on_ground: bool = t.phase in ["standing", "walking", "running"] and _wind_seen
		_press("run", hold_w)
		_press("walk_forward", on_ground)
	else:
		_press("run", hold_w)
	# на земле — нос по углу атаки, в полёте — трапеция в триме (ручка к нейтрали)
	if hold_airspeed_ms > 0.0 and pendulum and t.phase == "flying":
		speed_hold.target_ms = hold_airspeed_ms
		pitch_command = move_toward(pitch_command, speed_hold.update(t, dt), PITCH_RATE * dt)
	else:
		speed_hold.reset()
		pitch_command = _ramp(pitch_command, float(nose), PITCH_RATE, PITCH_RETURN, dt)


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


## ПИД крена: цель want, °; bank, ° — крен; скорость крена — фильтрованная (_bank_rate).
func _pid_roll(bank: float, want: float) -> void:
	var e := deg_to_rad(want - bank)
	_pid_i = clampf(_pid_i + pid_ki * e * _dt, -1.0, 1.0)
	roll_command = clampf(pid_kp * e - pid_kd * deg_to_rad(_bank_rate) + _pid_i, -1.0, 1.0)


func _press(action: String, on: bool) -> void:
	if not InputMap.has_action(action):
		return
	if on:
		Input.action_press(action)
	else:
		Input.action_release(action)


static func _ramp(v: float, dir: float, rate: float, ret: float, dt: float) -> float:
	if dir != 0.0:
		return move_toward(v, signf(dir), rate * dt)
	return move_toward(v, 0.0, ret * dt)
