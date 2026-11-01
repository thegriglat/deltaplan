extends Node
## TKF-1 (TKF-К1 v1): углы тележки к крылу дельталёта игрока. Headless:
##   godot --headless --path . res://tools/research/trike-fix/coupling_run.tscn -- [--out=<каталог>] [--only=a,b] [--dt=120]
## Пишет <out>/<сценарий>.csv и <out>/summary.json (временный файл + переименование).
## Шаг модели как в игре (physics_ticks_per_second = 120), ввод и тяга - как Glider.step, но тяга задана напрямую
## из таблицы configs/tow_tug.json (газ g: T = idle + g (full - idle)), без TrikeEngine.

const BAR_WING := Vector3(0.0, 0.6793, -1.5287)  ## штанга trim в осях крыла от HangPoint (trapeze.json wing_frame_bar)
const BAR_TRIM := Vector2(0.72, 1.51)  ## (y, -z) в осях тележки: trike_params.json bar.trim
const SCENARIOS := ["trim_full", "push_full", "pull_full", "throttle_step", "turn30_half", "turn30_idle",
	"turn45_half", "turn45_idle", "reversal45", "roll_pump", "pitch_pump"]
## Дополнительные сценарии (не в контракте)
const EXTRA := ["pitch_pump_2p0", "pitch_pump_3p2", "pitch_pump_4p0", "turn45_full", "reversal45_idle", "roll_pump_idle"]

var _out := "res://tools/research/trike-fix/out"
var _dt := 1.0 / 120.0
var _cfg: Dictionary
var _g: Glider
var _bank_i := 0.0


func _ready() -> void:
	var only: PackedStringArray = []
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--only="):
			only = a.substr(7).split(",")
		elif a.begins_with("--dt="):
			_dt = 1.0 / float(a.substr(5))
	DirAccess.make_dir_recursive_absolute(_out)
	_cfg = Config.get_config("tow_tug")
	var names: Array = SCENARIOS + EXTRA
	var res := {}
	for n: String in names:
		if not only.is_empty() and not (n in only):
			continue
		res[n] = _run(n)
		print("coupling: ", n, " ", JSON.stringify(res[n]))
	var limits := {"push_deg": 4.95, "pull_deg": 8.39}
	var tp: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tools/blender/trike_params.json"))
	limits = {"push_deg": float(tp.bar.push_deg), "pull_deg": float(tp.bar.pull_deg)}
	var out := {"version": 1, "dt_s": _dt, "git": _git(), "limits": limits, "scenarios": res}
	var tmp := _out.path_join("summary.json.tmp")
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	f.store_string(JSON.stringify(out, "\t"))
	f.close()
	DirAccess.rename_absolute(tmp, _out.path_join("summary.json"))
	get_tree().quit(0)


func _git() -> String:
	var o := []
	OS.execute("git", ["rev-parse", "--short", "HEAD"], o)
	return String(o[0]).strip_edges() if o.size() > 0 else "?"


func _thrust(v: float, gk: float) -> float:
	var th: Dictionary = _cfg.thrust
	var ti := _interp(th.v_ms, th.idle_n, v)
	return ti + gk * (_interp(th.v_ms, th.full_n, v) - ti)


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


## Регулятор крена: цель target_deg (+ вправо), ПИД как BankHold тестов (6; 2,5; 1) на шаге dt.
func _bank_roll(target_deg: float) -> float:
	var m: PendulumModel = _g.model
	var e := deg_to_rad(target_deg) - m.bank
	_bank_i = clampf(_bank_i + 1.0 * e * _dt, -1.0, 1.0)
	return clampf(6.0 * e - 2.5 * m.roll_rate + _bank_i, -1.0, 1.0)


