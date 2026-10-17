extends Node
## AWW-1: замер W1 у старта (по TW-2 probe.gd). Запуск (окно для GPU, как lee_cal/run.sh):
##   godot --path . --audio-driver Dummy --resolution 320x240 res://tools/research/air_weak_wind/AWW-1/probe.tscn -- \
##     --autostart --location=training_island --site=thermal_plain [--nobake] --out=<json> [--secs=60]
## Пишет json: last_info (итерации, фазы, заморозка), stats фаз (Fr, U_sat, N, w*, z_i, веса у старта), профиль
## среднего ветра/θ′/w_conv по уровням поля 1–400 м, z0 по уровням, turb_at на 10 м (u*, w*, h), ряд полного
## воздуха за --secs игровых секунд на 2/5/10/20/50 м, термики в 2 км, облака в 5 км, |w| на 1500 м в 5 км.
const MAIN_SCENE := preload("res://scenes/main.tscn")
const DT := 1.0 / 120.0
var _out := ""
var _secs := 60.0
var _nobake := false
var _main: Node = null


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.substr(2).split("=", true, 1)
		var v := kv[1] if kv.size() > 1 else ""
		match kv[0]:
			"out": _out = v
			"secs": _secs = float(v)
			"nobake": _nobake = true
	_run()


func _run() -> void:
	_main = MAIN_SCENE.instantiate()
	add_child(_main)
	var g: Game = _main.get_node("Game")
	var t0 := Time.get_ticks_msec()
	while int(_main.get("state")) != 2 and Time.get_ticks_msec() - t0 < 900000:
		if _nobake and g.air_runtime != null:
			g.air_runtime.baked_enabled = false
			g.air_runtime.cache_enabled = false
		await get_tree().process_frame
	await get_tree().create_timer(2.0, true, false, true).timeout
	var res := {}
	var rt := g.air_runtime
	res.last_info = _clean(rt.last_info) if rt != null else {}
	res.field_on = g.air.is_air_field_on()
	res.phase = _phase(rt, g)
	res.column = _column(g)
	res.series = _series(g)
	res.around = _around(g)
	var f := FileAccess.open(_out, FileAccess.WRITE)
	f.store_string(JSON.stringify(res, " "))
	f.close()
	print("aww_probe: OK ", _out)
	_main.queue_free()
	for i in 2:
		await get_tree().process_frame
	get_tree().quit(0)


static func _clean(d: Dictionary) -> Dictionary:
	var o := {}
	for k: Variant in d:
		var v: Variant = d[k]
		if v is Dictionary:
			o[str(k)] = _clean(v)
		elif v is Array or v is String or v is float or v is int or v is bool:
			o[str(k)] = v
		elif v is PackedFloat32Array or v is PackedFloat64Array:
			o[str(k)] = "packed[%d]" % v.size()
		else:
			o[str(k)] = str(v)
	return o


