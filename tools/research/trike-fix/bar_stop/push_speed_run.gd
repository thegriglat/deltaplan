extends Node
## TKF-5: установившаяся скорость на полном «от себя» (газ 0/1), минимум скорости, касание с 5 м при полном «от себя» (газ 0).
## godot --headless --path . res://tools/research/trike-fix/bar_stop/push_speed_run.tscn -- [--nostop]
const DT := 1.0 / 120.0
var _cfg: Dictionary


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
	_cfg = Config.get_config("tow_tug").duplicate(true)
	if "--nostop" in OS.get_cmdline_user_args():
		_cfg.cart.erase("strut_stop")
	var out := {}
	for gas in [0.0, 1.0]:
		var g := _mk(300.0)
		var vmin := INF
		var vs := []
		for i in int(60.0 / DT):
			_step(g, 1.0, gas)
			var v: float = g.model.telemetry.airspeed * 3.6
			if i * DT > 5.0:
				vmin = minf(vmin, v)
			if i % 1200 == 1199:
				vs.append(snappedf(v, 0.1))
		out["push60s_gas%.0f" % gas] = {"v_each10s_kmh": vs, "v_min_kmh": snappedf(vmin, 0.1), "alt_end_m": snappedf(g.model.position.y, 1.0)}
		g.free()
	# касание: с 5 м над землёй, 80 км/ч, газ 0, полный «от себя» с начала
	var g2 := _mk(5.0)
	var landed := false
	g2.landed.connect(func(r: Dictionary) -> void: landed = true; out["landed"] = {"horiz_kmh": snappedf(float(r.horizontal_speed_ms) * 3.6, 0.1), "vert_ms": snappedf(float(r.vertical_speed_ms), 0.01), "grade": r.grade})
	var vlast := 0.0
	for i in int(40.0 / DT):
		vlast = g2.model.telemetry.airspeed * 3.6
		_step(g2, 1.0, 0.0)
		if landed or g2.model.position.y < 0.3:
			break
	out["touch_airspeed_kmh"] = snappedf(vlast, 0.1)
	out["touch_t_s"] = snappedf(g2.model.time_s, 0.1)
	print("PUSH_SPEED ", JSON.stringify(out))
	get_tree().quit(0)


func _mk(h: float) -> Glider:
	var g := Glider.new()
	g.set_ground_fn(flat)
	g.setup_trike(_cfg, 0.0, Config.get_config("trike_pilot"))
	g.reset_in_air(Vector3(0.0, h, 0.0), 0.0, 80.0 / 3.6)
	g.trike.refresh(0.0)
	return g


var _ctl := ControlInput.new()


func _step(g: Glider, p: float, gas: float) -> void:
	_ctl.pitch = p
	g.trike.thrust_n = _thrust(g.model.telemetry.airspeed, gas)
	g.model.step(DT, _ctl, Callable(), Callable(flat))
	g.trike.refresh(DT)
