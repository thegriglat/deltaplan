extends Node
## TKF-5 (TKF-К4): положение штанги bar_deg_phys дельталёта игрока по вводу и газу; скорость тангажа «на себя».
## Headless: godot --headless --path . res://tools/research/trike-fix/bar_stop/bar_stop_run.tscn -- [--out=<файл.json>]
##   [--pull=<м>] [--nostop] [--only=table,pull,scen]
## Расчёт bar_deg_phys - как tools/research/trike-fix/coupling_run.gd (TKF-К1): середина базовой штанги в осях C_phys
## от bar.trim; «+» к подкосу. Шаг 1/120 с, тяга по таблице tow_tug.json (T = idle + g (full - idle)).
## --pull: ход «на себя» (м), перекрывает конфиг; --nostop: убрать ключ упора из cart (сравнение «до»).

const BAR_WING := Vector3(0.0, 0.6793, -1.5287)
const BAR_TRIM := Vector2(0.72, 1.51)
const DT := 1.0 / 120.0

var _cfg: Dictionary
var _pull := -1.0
var _k := -1.0
var _c := -1.0
var _g: Glider


func _ready() -> void:
	var out := ""
	var only := ["table", "pull", "scen"]
	var nostop := false
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
		elif a.begins_with("--pull="):
			_pull = float(a.substr(7))
		elif a.begins_with("--k="):
			_k = float(a.substr(4))
		elif a.begins_with("--c="):
			_c = float(a.substr(4))
		elif a == "--nostop":
			nostop = true
		elif a.begins_with("--only="):
			only = a.substr(7).split(",")
	_cfg = Config.get_config("tow_tug").duplicate(true)
	if nostop:
		for k in _cfg.cart.keys():
			if String(k).begins_with("strut_stop"):
				_cfg.cart.erase(k)
	var res := {}
	if "table" in only:
		var t := {}
		for gas in [0.0, 1.0]:
			for p in [-1.0, 0.0, 1.0]:
				var r := _run(p, gas, 12.0)
				t["g%.0f_p%+.0f" % [gas, p]] = {"bar_end": r.bar_end, "bar_min": r.bar_min, "bar_max": r.bar_max}
		res["table"] = t
	if "pull" in only:
		var t := {}
		for gas in [0.0, 0.5, 1.0]:
			var r := _run(-1.0, gas, 20.0, 10.0)
			t["g%.1f" % gas] = r
		res["pull"] = t
	if "scen" in only:
		var t := {}
		t["push_full"] = _run(98.0, 1.0, 20.0)
		t["pitch_pump"] = _run(99.0, 1.0, 20.0)
		t["pitch_pump_idle"] = _run(99.0, 0.0, 20.0)
		res["scen"] = t
	print("BAR_STOP ", JSON.stringify(res, "\t"))
	if out != "":
		var f := FileAccess.open(out, FileAccess.WRITE)
		f.store_string(JSON.stringify(res, "\t"))
		f.close()
	get_tree().quit(0)


func _interp(xs: Array, ys: Array, x: float) -> float:
	if x <= xs[0]:
		return ys[0]
	for i in range(1, xs.size()):
		if x <= xs[i]:
			var f: float = (x - xs[i - 1]) / (xs[i] - xs[i - 1])
			return ys[i - 1] + f * (ys[i] - ys[i - 1])
	return ys[xs.size() - 1]


static func flat(_x: float, _z: float) -> float:
	return 0.0


func _thrust(v: float, gk: float) -> float:
	var th: Dictionary = _cfg.thrust
	var ti := _interp(th.v_ms, th.idle_n, v)
	return ti + gk * (_interp(th.v_ms, th.full_n, v) - ti)


static func bar_deg(rig: TrikeRig) -> float:
	var c := rig._cart_model_basis(rig.pilot_pos, rig.hang_pos, rig.wing_basis, false)
	var bw: Vector3 = c.transposed() * (rig.wing_basis * BAR_WING)
	return rad_to_deg(atan2(bw.y, -bw.z) - atan2(BAR_TRIM.x, BAR_TRIM.y))