## Числа фаз (stats P10) и веса фаз в клетке старта; числа случая области (AirCase).
func _phase(rt: AirRuntime, g: Game) -> Dictionary:
	var o := {}
	if rt == null:
		return o
	var ph: Dictionary = rt.get("_phase")
	if ph != null and not ph.is_empty():
		var st: Dictionary = ph.get("stats", {})
		var so := {}
		for k: Variant in st:
			var v: Variant = st[k]
			if v is float or v is int or v is bool or v is String:
				so[str(k)] = v
			elif v is Dictionary and str(k) == "phase_frac":
				so[str(k)] = v
		o.stats = so
	var pm: Dictionary = rt.phase_map
	if pm != null and not pm.is_empty():
		var p: Vector3 = g.get_start().position
		var nx: int = pm.nx
		var ny: int = pm.ny
		var i := clampi(int(floor((p.x - float(pm.x0)) / float(pm.dx))), 0, nx - 1)
		var j := clampi(int(floor((-p.z - float(pm.y0)) / float(pm.dx))), 0, ny - 1)
		var w: PackedFloat32Array = pm.weights
		var names: Array = pm.phases
		var ws := {}
		for k in names.size():
			ws[str(names[k])] = w[k * nx * ny + j * nx + i]
		o.weights_at_start = ws
		o.cell = [i, j]
	var prep: Dictionary = rt.get("_prep")
	if prep != null and prep.has("case"):
		var c: AirCase = prep.case
		o.case = {
			u10 = c.u10, u_a = c.u_a, ustar = c.ustar, z_i = c.z_i, alpha = float(c.p.alpha), z0 = float(c.p.z0),
			max_profile = float(c.p.max_profile), closure = _clean(c.closure_info), nx = c.nx, ny = c.ny, dx = c.dx,
		}
		# h_bl и θ′-вход (H_k) области в столбце старта
		var p: Vector3 = g.get_start().position
		var i := clampi(int(floor((p.x - c.x0) / c.dx)), 0, c.nx - 1)
		var j := clampi(int(floor((-p.z - c.y0) / c.dx)), 0, c.ny - 1)
		var q := j * c.nx + i
		if c.h_bl.size() > q:
			o.case.h_bl_start = c.h_bl[q]
		if c.heat_used.size() > q:
			o.case.heat_start_wm2 = c.heat_used[q]
		if c.z0_map.size() > q:
			o.case.z0_start = c.z0_map[q]
	return o


func _column(g: Game) -> Dictionary:
	var st := g.get_start()
	var p: Vector3 = st.position
	var atmo: Node = g.air
	var gh: float = g.terrain.height_at(p.x, p.z)
	var gs: Vector4 = atmo.ground.sample(p.x, p.z)
	var out := {start = [p.x, p.z], heading = st.heading_deg, ground = gh, ground_field = gs.x, rows = []}
	var fs: AirFieldSet = atmo.air_field
	var names := []
	var z0s := {}
	var zis := {}
	if fs != null:
		for lv: WindField in fs.levels:
			var nm := "dx%d" % int(lv.dx)
			names.append(nm)
			z0s[nm] = lv.z0_at(p)
			zis[nm] = lv.z_i_at(p)
	out.levels = names
	out.z0 = z0s
	out.z_i_msl = zis
	out.turb10 = Array(fs.sample_turb(Vector3(p.x, gh + 10.0, p.z), gs.x)) if fs != null else []
	for agl in [1.0, 2.0, 5.0, 10.0, 20.0, 30.0, 50.0, 75.0, 100.0, 150.0, 200.0, 300.0, 400.0, 600.0, 1000.0]:
		var q := Vector3(p.x, gh + agl, p.z)
		var m: Vector3 = atmo.mean_wind_at(q)
		var row := {agl = agl, mean = [m.x, m.z, m.y], mean_h = Vector2(m.x, m.z).length()}
		if fs != null:
			var fw := fs.sample(q, gs.x)
			row.set_weight = fw.w
			var per := {}
			for lv: WindField in fs.levels:
				var s := lv.sample(q, gs.x)
				per["dx%d" % int(lv.dx)] = [s.x, s.z, s.y, lv.sample_w_conv(q, gs.x), lv.sample_theta(q, gs.x)]
			row.levels = per
		out.rows.append(row)
	return out