## Ввод сценария на момент t: [pitch, roll, газ 0..1, описание газа]
func _inputs(name: String, t: float) -> Array:
	var m: PendulumModel = _g.model
	match name:
		"trim_full":
			return [0.0, 0.0, 1.0]
		"push_full":
			return [1.0 if t < 10.0 else 0.0, 0.0, 1.0]
		"pull_full":
			return [-1.0 if t < 10.0 else 0.0, 0.0, 1.0]
		"throttle_step":
			return [0.0, 0.0, 1.0 if (t >= 5.0 and t < 10.0) else 0.0]
		"turn30_half", "turn30_idle", "turn45_half", "turn45_idle", "turn45_full":
			var tgt := 30.0 if name.begins_with("turn30") else 45.0
			var gk := 0.5 if name.ends_with("half") else (0.0 if name.ends_with("idle") else 1.0)
			var ramp := clampf((t - 2.0) / 3.0, 0.0, 1.0)  # вход в крен за 3 с после 2 с прямого
			return [0.0, _bank_roll(tgt * ramp), gk]
		"reversal45", "reversal45_idle":
			var gk2 := 0.5 if name == "reversal45" else 0.0
			var tg := 0.0
			if t >= 2.0 and t < 12.0:
				tg = 45.0
			elif t >= 12.0 and t < 22.0:
				tg = -45.0
			elif t >= 22.0:
				tg = 45.0
			return [0.0, _bank_roll(tg), gk2]
		"roll_pump", "roll_pump_idle":
			return [0.0, 1.0 if int(floor(t / 2.0)) % 2 == 0 else -1.0, 1.0 if name == "roll_pump" else 0.0]
		_:
			if name.begins_with("pitch_pump"):
				var per := 2.6
				if name != "pitch_pump":
					per = float(name.substr(11).replace("p", "."))
				return [1.0 if fmod(t, per) < per * 0.5 else -1.0, 0.0, 1.0]
	return [0.0, 0.0, 0.0]


static func _desc(name: String) -> String:
	if name.ends_with("_half") or name in ["reversal45"]:
		return "half"
	if name.ends_with("_idle"):
		return "idle"
	if name == "throttle_step":
		return "0 -> 1 on 5 s -> 0"
	return "full"


func _duration(name: String) -> float:
	if name == "trim_full":
		return 30.0
	if name.begins_with("push") or name.begins_with("pull"):
		return 20.0
	if name == "throttle_step":
		return 35.0
	if name.begins_with("turn"):
		return 25.0
	if name.begins_with("reversal"):
		return 32.0
	return 20.0


