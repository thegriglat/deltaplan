extends Node
## TKF-9: установившаяся скорость и bar_deg_phys по вводу (-1..+1) и газу (0, 1); без упора (ветка feature/trike-fix).
## godot --headless --path . res://tools/research/trike-fix/strut/speed_bar_run.tscn -- --out=f.json [--pull=0.25]
## bar_deg_phys - как bar_stop_run.gd TKF-5 (середина базовой штанги в осях C_phys от bar.trim; + к подкосу).
const BAR_WING := Vector3(0.0, 0.6793, -1.5287)
const BAR_TRIM := Vector2(0.72, 1.51)
const DT := 1.0 / 120.0
const CM_BEHIND := Vector3(0.0, -1.70, 0.13)
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
		for p in [0.0, 0.5]:
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
	var T := 45.0
	var n := int(T / DT)
	var vs := []
	var bs := []
	var bs2 := []
	var po := 0.0
	var pn := 0.0
	var nn := 0
	var vmin := INF
	var bmax := -INF
	for i in n:
		var v: float = g.model.telemetry.airspeed
		rig.thrust_n = _thrust(v, gas)
		g.model.step(DT, ctl, Callable(), Callable(flat))
		rig.refresh(DT)
		var c := rig._cart_model_basis(rig.pilot_pos, rig.hang_pos, rig.wing_basis, false)
		var pit_old := rad_to_deg(asin(clampf((-c.z).y, -1.0, 1.0)))
		var bw: Vector3 = c.transposed() * (rig.wing_basis * BAR_WING)
		var b := rad_to_deg(atan2(bw.y, -bw.z) - atan2(BAR_TRIM.x, BAR_TRIM.y))
		# CM тележки за подвеской (cart.py: -0,134 м в y Blender = +Z в trike.glb) - знак z обратный CART_CM_MODEL
		var c0 := rig.cart_axes(rig.pilot_pos, rig.hang_pos, rig.wing_basis)
		var c2: Basis = c0 * Basis(Quaternion(CM_BEHIND.normalized(), Vector3.DOWN))
		var bw2: Vector3 = c2.transposed() * (rig.wing_basis * BAR_WING)
		var pit_new := rad_to_deg(asin(clampf((-c2.z).y, -1.0, 1.0)))
		var b2 := rad_to_deg(atan2(bw2.y, -bw2.z) - atan2(BAR_TRIM.x, BAR_TRIM.y))
		if i * DT >= 5.0:
			vmin = minf(vmin, v * 3.6)
			bmax = maxf(bmax, b)
		if i * DT >= T - 15.0:
			vs.append(v * 3.6)
			bs.append(b)
			bs2.append(b2)
			po += pit_old
			pn += pit_new
			nn += 1
	var sv := 0.0
	var sb := 0.0
	var sb2 := 0.0
	for x in vs:
		sv += x
	for x in bs:
		sb += x
	for x in bs2:
		sb2 += x
	var alt: float = g.model.position.y
	g.free()
	return {"v_mean_kmh": snappedf(sv / vs.size(), 0.1), "bar_mean": snappedf(sb / bs.size(), 0.01), "cart_pitch_old_deg": snappedf(po / nn, 0.01), "cart_pitch_cm_behind_deg": snappedf(pn / nn, 0.01), "bar_mean_cm_behind": snappedf(sb2 / bs2.size(), 0.01),
		"v_min_kmh": snappedf(vmin, 0.1), "bar_max": snappedf(bmax, 0.01), "alt_end": snappedf(alt, 1.0)}
