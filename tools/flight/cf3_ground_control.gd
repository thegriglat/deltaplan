extends Node
## CF-3: замеры управления крылом на земле (вариант В) через всю цепочку ввода:
## Input (действия InputMap / смещение мыши) → InputController → ControlInput → FlightModel/GroundRun.
## Склон 0,3 (~17°) вниз по курсу, ветер постоянный встречный (аналитическое поле), штиль = 0.
##
## Запуск (без окна):
##   XDG_DATA_HOME=$(mktemp -d) godot --headless --path . res://tools/flight/cf3_ground_control.tscn
## Печатает таблицы пунктов приёмки 1–4 (docs/plan/control-fix.md, CF-3); итог в отчёте CF-3.

const DT := 1.0 / 120.0
const SLOPE := 0.3
const BAR_ACTIONS := [
	"run", "pitch_pull_in", "pitch_push_out", "roll_left", "roll_right",
	"walk_forward", "walk_back", "turn_left", "turn_right"
]

var ic: InputController


static func slope(_x: float, z: float) -> float:
	return 1000.0 + SLOPE * z


func _ready() -> void:
	ic = InputController.new()
	add_child(ic)
	ic.reload_config()
	_standing()
	_running()
	_liftoff()
	_launch_table()
	get_tree().quit()


func _model(w: String) -> FlightModel:
	var wing: Dictionary = Config.get_config("wings/" + w)
	var pilot: Dictionary = Config.get_config("pilot").duplicate(true)
	pilot.mass_kg = float(wing.pilot_mass_ref_kg)
	var m := FlightModel.new()
	m.setup(wing, pilot, {"air_density": {"altitude_dependent": false}})
	m.reset_on_ground(Vector3.ZERO, 0.0)
	return m


func _release_all() -> void:
	for a: String in BAR_ACTIONS:
		Input.action_release(a)


func _reset(m: FlightModel) -> void:
	_release_all()
	ic.reset()
	m.reset_on_ground(Vector3.ZERO, 0.0)
	m._ground.reset()


## Шагать seconds с действиями actions зажатыми и смещением мыши mouse (доли хода).
func _hold(m: FlightModel, wind: float, seconds: float, actions: Array, mouse := Vector2.ZERO) -> Dictionary:
	var af := func(_p: Vector3) -> Vector3: return Vector3(0, 0, wind)
	for a: String in actions:
		Input.action_press(a)
	ic._mouse_offset = mouse
	var res := {"max_a": 0.0, "turned": 0.0, "dp": 0.0, "dr": 0.0, "took_off": false, "t": 0.0}
	var h_prev := m.heading
	var t := 0.0
	var p_prev := ic.control.pitch
	var r_prev := ic.control.roll
	while t < seconds:
		ic.on_ground = m.mode != FlightModel.Mode.AIR
		var c := ic.update(DT)
		m.step(DT, c, af, slope)
		t += DT
		var dh := wrapf(m.heading - h_prev, -PI, PI)
		h_prev = m.heading
		res.turned += dh
		var v := Vector2(m.velocity.x, m.velocity.z).length()
		if m.mode == FlightModel.Mode.GROUND:
			res.max_a = maxf(res.max_a, v * absf(dh) / DT)
		if m.mode == FlightModel.Mode.AIR and not res.took_off:
			res.took_off = true
			res.t = t
			# первый воздушный шаг ввода: on_ground = false
			ic.on_ground = false
			var c2 := ic.update(DT)
			res.dp = absf(c2.pitch - c.pitch)
			res.dr = absf(c2.roll - c.roll)
			res.dp_prev = absf(c.pitch - p_prev)
			res.dr_prev = absf(c.roll - r_prev)
			break
		if m.mode == FlightModel.Mode.FAILED:
			break
		p_prev = c.pitch
		r_prev = c.roll
	for a: String in actions:
		Input.action_release(a)
	return res


func _state(m: FlightModel) -> String:
	var gr: GroundRun = m._ground
	return (
		"pitch %+.2f roll %+.2f | α %5.1f° крен %+5.1f° курс %+6.1f° N/W %.2f %s%s"
		% [
			ic.control.pitch, ic.control.roll, rad_to_deg(m.alpha), m.telemetry.bank_deg,
			wrapf(m.telemetry.heading_deg + 180.0, 0.0, 360.0) - 180.0, gr.feet_load, m.phase(),
			("/" + m.takeoff_failure) if m.mode == FlightModel.Mode.FAILED else ""
		]
	)


