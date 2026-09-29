extends Node
## Замер Atmosphere.air_velocity_at, мкс/вызов (AM-05, docs/air_model.md → «Поле на CPU»), и
## побитное сравнение с сохранённым эталоном (поле выключено — аналитика не изменилась). Не игровой
## код. Мир — AtmoFingerprint.make_world (аналитический рельеф), t = 600 с, 6400 точек (сетка
## 40 × 40 × 4 высоты над рельефом), турбулентность включена.
##   XDG_DATA_HOME=$(mktemp -d) godot --headless --path . res://tools/bench/air_velocity_bench.tscn \
##     -- [--out=<файл>] [--compare=<файл>] [--field=<путь .json поля>]
##   --out / --compare — записать / сравнить air_velocity_at и mean_wind_at (float64 подряд)
##   --kayancha — способ базы AM-00: Онгудай, Каянча, 75 м, 100 000 вызовов в точке (с --field —
##             ещё и с полем)
##   --field — подать поле (WindField.load_file) и выборку делать в его области (x, z точек
##             сдвигаются в центр поля, высоты — над рельефом поля); без него — аналитика
## Печатает: «air_velocity_at: X мкс/вызов (лучший из 5, N вызовов)».


func _ready() -> void:
	var out := ""
	var cmp := ""
	var field_path := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
		elif a.begins_with("--compare="):
			cmp = a.substr(10)
		elif a.begins_with("--field="):
			field_path = a.substr(8)
	if OS.get_cmdline_user_args().has("--kayancha"):
		_kayancha(field_path)
		return
	var a := AtmoFingerprint.make_world()
	a.start_at(600.0)
	var pts: Array[Vector3] = []
	var center := Vector2(AtmoFingerprint.CENTER.x, AtmoFingerprint.CENTER.z)
	var step_m := 300.0
	var wf: WindField = null
	if field_path != "":
		wf = WindField.load_file(field_path)
		if wf == null:
			print("air_velocity_bench: поле не прочитано: " + field_path)
			get_tree().quit(1)
			return
		center = wf.center_xz()
		step_m = 0.9 * wf.size_x() / 40.0
		a.set_ground(wf.ground_height, AtmoFingerprint.source_static)
		a.set_air_field(wf, 0.0)
		a.set_air_mode("on")
	for i in 40:
		for j in 40:
			for hh in [5.0, 40.0, 300.0, 1500.0]:
				var x := center.x + (i - 19.5) * step_m
				var z := center.y + (j - 19.5) * step_m
				var gh: float = a.ground.sample(x, z).x
				pts.append(Vector3(x, gh + hh, z))
	var vals := PackedFloat64Array()
	for p in pts:
		var v := a.air_velocity_at(p)
		var m := a.mean_wind_at(p)
		vals.append_array([v.x, v.y, v.z, m.x, m.y, m.z])
	if out != "":
		var f := FileAccess.open(out, FileAccess.WRITE)
		f.store_buffer(vals.to_byte_array())
		f.close()
	if cmp != "":
		var ref := FileAccess.get_file_as_bytes(cmp).to_float64_array()
		var nd := 0
		for i in mini(ref.size(), vals.size()):
			if ref[i] != vals[i]:
				nd += 1
		print("air_velocity_bench: %d значений, отличий от эталона %d" % [ref.size(), nd])
	if wf != null:
		a.set_air_mode("off")
		print("air_velocity_at: %.2f мкс/вызов без поля (те же точки)" % _bench(a, pts))
		a.set_air_mode("on")
	print(
		(
			"air_velocity_at: %.2f мкс/вызов (лучший из 5, %d вызовов)%s"
			% [_bench(a, pts), 4 * pts.size(), " с полем" if wf != null else ""]
		)
	)
	a.free()
	get_tree().quit(0)


func _bench(a: Atmosphere, pts: Array[Vector3]) -> float:
	var best := 1.0e9
	for r in 5:
		var t0 := Time.get_ticks_usec()
		for k in 4:
			for p in pts:
				a.air_velocity_at(p)
		best = minf(best, float(Time.get_ticks_usec() - t0) / (4.0 * pts.size()))
	return best


## Способ базы AM-00 (docs/plan/air_model_baseline.md → §3): Онгудай, старт Каянча, 75 м над
## землёй, ветер 20 км/ч в склон, 100 000 вызовов в одной точке; без поля и с полем (--field).
func _kayancha(field_path: String) -> void:
	var terrain := Terrain.new()
	terrain.location_id = ""
	if not terrain.load_location("ongudai"):
		print("air_velocity_bench: нет рельефа ongudai")
		get_tree().quit(1)
		return
	var site: Dictionary = terrain.get_start_sites()[0]
	var w: Dictionary = Config.get_config("weather/medium").duplicate(true)
	w.wind_speed_kmh = 20.0
	w.wind_from_deg = float(site.heading_deg)
	var a := Atmosphere.new()
	a.visuals_enabled = false
	a.seed_value = 4242
	a.configure(Config.get_config("atmosphere").duplicate(true), w)
	a.set_ground(terrain.height_at, terrain.thermal_source_strength_at, terrain.surface_at)
	var pos0: Vector3 = site.position
	a.set_focus(pos0)
	a.step(1.0)
	var p := Vector3(pos0.x, terrain.height_at(pos0.x, pos0.z) + 75.0, pos0.z)
	var modes: Array[String] = ["off"]
	if field_path != "":
		a.set_air_field(WindField.load_file(field_path), 0.0)
		modes.append("on")
	for mode in modes:
		a.set_air_mode(mode)
		var best := 1.0e9
		for r in 3:
			var t0 := Time.get_ticks_usec()
			for i in 100000:
				a.air_velocity_at(p)
			best = minf(best, float(Time.get_ticks_usec() - t0) / 100000.0)
		print(
			"air_velocity_at Каянча 75 м: %.2f мкс/вызов (%s, лучший из 3 × 100 000), v = %s"
			% [best, "с полем" if mode == "on" else "без поля", a.air_velocity_at(p)]
		)
	a.free()
	terrain.free()
	get_tree().quit(0)
