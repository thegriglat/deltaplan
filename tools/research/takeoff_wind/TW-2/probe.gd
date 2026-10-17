extends Node
## TW-2: замер ветра у старта. Запуск (окно для GPU, как lee_cal/run.sh):
##   godot --path . --audio-driver Dummy --resolution 320x240 res://tools/research/takeoff_wind/TW-2/probe.tscn -- \
##     --autostart --location=training_island --site=thermal_plain [--hour=12 …] --out=<json> [--nobake] [--mode=column|obs1] [--secs=60]
## column: последний air_model (k, U₁), профиль у старта 0–200 м по уровням поля (окно 50/100 м, область) и
##         среднее атмосферы; ряд w у старта (полный воздух, термики) за --secs игровых секунд (game.tick).
## obs1:   наблюдение 1 — как tests/steam/test_achievements_e2e.gd до 00be3e4c: 12 с на 150 м, затем 1,5 м над
##         землёй с курсом старта, v = (0, −1, 0), 20 с; ряд высоты, скорости и воздуха у аппарата.
const MAIN_SCENE := preload("res://scenes/main.tscn")
const DT := 1.0 / 120.0
var _out := ""
var _mode := "column"
var _secs := 60.0
var _nobake := false
var _main: Node = null
var _log_lines: Array = []


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.substr(2).split("=", true, 1)
		var v := kv[1] if kv.size() > 1 else ""
		match kv[0]:
			"out": _out = v
			"mode": _mode = v
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
	if _mode == "obs1":
		res.obs1 = _obs1(g)
	else:
		res.column = _column(g)
		res.series = _series(g)
	var f := FileAccess.open(_out, FileAccess.WRITE)
	f.store_string(JSON.stringify(res, " "))
	f.close()
	print("tw2_probe: OK ", _out)
	_main.queue_free()
	for i in 2:
		await get_tree().process_frame
	get_tree().quit(0)


static func _clean(d: Dictionary) -> Dictionary:
	var o := {}
	for k: Variant in d:
		var v: Variant = d[k]
		if v is Dictionary or v is Array or v is String or v is float or v is int or v is bool:
			o[str(k)] = v
		else:
			o[str(k)] = str(v)
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
	if fs != null:
		for lv: WindField in fs.levels:
			names.append("dx%d" % int(lv.dx))
	out.levels = names
	for agl in [1.0, 2.0, 5.0, 10.0, 20.0, 50.0, 100.0, 200.0, 400.0]:
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


## w и горизонталь у старта за _secs игровых секунд: полный воздух (с термиками и болтанкой), термики (field.sample).
func _series(g: Game) -> Dictionary:
	var st := g.get_start()
	var p: Vector3 = st.position
	var atmo: Node = g.air
	var gh: float = g.terrain.height_at(p.x, p.z)
	g.process_mode = Node.PROCESS_MODE_DISABLED
	var agls := [1.0, 2.0, 5.0, 10.0, 20.0, 50.0]
	var acc := {}
	for a in agls:
		acc[a] = {w = [], h = [], th = []}
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
			acc[a].th.append(th.x)
	var o := {}
	for a in agls:
		o[str(a)] = {w = _stats(acc[a].w), h = _stats(acc[a].h), thermal = _stats(acc[a].th)}
	# термики в радиусе 500 м от старта
	var near: Array = atmo.thermals_near(Vector3(p.x, gh + 100.0, p.z), 500.0)
	var tl := []
	for t: Dictionary in near:
		tl.append(_clean(t))
	o.thermals_500m = tl
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


func _obs1(g: Game) -> Dictionary:
	g.process_mode = Node.PROCESS_MODE_DISABLED
	var atmo: Node = g.air
	var st := g.get_start()
	var p: Vector3 = st.position
	p.y = g.terrain.height_at(p.x, p.z) + 150.0
	g.glider.reset_in_air(p, float(st.heading_deg))
	for i in 120 * 12:
		g.tick(DT)
	p.y = g.terrain.height_at(p.x, p.z) + 1.5
	g.glider.reset_in_air(p, float(st.heading_deg))
	g.glider.model.velocity = Vector3(0.0, -1.0, 0.0)
	var ended: Array = []
	g.flight_ended.connect(func(k: String, _i: Dictionary) -> void: ended.append(k))
	var rows := []
	var p0: Vector3 = g.glider.model.position
	for i in 120 * 22:
		g.tick(DT)
		if i % 12 == 0:
			var q: Vector3 = g.glider.model.position
			var gh: float = g.terrain.height_at(q.x, q.z)
			var air: Vector3 = atmo.air_velocity_at(q)
			var mw: Vector3 = atmo.mean_wind_at(q)
			var th: Vector3 = atmo.field.sample(q)
			var vel: Vector3 = g.glider.model.velocity
			rows.append({
				t = i * DT, dist = Vector2(q.x - p0.x, q.z - p0.z).length(), y = q.y, ground = gh, agl = q.y - gh,
				vy = vel.y, vh = Vector2(vel.x, vel.z).length(), air_w = air.y, air_h = Vector2(air.x, air.z).length(),
				mean_w = mw.y, thermal_w = th.x, ended = ended.duplicate()
			})
		if not ended.is_empty() and i > 0:
			break
	return {ended = ended, rows = rows, start = [p0.x, p0.y, p0.z], heading = st.heading_deg}