## Полный воздух у старта за _secs игровых секунд (с термиками и болтанкой): w, модуль горизонтали,
## продольная (вдоль среднего ветра на этой высоте) — статистика.
func _series(g: Game) -> Dictionary:
	var st := g.get_start()
	var p: Vector3 = st.position
	var atmo: Node = g.air
	var gh: float = g.terrain.height_at(p.x, p.z)
	g.process_mode = Node.PROCESS_MODE_DISABLED
	var agls := [2.0, 5.0, 10.0, 20.0, 50.0]
	var acc := {}
	var dirs := {}
	for a in agls:
		acc[a] = {w = [], h = [], l = [], th = []}
		var m: Vector3 = atmo.mean_wind_at(Vector3(p.x, gh + a, p.z))
		var d := Vector2(m.x, m.z)
		dirs[a] = d.normalized() if d.length() > 1e-6 else Vector2(1, 0)
	var n := int(_secs / DT)
	for i in n:
		g.tick(DT)
		if i % 12 != 0:
			continue
		for a in agls:
			var q := Vector3(p.x, gh + a, p.z)
			var v: Vector3 = atmo.air_velocity_at(q)
			var th: Vector3 = atmo.field.sample(q)
			acc[a].w.append(v.y)
			acc[a].h.append(Vector2(v.x, v.z).length())
			acc[a].l.append(Vector2(v.x, v.z).dot(dirs[a]))
			acc[a].th.append(th.x)
	var o := {}
	for a in agls:
		o[str(a)] = {w = _stats(acc[a].w), h = _stats(acc[a].h), along = _stats(acc[a].l), thermal = _stats(acc[a].th)}
	return o


static func _stats(a: Array) -> Dictionary:
	if a.is_empty():
		return {}
	var s := 0.0
	var mx := -INF
	var mn := INF
	for x: float in a:
		s += x
		mx = maxf(mx, x)
		mn = minf(mn, x)
	var m := s / a.size()
	var v := 0.0
	for x: float in a:
		v += (x - m) * (x - m)
	return {mean = m, std = sqrt(v / a.size()), max = mx, min = mn, n = a.size()}


## Термики в 2 км (w ядра на 300 м над землёй), облака в 5 км (доля, основание над стартом), |w| среднего
## поля на 1500 м над стартом в 5 км.
func _around(g: Game) -> Dictionary:
	var st := g.get_start()
	var p: Vector3 = st.position
	var atmo: Node = g.air
	var gh: float = g.terrain.height_at(p.x, p.z)
	var o := {}
	var near: Array = atmo.thermals_near(Vector3(p.x, gh + 100.0, p.z), 2000.0)
	var tl := []
	var wmax := 0.0
	for t: Dictionary in near:
		var src: Vector3 = t.source
		var ga: Vector3 = t.ground_axis
		var q := Vector3(ga.x, src.y + 300.0, ga.z)
		var w: float = atmo.field.sample(q).x
		wmax = maxf(wmax, w)
		tl.append({id = t.id, src = [src.x, src.y, src.z], top = t.top_m, strength = t.strength_ms, radius = t.radius_m,
				env = t.envelope, w300 = w, cloud = t.has_cloud})
	o.thermals = tl
	o.therm_n = near.size()
	o.therm_w300 = wmax
	# облака в круге 5 км
	var cov_sum := 0.0
	var cov_n := 0
	var cp: CloudPhysics = atmo.cloud_phys
	if cp != null:
		var c0: Vector4 = cp.field_cover_at(Vector3(p.x, gh + 1000.0, p.z))
		o.cloud_at_start = [c0.x, c0.y, c0.z, c0.w]
		for dx in range(-5000, 5001, 500):
			for dz in range(-5000, 5001, 500):
				if dx * dx + dz * dz > 5000 * 5000:
					continue
				var c: Vector4 = cp.field_cover_at(Vector3(p.x + dx, gh + 1000.0, p.z + dz))
				cov_sum += c.x
				cov_n += 1
	o.cloud_frac = cov_sum / cov_n if cov_n > 0 else -1.0
	o.cloudbase_msl = atmo.get_cloudbase_msl()
	# волна/обтекание: |w| среднего поля на 1500 м над стартом в круге 5 км
	var wm := 0.0
	for dx in range(-5000, 5001, 250):
		for dz in range(-5000, 5001, 250):
			if dx * dx + dz * dz > 5000 * 5000:
				continue
			var w: float = atmo.mean_wind_at(Vector3(p.x + dx, gh + 1500.0, p.z + dz)).y
			wm = maxf(wm, absf(w))
	o.wave_w1500 = wm
	return o
