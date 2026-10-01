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


## П. 4: разбег 0/3/6/10 м/с × крыло — «разумный ввод»: Shift, нос по углу атаки киля (как
## автопилот: штиль — 19,5°, ветер ≥ 3,5 м/с — 18°, срыв — нос вниз), и без ввода носа.
func _launch_table() -> void:
	print("\n== 4. Разбег: исход, длина, время ==")
	print("крыло | ветер | ввод | исход | длина, м | время, с | α отрыва")
	for w in ["slavutich_ut", "training", "sport"]:
		for wind in [0.0, 3.0, 6.0, 10.0]:
			for policy in ["нос по α", "без ввода"]:
				var m := _model(w)
				_reset(m)
				var af := func(_p: Vector3) -> Vector3: return Vector3(0, 0, wind)
				var target := 18.0 if wind >= 3.5 else 19.5
				var t := 0.0
				var out := "нет"
				var x0 := m.position
				Input.action_press("run")
				while t < 15.0:
					if policy == "нос по α" and m.telemetry.airspeed > 1.0:
						var a := rad_to_deg(m.alpha)
						var dn := -1 if (m.stalled or a > target + 1.0) else (1 if a < target - 1.0 else 0)
						_press("pitch_pull_in", dn < 0)
						_press("pitch_push_out", dn > 0)
					ic.on_ground = true
					m.step(DT, ic.update(DT), af, slope)
					t += DT
					if m.mode == FlightModel.Mode.AIR:
						out = "взлёт"
						break
					if m.mode == FlightModel.Mode.FAILED:
						out = "срыв: " + m.takeoff_failure
						break
				_release_all()
				var run_len := Vector2(m.position.x - x0.x, m.position.z - x0.z).length()
				print(
					"%s | %.0f | %s | %s | %.1f | %.2f | %.1f°"
					% [w, wind, policy, out, run_len, t, rad_to_deg(m.alpha)]
				)


func _press(a: String, on: bool) -> void:
	if on:
		Input.action_press(a)
	else:
		Input.action_release(a)