## П. 1: стоя — нос (клавиши, мышь) на полный ход, крен к заданному, W/S шаг, A/D поворот.
func _standing() -> void:
	print("\n== 1. Стоя (склон 17°, постоянный встречный ветер) ==")
	var phi := float(Config.get_config("flight").ground_bank.command_max_deg)
	for w in ["slavutich_ut", "sport"]:
		for wind in [0.0, 6.0]:
			var m := _model(w)
			var cases := [
				["без ввода", [], Vector2.ZERO],
				["«от себя» (клавиша)", ["pitch_push_out"], Vector2.ZERO],
				["«на себя» (клавиша)", ["pitch_pull_in"], Vector2.ZERO],
				["мышь вверх до упора", [], Vector2(0, -1)],
				["мышь вниз до упора", [], Vector2(0, 1)],
				["крен вправо (клавиша)", ["roll_right"], Vector2.ZERO],
				["крен влево (клавиша)", ["roll_left"], Vector2.ZERO],
				["мышь вправо до упора", [], Vector2(1, 0)],
				["мышь влево полхода", [], Vector2(-0.5, 0)],
				["шаг вперёд (walk_forward)", ["walk_forward"], Vector2.ZERO],
				["поворот вправо (turn_right)", ["turn_right"], Vector2.ZERO],
			]
			for cs: Array in cases:
				_reset(m)
				var x0 := m.position
				var r := _hold(m, wind, 3.0, cs[1], cs[2])
				var moved := Vector2(m.position.x - x0.x, m.position.z - x0.z).length()
				print(
					"%-13s %4.1f м/с  %-28s %s  сдвиг %.2f м  поворот %+.0f°  (заданный крен ±%.0f°)"
					% [w, wind, cs[0], _state(m), moved, rad_to_deg(r.turned), phi]
				)


## П. 2: на бегу — нос, крен, дуга от крена, |a| ≤ a_max; без крена — прямо.
func _running() -> void:
	print("\n== 2. На бегу (Shift), 2,5 с или до отрыва ==")
	var a_max := float(Config.value("pilot", "run.turn_accel_max_ms2"))
	for w in ["slavutich_ut", "sport"]:
		for wind in [0.0, 3.0]:
			var m := _model(w)
			var cases := [
				["без ввода", [], Vector2.ZERO],
				["«на себя» (клавиша)", ["pitch_pull_in"], Vector2.ZERO],
				["«от себя» (клавиша)", ["pitch_push_out"], Vector2.ZERO],
				["мышь на себя полхода", [], Vector2(0, 0.5)],
				["крен вправо (клавиша)", ["roll_right"], Vector2.ZERO],
				["крен влево (клавиша)", ["roll_left"], Vector2.ZERO],
				["мышь вправо полхода", [], Vector2(0.5, 0)],
			]
			for cs: Array in cases:
				_reset(m)
				var r := _hold(m, wind, 2.5, ["run"] + cs[1], cs[2])
				print(
					"%-13s %4.1f м/с  %-24s %s  поворот %+6.1f°  max|a| %.2f (≤ %.1f) м/с²%s"
					% [w, wind, cs[0], _state(m), rad_to_deg(r.turned), r.max_a, a_max,
						("  отрыв %.2f с" % r.t) if r.took_off else ""]
				)


## П. 3: отрыв — скачок трапеции за шаг (клавиши зажаты, мышь отклонена).
func _liftoff() -> void:
	print("\n== 3. Отрыв: |Δpitch|, |Δroll| за шаг отрыва (и за шаг до него) ==")
	for w in ["slavutich_ut", "sport"]:
		for cs: Array in [
			["Shift", [], Vector2.ZERO],
			["Shift + крен вправо", ["roll_right"], Vector2.ZERO],
			["Shift + «от себя»", ["pitch_push_out"], Vector2.ZERO],
			["Shift + мышь (0,3; −0,2)", [], Vector2(0.3, -0.2)],
		]:
			var m := _model(w)
			_reset(m)
			var r := _hold(m, 6.0, 12.0, ["run"] + cs[1], cs[2])
			print(
				"%-13s 6 м/с  %-26s отрыв %s %.2f с  Δpitch %.4f  Δroll %.4f  (шаг до: %.4f / %.4f)"
				% [w, cs[0], r.took_off, r.t, r.dp, r.dr, r.get("dp_prev", 0.0), r.get("dr_prev", 0.0)]
			)