func _run(name: String) -> Dictionary:
	if _g != null:
		_g.free()
	_g = Glider.new()
	_g.set_ground_fn(flat)
	_g.setup_trike(_cfg, 0.0, Config.get_config("trike_pilot"))
	_g.reset_in_air(Vector3(0.0, 300.0, 0.0), 0.0, 80.0 / 3.6)
	var rig := _g.trike
	rig.refresh(0.0)
	_bank_i = 0.0
	var dur := _duration(name)
	var n := int(round(dur / _dt))
	var ctl := ControlInput.new()
	var ang_trim := atan2(BAR_TRIM.x, BAR_TRIM.y)
	var keys := ["airspeed_kmh", "bar_deg_vis", "bar_deg_phys", "roll_rel_deg_vis", "roll_rel_deg_phys",
		"yaw_rel_deg_vis", "yaw_rel_deg_phys", "mast_normal_deg_vis", "mast_normal_deg_phys", "vis_lag_deg"]
	var mm := {}
	for k: String in keys:
		mm[k] = [INF, -INF]
	var rows := PackedStringArray(["t_s,thrust_n,bank_deg,wing_pitch_deg,heading_deg," + ",".join(keys)])
	var every := maxi(1, int(round(0.05 / _dt)))
	var ok := true
	var lims := [40.0, 60.0, 90.0, 180.0]
	var alt: Array = []
	var altmax: Array = []
	for _l in lims:
		alt.append(rig._cart_model_basis(rig.pilot_pos, rig.hang_pos, rig.wing_basis, false))
		altmax.append(0.0)
	var prev_cp := alt[0] as Basis
	var rate_max := 0.0
	var rates: Array = []
	var jump := rad_to_deg(rig._cart_model_basis(rig.pilot_pos, rig.hang_pos, rig.wing_basis, true).get_rotation_quaternion().angle_to(
		rig._cart_model_basis(rig.pilot_pos, rig.hang_pos, rig.wing_basis, false).get_rotation_quaternion()))
	for i in n:
		var t := i * _dt
		var u := _inputs(name, t)
		ctl.pitch = u[0]
		ctl.roll = u[1]
		var v: float = _g.model.telemetry.airspeed
		rig.thrust_n = _thrust(v, u[2])
		_g.model.step(_dt, ctl, Callable(), Callable(flat_ground_cb()))
		rig.refresh(_dt)
		var w := rig.wing_basis
		var cv := rig.cart_basis
		var cp := rig._cart_model_basis(rig.pilot_pos, rig.hang_pos, w, false)
		var vals := {"airspeed_kmh": _g.model.telemetry.airspeed * 3.6}
		for suf in ["vis", "phys"]:
			var c: Basis = cv if suf == "vis" else cp
			var bw: Vector3 = c.transposed() * (w * BAR_WING)
			vals["bar_deg_" + suf] = rad_to_deg(atan2(bw.y, -bw.z) - ang_trim)
			var yw: Vector3 = c.transposed() * w.y
			vals["roll_rel_deg_" + suf] = -rad_to_deg(atan2(yw.x, yw.y))
			var mast: Vector3 = (-(c * TrikeRig.CART_CM_MODEL)).normalized()
			var kf: Vector3 = -w.z
			var pr := (kf - mast * kf.dot(mast)).normalized()
			vals["yaw_rel_deg_" + suf] = rad_to_deg(atan2(pr.dot(c.x), pr.dot(-c.z)))
			vals["mast_normal_deg_" + suf] = rad_to_deg(mast.angle_to(w.y))
		var rt := rad_to_deg(prev_cp.get_rotation_quaternion().angle_to(cp.get_rotation_quaternion())) / _dt
		prev_cp = cp
		if i > 0:
			rate_max = maxf(rate_max, rt)
			rates.append(rt)
		for j in lims.size():
			alt[j] = TrikeRig._turn_toward(alt[j], cp, deg_to_rad(lims[j]) * _dt)
			altmax[j] = maxf(altmax[j], rad_to_deg((alt[j] as Basis).get_rotation_quaternion().angle_to(cp.get_rotation_quaternion())))
		vals["vis_lag_deg"] = rad_to_deg(cv.get_rotation_quaternion().angle_to(cp.get_rotation_quaternion()))
		for k: String in keys:
			var x: float = vals[k]
			if not is_finite(x):
				ok = false
				continue
			mm[k][0] = minf(mm[k][0], x)
			mm[k][1] = maxf(mm[k][1], x)
		if i % every == 0:
			var r: PackedStringArray = [
				"%.3f" % t, "%.1f" % rig.thrust_n, "%.3f" % rad_to_deg(_g.model.bank),
				"%.3f" % rad_to_deg(_g.model.theta), "%.3f" % rad_to_deg(_g.model.heading)]
			for k: String in keys:
				r.append("%.4f" % float(vals[k]))
			rows.append(",".join(r))
	var f := FileAccess.open(_out.path_join(name + ".csv"), FileAccess.WRITE)
	f.store_string("\n".join(rows) + "\n")
	f.close()
	rates.sort()
	var lag_by := {}
	for j in lims.size():
		lag_by[str(int(lims[j]))] = altmax[j]
	return {
		"cart_phys_rate_dps_max": rate_max, "cart_phys_rate_dps_p99": rates[int(rates.size() * 0.99)],
		"vis_lag_deg_max_by_limit_dps": lag_by, "wheels_to_air_jump_deg": jump,
		"duration_s": dur, "throttle": _desc(name), "finite": ok,
		"airspeed_kmh": mm.airspeed_kmh, "bar_deg_vis": mm.bar_deg_vis, "bar_deg_phys": mm.bar_deg_phys,
		"roll_rel_deg_vis": mm.roll_rel_deg_vis, "roll_rel_deg_phys": mm.roll_rel_deg_phys,
		"yaw_rel_deg_vis": mm.yaw_rel_deg_vis, "yaw_rel_deg_phys": mm.yaw_rel_deg_phys,
		"mast_normal_deg_max_vis": mm.mast_normal_deg_vis[1], "mast_normal_deg_max_phys": mm.mast_normal_deg_phys[1],
		"vis_lag_deg_max": mm.vis_lag_deg[1]}


func flat_ground_cb() -> Callable:
	return Callable(self, "_ground")


func _ground(_x: float, _z: float) -> float:
	return 0.0
