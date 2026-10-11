extends Node
## PD-39: авария «на брюхо» (8 м/с вниз + 2 м/с вперёд), оба режима, шаг 1/120 и 1/240 → out/crash.txt и stdout.
## phys_g — пик |Δpilot_velocity/Δt − g_vec| в g на шаге физики; g60 — на интервалах 1/60 с;
## t_stop_s — от касания до |pilot_velocity| < 0,01 м/с; path_m — путь pilot_position за это время;
## guard_resets — сколько интервалов 1/60 с защита MotionSource (50 g) сбросила (valid = false после первого).
## Запуск — crash.sh.

const LP := preload("res://tests/flight/landing_peaks.gd")

var _src: MotionSource
var _resets := 0
var _acc := 0.0
var _t_td := -1.0
var _t_stop := -1.0
var _p0 := Vector3.ZERO
var _path := 0.0
var _p_prev := Vector3.ZERO
var _g60 := 0.0
var _v60 := Vector3.ZERO


func _hook(m: Variant, i: int, dt: float) -> void:
	var tel: Telemetry = m.telemetry
	if i == 0:
		# состояние до первого шага: касание бывает уже на нём
		var t0 := Telemetry.new()
		t0.pilot_velocity = Vector3(0.0, -(8.0 - Units.G * dt), -2.0)
		t0.pilot_basis = tel.pilot_basis
		_src.reset()
		_src.push(t0, dt)
		_acc = 0.0
		_v60 = t0.pilot_velocity
		_p_prev = tel.pilot_position
	_src.push(tel, dt)
	_acc += dt
	if _acc >= 1.0 / 60.0 - 1.0e-9:
		var s := _src.sample()
		if i > 2 and not s.valid:
			_resets += 1
		_acc = 0.0
		_g60 = maxf(_g60, ((tel.pilot_velocity - _v60) * 60.0 + Vector3(0.0, Units.G, 0.0)).length() / Units.G)
		_v60 = tel.pilot_velocity
	if _t_td < 0.0 and m.mode != FlightModel.Mode.AIR:
		_t_td = (i + 1) * dt
		_path = 0.0
	elif _t_td >= 0.0 and _t_stop < 0.0:
		_path += (tel.pilot_position - _p_prev).length()
		if tel.pilot_velocity.length() < 0.01:
			_t_stop = (i + 1) * dt - _t_td
	_p_prev = tel.pilot_position


func _ready() -> void:
	var out := PackedStringArray()
	var total := 0
	for mode: String in ["ws", "pend"]:
		for hz: int in [120, 240]:
			_src = MotionSource.new()
			_resets = 0
			_acc = 0.0
			_t_td = -1.0
			_t_stop = -1.0
			_path = 0.0
			_g60 = 0.0
			var r := LP.run(mode, 8.0, 2.0, 2.0, "sport", 1.0 / hz, _hook)
			total += _resets
			var s := "CRASH mode=%s hz=%d phys_g=%.2f g60=%.2f grade=%s t_stop_s=%.3f path_m=%.3f guard_resets=%d nan=%s" % [
				mode, hz, r.phys_g, _g60, r.grade, _t_stop, _path, _resets, r.nan]
			print(s)
			out.append(s)
	var tail := "guard_resets_total=%d" % total
	print(tail)
	out.append(tail)
	var path := OS.get_environment("PD39_OUT")
	if path == "":
		path = ProjectSettings.globalize_path("res://tools/research/pendulum/pd39/out/crash.txt")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("\n".join(out) + "\n")
	f.close()
	get_tree().quit(0)