## П. 4: разбег 0/3/6/10 м/с × крыло — «без ввода» (только Shift) и «нос по α» (разумный нос:
## в штиль и слабый ветер — на min(3°, запас до срыва − 1,5°) выше нейтрали разбега, в ветер
## ≥ 3,5 м/с — на 2° ниже; срыв — нос вниз). Shift держится, пока ступни не выше
## takeoff.upright_clear_m (пилот в подвеске). Отдельно — штиль на высоком старте (ρ по высоте).
## Ветер — вдоль склона (вверх по склону, как обтекание рельефа). Порогов по времени нет:
## предел прогона 30 с — только у самого замера.
const LAUNCH_WINGS := [
	"slavutich_ut", "training", "sport", "condor_crex3", "dp_she1", "icaro_piuma", "atlas"
]
const HIGH_START_M := 1869.0


func _launch_table() -> void:
	print("\n== 4. Разбег: исход, отрыв (длина, время), ступни выше 1 м (длина, время) ==")
	print("крыло | старт | ветер | ввод | исход | отрыв: м / с | в подвеске: м / с | α отрыва | α срыва")
	for w: String in LAUNCH_WINGS:
		var cases := []
		for wind in [0.0, 3.0, 6.0, 10.0]:
			cases.append([1000.0, wind])
		cases.append([HIGH_START_M, 0.0])
		for cs: Array in cases:
			for policy in ["без ввода", "нос по α"]:
				var r := _launch(w, float(cs[0]), float(cs[1]), policy)
				print(
					"%s | %s | %.0f | %s | %s | %s | %s | %.1f° | %.1f°"
					% [w, "%.0f м" % cs[0], cs[1], policy, r.out, r.lift, r.clear, r.alpha, r.stall]
				)


func _launch(w: String, base_m: float, wind: float, policy: String) -> Dictionary:
	var wing: Dictionary = Config.get_config("wings/" + w)
	var pilot: Dictionary = Config.get_config("pilot").duplicate(true)
	pilot.mass_kg = float(wing.pilot_mass_ref_kg)
	var m := FlightModel.new()
	var high := base_m > 1000.0
	m.setup(wing, pilot, {"air_density": {"altitude_dependent": high}})
	var gf := func(_x: float, z: float) -> float: return base_m + SLOPE * z
	# ветер вдоль склона (обтекание рельефа): встречный по горизонтали w·cosθ и вверх по склону
	# w·sinθ — у горизонтального ветра над склоном нет склонового подъёма
	var th := atan(SLOPE)
	var af := func(_p: Vector3) -> Vector3: return Vector3(0, wind * sin(th), wind * cos(th))
	_release_all()
	ic.reset()
	m.reset_on_ground(Vector3(0, base_m, 0), 0.0)
	var neutral := float(wing.launch.alpha_neutral_deg)
	var margin := rad_to_deg(m.alpha_stall) - neutral
	var target := neutral - 2.0 if wind >= 3.5 else neutral + minf(3.0, margin - 1.5)
	var clear_h := float(m.flight.takeoff.upright_clear_m)
	var res := {"out": "не взлетел", "lift": "—", "clear": "—", "alpha": 0.0, "stall": rad_to_deg(m.alpha_stall)}
	var t := 0.0
	var x0 := m.position
	var lifted := false
	while t < 30.0:
		var agl: float = m.position.y - gf.call(m.position.x, m.position.z)
		_press("run", agl <= clear_h)
		if policy == "нос по α" and m.telemetry.airspeed > 1.0 and m.mode == FlightModel.Mode.GROUND:
			var a := rad_to_deg(m.alpha)
			var dn := -1 if (m.stalled or a > target + 1.0) else (1 if a < target - 1.0 else 0)
			_press("pitch_pull_in", dn < 0)
			_press("pitch_push_out", dn > 0)
		ic.on_ground = m.mode != FlightModel.Mode.AIR
		m.step(DT, ic.update(DT), af, gf)
		t += DT
		var d := Vector2(m.position.x - x0.x, m.position.z - x0.z).length()
		if m.mode == FlightModel.Mode.AIR and not lifted:
			lifted = true
			res.lift = "%.1f / %.2f" % [d, t]
			res.alpha = rad_to_deg(m.alpha)
		if m.mode == FlightModel.Mode.AIR and agl > clear_h:
			res.clear = "%.1f / %.2f" % [d, t]
			res.out = "взлёт"
			break
		if m.mode == FlightModel.Mode.FAILED:
			res.out = "срыв: " + m.takeoff_failure
			break
		if m.mode == FlightModel.Mode.LANDED:
			res.out = "сел обратно"
			break
	_release_all()
	return res


func _press(a: String, on: bool) -> void:
	if on:
		Input.action_press(a)
	else:
		Input.action_release(a)