## pitch 99 - качание ±1 с периодом 2,6 с (сценарий pitch_pump TKF-К1); pull_t > 0 - ввод с этого момента (до него 0).
## -> {bar_min, bar_max, bar_end, rate_peak_dps (0..2 с после ввода), step_jump_dps (наибольшее изменение угловой
## скорости тангажа за шаг), theta_end_deg, v_end_kmh}
func _run(pitch: float, gas: float, dur: float, settle: float = 0.0) -> Dictionary:
	if _g != null:
		_g.free()
	_g = Glider.new()
	_g.set_ground_fn(flat)
	if _k > 0.0 and _cfg.cart.has("strut_stop"):
		_cfg.cart.strut_stop.stiffness_nm_rad = _k
		_cfg.cart.strut_stop.damping_nms_rad = _c
	_g.setup_trike(_cfg, 0.0, Config.get_config("trike_pilot"))
	if _pull > 0.0:
		_g.model.arms.shift_x_pull = _pull
		_g.model.arms.shift_x_pull_full = _pull
		_g.model.arms.pull_limit = _pull
	_g.reset_in_air(Vector3(0.0, 300.0, 0.0), 0.0, 80.0 / 3.6)
	var rig := _g.trike
	rig.refresh(0.0)
	var ctl := ControlInput.new()
	var n := int(round((settle + dur) / DT))
	var bmin := INF
	var bmax := -INF
	var th: Array = []
	var w_prev := 0.0
	var jump := 0.0
	var jump_on := 0.0
	var on_prev := false
	var bar_end := 0.0
	var i_in := int(round(settle / DT))
	var t0 := 1.0 if settle <= 0.0 else settle
	for i in n:
		var t := i * DT
		if pitch > 98.5:
			ctl.pitch = 1.0 if fmod(t, 2.6) < 1.3 else -1.0
		elif pitch > 90.0:  # 98: «от себя» 10 с, потом 0 (push_full TKF-К1)
			ctl.pitch = 1.0 if t < 10.0 else 0.0
		else:
			ctl.pitch = pitch if i >= i_in else 0.0
		var v: float = _g.model.telemetry.airspeed
		rig.thrust_n = _thrust(v, gas)
		_g.model.step(DT, ctl, Callable(), Callable(flat))
		rig.refresh(DT)
		var b := bar_deg(rig)
		bar_end = b
		if t >= t0 or (settle > 0.0 and t >= settle):
			bmin = minf(bmin, b)
			bmax = maxf(bmax, b)
		var thn := rad_to_deg(asin(clampf((-_g.model.wing_basis().z).normalized().y, -1.0, 1.0)))
		th.append(thn)
		var w := (thn - float(th[th.size() - 2])) / DT if th.size() > 1 else 0.0
		var on := b > 4.9
		if i > 0 and t > 1.0:
			jump = maxf(jump, absf(w - w_prev))
			if on or on_prev:
				jump_on = maxf(jump_on, absf(w - w_prev))
		on_prev = on
		w_prev = w
	var peak := 0.0
	var h := 12
	var a := i_in
	if a + h < th.size():
		for i in range(a + h, mini(th.size(), a + int(2.0 / DT) + 1)):
			peak = maxf(peak, absf(th[i] - th[i - h]) / (h * DT))
	return {"bar_min": snappedf(bmin, 0.01), "bar_max": snappedf(bmax, 0.01), "bar_end": snappedf(bar_end, 0.01),
		"rate_peak_dps": snappedf(peak, 0.1), "step_jump_dps": snappedf(jump, 0.01), "step_jump_on_stop_dps": snappedf(jump_on, 0.01),
		"theta_end_deg": snappedf(th[th.size() - 1], 0.01), "v_end_kmh": snappedf(_g.model.telemetry.airspeed * 3.6, 0.1)}
