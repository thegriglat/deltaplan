extends Node
## TP-23: прогон связки буксировщик + sport на тросе (как tests/game/test_tow_trike_climb.gd, TT-К4) с подменой чисел.
## Запуск (из корня копии, под замком cpu):
##   godot --headless --path . res://tools/research/trike-pilot/tug/tug_runner.tscn -- <spec.json> <out.jsonl>
## spec.json — массив {name, ovr:{"tow_tug.tow.tow_speed_kmh":55,...}, wing_area_k:1.0, thrust_k:1.0, tmax_s:240}.
## Ключ ovr: "<конфиг>.<путь через точки>" (конфиг — имя для Config.get_config, например tow_tug или wings/trike_ixess15).
## wing_area_k — площадь крыла буксировщика ×k при тех же CL/CD (скорости и снижения поляры ÷√k).
## Требует scripts/flight/trike_rig.gd из ветки TP-20 (thrust_split по оси винта) - в копию TP-23 кладётся временно, не коммитится.
## thrust_k — множитель таблицы тяги full_n/idle_n. Для чисел шлюза: пороги скорость 55-65 км/ч и набор >= 2,54 м/с.
const Sim := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const DT := 1.0 / 120.0
const CLIMB_K := 0.15
const CLIMB_KV := 0.3
const BANK_K := 1.5
const BANK_MAX := 0.35
const ROLL_KP := 3.0
const ROLL_KD := 0.8
const TOP_AGL := 300.0
const SETTLE_S := 5.0


func _set_path(d: Dictionary, path: PackedStringArray, v: Variant) -> void:
	var cur: Dictionary = d
	for i in path.size() - 1:
		cur = cur[path[i]]
	cur[path[path.size() - 1]] = v


func _apply(spec: Dictionary) -> void:
	for key: String in spec.get("ovr", {}):
		var cname := key.substr(0, key.find(".", key.find("/") + 1 if key.contains("/") else 0))
		var rest := key.substr(cname.length() + 1)
		_set_path(Config.get_config(cname), rest.split("."), spec.ovr[key])
	var k := float(spec.get("wing_area_k", 1.0))
	if k != 1.0:
		var w: Dictionary = Config.get_config("wings/trike_ixess15")
		w.area_m2 = float(w.area_m2) * k
		for p: Array in w.polar.points_kmh_ms:
			p[0] = float(p[0]) / sqrt(k)
			p[1] = float(p[1]) / sqrt(k)
	var tk := float(spec.get("thrust_k", 1.0))
	if tk != 1.0:
		var th: Dictionary = Config.get_config("tow_tug").thrust
		for i in th.full_n.size():
			th.full_n[i] = float(th.full_n[i]) * tk
			th.idle_n[i] = float(th.idle_n[i]) * tk


func _run(spec: Dictionary) -> Dictionary:
	Config._cache.erase("tow_tug")
	Config._cache.erase("wings/trike_ixess15")
	Config._cache.erase("tow")
	_apply(spec)
	var cartc: Dictionary = Config.get_config("tow_tug").cart
	if not spec.get("ovr", {}).has("tow_tug.cart.prop_axis_below_hang_m"):
		cartc.prop_axis_below_hang_m = 1.238  ## TP-К6 v2 (ветка TP-20): ось винта; 1,71 = тяга в ЦМ тележки (старая схема)
	var g := Glider.new()
	g.setup("sport", 0.0)
	var flat := func(_x: float, _z: float) -> float: return 0.0
	g.model = Sim.make("sport")
	g.set_ground_fn(flat)
	g.reset_on_ground(Vector3.ZERO, 0.0)
	var s := TowSession.new()
	add_child(s)
	var site := {"start_pos": Vector3.ZERO, "end_pos": Vector3(0.0, 0.0, -400.0), "heading_deg": 0.0}
	s.setup(g, flat, site, "aerotow", false)
	var t := 0.0
	var t_climb := -1.0
	var w0 := -1.0
	var h0 := 0.0
	var w1 := -1.0
	var h1 := 0.0
	var acc := {"v": 0.0, "ten": 0.0, "thr": 0.0, "T": 0.0, "theta": 0.0, "bar": 0.0, "n": 0.0}
	var start_z: float = s.tug.pos.z
	var x_lift := -1.0
	var red_agl := float(Config.get_config("tow_tug").tow.power_reduce_agl_m)
	var tmax := float(spec.get("tmax_s", 240.0))
	while t < tmax:
		var c := Sim.input(0.0, 0.0)
		if g.phase() == "flying":
			var h_t: float = s.tug.agl_m + 3.5
			var vz_rel: float = g.model.velocity.y - s.tug.vel.y
			c.pitch = clampf(CLIMB_K * (h_t - s.glider_agl_m()) - CLIMB_KV * vz_rel, -1.0, 1.0)
			var to_tug: Vector3 = s.tug.pos - g.model.pilot_position
			var brg := Vector2(to_tug.x, -to_tug.z).angle_to(Vector2(0.0, 1.0))
			var he := wrapf(brg - g.model.heading, -PI, PI)
			var bank_tgt := clampf(BANK_K * he, -BANK_MAX, BANK_MAX)
			c.roll = clampf(ROLL_KP * (bank_tgt - g.model.bank) - ROLL_KD * g.model.roll_rate, -1.0, 1.0)
		g.set_input(c)
		s.step(DT, t >= 1.0, false)
		g.step(DT)
		t += DT
		var tg: TowTug = s.tug
		if x_lift < 0.0 and tg.agl_m > 0.5:
			x_lift = absf(tg.pos.z - start_z)
		if tg.phase == "climb":
			if t_climb < 0.0:
				t_climb = t
			if w0 < 0.0 and t - t_climb >= SETTLE_S:
				w0 = t
				h0 = tg.agl_m
			if w0 > 0.0 and tg.agl_m < red_agl:
				w1 = t
				h1 = tg.agl_m
				acc.v += tg.airspeed_ms
				acc.ten += g.model.link_tension_n
				acc.thr += tg.throttle
				acc.T += tg._thrust_n
				acc.bar += tg._bar_i
				acc.theta += rad_to_deg(asin(clampf((-tg.model.wing_basis().z).normalized().y, -1.0, 1.0)))
				acc.n += 1.0
		if tg.agl_m >= TOP_AGL or not Sim.finite(tg.model):
			break
	var dur := w1 - w0
	var n := maxf(acc.n, 1.0)
	var out := {
		"name": spec.get("name", ""), "spec": spec, "dur_s": snappedf(dur, 0.1), "phase": s.tug.phase,
		"climb_ms": snappedf((h1 - h0) / dur if dur > 0.0 else 0.0, 0.01), "speed_kmh": snappedf(acc.v / n * 3.6, 0.1),
		"tension_n": snappedf(acc.ten / n, 1.0), "throttle": snappedf(acc.thr / n, 0.01), "thrust_n": snappedf(acc.T / n, 1.0),
		"bar_i_m": snappedf(acc.bar / n, 0.001), "wing_pitch_deg": snappedf(acc.theta / n, 0.1), "liftoff_m": snappedf(x_lift, 1.0),
		"t_end": snappedf(t, 0.1)}
	s.queue_free()
	g.free()
	return out


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var specs: Array = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
	var f := FileAccess.open(args[1], FileAccess.WRITE)
	for sp: Dictionary in specs:
		var r := _run(sp)
		f.store_line(JSON.stringify(r))
		f.flush()
		print("TUG ", r.name, " climb=", r.climb_ms, " v=", r.speed_kmh, " T=", r.tension_n, " thr=", r.throttle)
	f.close()
	get_tree().quit()
