extends Node
## TKF-9: установившаяся скорость и bar_deg_phys по вводу (-1..+1) и газу (0, 1); без упора (ветка feature/trike-fix).
## godot --headless --path . res://tools/research/trike-fix/strut/speed_bar_run.tscn -- --out=f.json [--pull=0.25]
## bar_deg_phys - как bar_stop_run.gd TKF-5 (середина базовой штанги в осях C_phys от bar.trim; + к подкосу).
const BAR_WING := Vector3(0.0, 0.6793, -1.5287)
const BAR_TRIM := Vector2(0.72, 1.51)
const DT := 1.0 / 120.0
var _cfg: Dictionary
var _pull := 0.25


static func flat(_x: float, _z: float) -> float:
	return 0.0


func _interp(xs: Array, ys: Array, x: float) -> float:
	if x <= xs[0]:
		return ys[0]
	for i in range(1, xs.size()):
		if x <= xs[i]:
			return ys[i - 1] + (x - xs[i - 1]) / (xs[i] - xs[i - 1]) * (ys[i] - ys[i - 1])
	return ys[xs.size() - 1]


func _thrust(v: float, gk: float) -> float:
	var th: Dictionary = _cfg.thrust
	var ti := _interp(th.v_ms, th.idle_n, v)
	return ti + gk * (_interp(th.v_ms, th.full_n, v) - ti)


func _ready() -> void:
	var out := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
		elif a.begins_with("--pull="):
			_pull = float(a.substr(7))
	_cfg = Config.get_config("tow_tug").duplicate(true)
	var res := {}
	for gas in [0.0, 1.0]:
		for p in [-1.0, -0.75, -0.5, -0.25, 0.0, 0.25, 0.5, 0.75, 1.0]:
			res["g%.0f_p%+.2f" % [gas, p]] = _run(p, gas)
	print("SPEED_BAR ", JSON.stringify(res))
	if out != "":
		var f := FileAccess.open(out, FileAccess.WRITE)
		f.store_string(JSON.stringify(res, "\t"))
		f.close()
	get_tree().quit(0)


func _run(pitch: float, gas: float) -> Dictionary:
	var g := Glider.new()
	g.set_ground_fn(flat)
	g.setup_trike(_cfg, 0.0, Config.get_config("trike_pilot"))
	g.model.arms.shift_x_pull = _pull
	g.model.arms.shift_x_pull_full = _pull
	g.model.arms.pull_limit = _pull
	g.reset_in_air(Vector3(0.0, 800.0, 0.0), 0.0, 80.0 / 3.6)
	var rig := g.trike
	rig.refresh(0.0)
	var ctl := ControlInput.new()
	ctl.pitch = pitch
	var T := 90.0
	var n := int(T / DT)
	var vs := []
	var bs := []
	var vmin := INF
	var bmax := -INF
	for i in n:
		var v: float = g.model.telemetry.airspeed
		rig.thrust_n = _thrust(v, gas)
		g.model.step(DT, ctl, Callable(), Callable(flat))
		rig.refresh(DT)
		var c := rig._cart_model_basis(rig.pilot_pos, rig.hang_pos, rig.wing_basis, false)
		var bw: Vector3 = c.transposed() * (rig.wing_basis * BAR_WING)
		var b := rad_to_deg(atan2(bw.y, -bw.z) - atan2(BAR_TRIM.x, BAR_TRIM.y))
		if i * DT >= 5.0:
			vmin = minf(vmin, v * 3.6)
			bmax = maxf(bmax, b)
		if i * DT >= T - 20.0:
			vs.append(v * 3.6)
			bs.append(b)
	var sv := 0.0
	var sb := 0.0
	for x in vs:
		sv += x
	for x in bs:
		sb += x
	var alt: float = g.model.position.y
	g.free()
	return {"v_mean_kmh": snappedf(sv / vs.size(), 0.1), "bar_mean": snappedf(sb / bs.size(), 0.01),
		"v_min_kmh": snappedf(vmin, 0.1), "bar_max": snappedf(bmax, 0.01), "alt_end": snappedf(alt, 1.0)}
