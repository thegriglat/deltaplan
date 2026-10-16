extends Node
## TI-5: проверка воздуха учебного острова в игре как есть — главная сцена (--autostart, старт с фиксированной
## погодой TI-К2 из конфига места), поле воздуха GPU, термики ThermalField/AirThermals, затем пауза и
## замер в точках с ручным шагом атмосферы (Atmosphere.step). Запуск — из air_check.py (окно, DISPLAY=:0).
## Аргументы после --:
##   --site=<id старта>  --mode=ridge|rotor|thermal|landing  --out=<json>
##   --wind=<м/с>        подменить wind_speed_ms набора старта (только в памяти: склон при 5 и 8 м/с)
##   --shots=<каталог>   кадры F3 (стрелки ветра) и F6 (столбы термиков): <site>_f3.jpg, <site>_f6.jpg, JPEG q88
##   --climb-flights=3   (thermal) сколько вылетов кружения за ≤ 15 мин, со сдвигом старта 5 мин
## Выход: json {cond, info, …} — разбирает air_check.py.

const MAIN_SCENE := preload("res://scenes/main.tscn")
const LOC := "training_island"
const SNAP_N := 5  ## снимков воздуха для среднего по времени (ridge/rotor/landing)
const SNAP_DT := 60.0  ## шаг снимков, с
const STEP_DT := 0.5  ## шаг атмосферы при перемотке, с
const CORE_AGL: Array[float] = [300.0, 400.0, 500.0, 600.0, 700.0, 800.0, 900.0, 1000.0, 1100.0, 1200.0]
const THERMAL_R := 4000.0
const CLIMB_S := 900.0
## Кружение (крыло sport, эталонная масса): крен 30°, скорость минимального снижения ~40 км/ч.
const BANK_DEG := 30.0
const CIRCLE_V_KMH := 40.0
const GLIDE_V_KMH := 48.87  ## лучшее качество поляры sport

var _a := {}
var _main: Node
var _game: Node
var _air: Node
var _terrain: Node
var _cam: Camera3D
var _marker: Node3D


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for s in OS.get_cmdline_user_args():
		if s.begins_with("--"):
			var kv := s.substr(2).split("=", true, 1)
			_a[kv[0]] = kv[1] if kv.size() > 1 else "1"
	var site := String(_a.get("site", "ridge_west"))
	var cfg: Dictionary = Config.get_config("locations/" + LOC)
	for st: Dictionary in cfg.start_sites:
		if String(st.id) == site and _a.has("wind") and st.has("weather"):
			st.weather.wind_speed_ms = float(_a.wind)  # только в памяти этого процесса
	_main = MAIN_SCENE.instantiate()
	_main.set("opts", LaunchOptions.parse(PackedStringArray([
		"--autostart", "--location=" + LOC, "--site=" + site, "--bots=0", "--no-overlay"])))
	add_child(_main)
	_run.call_deferred()


func _wait(s: float) -> void:
	await get_tree().create_timer(s, true).timeout


func _run() -> void:
	var t0 := Time.get_ticks_msec()
	_game = _main.get_node("Game")
	for i in 20000:
		if int(_main.get("state")) == 2:
			break
		await get_tree().process_frame
	if int(_main.get("state")) != 2:
		push_error("air_check: полёт не начался")
		get_tree().quit(1)
		return
	await _wait(3.0)
	_air = _game.get("air")
	_terrain = _game.get("terrain")
	var settings: Object = _game.get("settings")
	var start: Vector3 = _game.get("_start_pos")
	var res := {
		"cond": {
			"site": String(_a.get("site", "")), "mode": String(_a.get("mode", "")),
			"start": [start.x, start.y, start.z], "heading": _game.get("_start_heading"),
			"wind_kmh": settings.wind_speed_kmh, "wind_from": settings.wind_from_deg, "hour": settings.start_hour,
			"month": settings.month, "day": settings.day, "sky": settings.sky, "temp": settings.temperature_c,
			"wind_ref": StartWeather.wind_ref_of(settings),
		},
		"info": {"load_s": (Time.get_ticks_msec() - t0) / 1000.0, "air_field_on": _air.call("is_air_field_on"),
			"weather": _weather_brief(_air.get("weather")), "cloudbase_msl": _air.call("get_cloudbase_msl")},
	}
	var rt: Node = _game.get_node_or_null("AirRuntime")
	if rt == null:
		for c in _game.get_children():
			if c.get_script() != null and String(c.get_script().resource_path).ends_with("air_runtime.gd"):
				rt = c
	if rt != null:
		res.info["air_runtime"] = rt.get("last_info")
	# Замер: пауза мира, атмосфера шагается вручную, без болтанки (средний поток + термики).
	_marker = Node3D.new()
	add_child(_marker)
	_marker.global_position = start
	var shots := String(_a.get("shots", ""))
	get_tree().paused = true
	_air.set("focus_node", _marker)
	_air.set("turbulence_enabled", false)
	match String(_a.get("mode", "")):
		"ridge":
			res["ridge"] = await _ridge(start)
		"rotor":
			res["rotor"] = await _rotor(start)
		"landing":
			res["landing"] = await _landing()
		"thermal":
			res["thermal"] = await _thermals(start)
	res.info["wall_s"] = (Time.get_ticks_msec() - t0) / 1000.0
	var out_path := String(_a.get("out", "air_check.json"))
	DirAccess.make_dir_recursive_absolute(out_path.get_base_dir())
	var fo := FileAccess.open(out_path, FileAccess.WRITE)
	fo.store_string(JSON.stringify(res))
	fo.close()
	print("air_check_run: ", out_path)
	if shots != "":
		_air.set("turbulence_enabled", true)
		_air.set("focus_node", _game.get("glider"))
		get_tree().paused = false
		await _shots(shots, start)
	get_tree().quit(0)


func _weather_brief(w: Dictionary) -> Dictionary:
	var out := {}
	for k: String in ["thermal_strength_ms", "thermal_radius_m", "thermal_spacing_m", "thermal_duty",
			"background_sink_ms", "cloudbase_agl_m", "dry_thermal_fraction", "wind_speed_kmh", "wind_from_deg"]:
		out[k] = w.get(k)
	var d: Dictionary = w.get("_derived", {})
	for k: String in ["temperature_c", "z_dry_msl_m", "z_lcl_msl_m", "top_agl_m", "heat", "blue"]:
		out[k] = d.get(k)
	return out


## Шагнуть атмосферу на s секунд.
func _advance(s: float) -> void:
	var n := int(ceil(s / STEP_DT))
	for i in n:
		_air.call("step", STEP_DT)
		if i % 40 == 39:
			await get_tree().process_frame


func _h(x: float, z: float) -> float:
	return float(_terrain.call("height_at", x, z))


## Гребень: самая высокая точка по x (шаг 10 м) на широте z.
func _crest(z: float, x0: float, x1: float) -> Vector2:
	var best := Vector2(x0, -1.0e9)
	var x := x0
	while x <= x1:
		var h := _h(x, z)
		if h > best.y:
			best = Vector2(x, h)
		x += 10.0
	return best


## Средние по SNAP_N снимкам (через SNAP_DT): [vx, vy, vz] air_velocity_at и w mean_wind_at.
func _snapshots(pts: Array[Vector3]) -> Array:
	var acc: Array = []
	for p in pts:
		acc.append([0.0, 0.0, 0.0, 0.0, INF])
	for k in SNAP_N:
		if k > 0:
			await _advance(SNAP_DT)
		for i in pts.size():
			var v: Vector3 = _air.call("air_velocity_at", pts[i])
			var m: Vector3 = _air.call("mean_wind_at", pts[i])
			acc[i][0] += v.x / SNAP_N
			acc[i][1] += v.y / SNAP_N
			acc[i][2] += v.z / SNAP_N
			acc[i][3] += m.y / SNAP_N
			acc[i][4] = minf(acc[i][4], v.y)
	return acc


func _ridge(start: Vector3) -> Dictionary:
	var pts: Array[Vector3] = []
	var tags: Array = []
	var dz := -1000.0
	while dz <= 1000.0:
		var z := start.z + dz
		var c := _crest(z, start.x - 600.0, start.x + 800.0)
		for d: float in [100.0, 200.0, 300.0]:
			for a: float in [50.0, 100.0, 150.0]:
				pts.append(Vector3(c.x - d, c.y + a, z))
				tags.append({"dz": dz, "upwind_m": d, "above_crest_m": a, "crest_h": c.y})
		dz += 125.0
	var acc := await _snapshots(pts)
	var rows: Array = []
	for i in pts.size():
		rows.append([pts[i].x, pts[i].y, pts[i].z, acc[i][0], acc[i][1], acc[i][2], acc[i][3], acc[i][4], tags[i]])
	return {"rows": rows}


func _rotor(start: Vector3) -> Dictionary:
	var pts: Array[Vector3] = []
	var tags: Array = []
	var z := start.z - 1250.0
	while z <= start.z + 1250.0:
		var c := _crest(z, start.x - 2400.0, start.x - 1100.0)
		for d: float in [500.0, 750.0, 1000.0, 1250.0, 1500.0]:
			var x := c.x + d
			if x > start.x - 50.0:
				continue
			for a: float in [10.0, 30.0, 60.0, 100.0, 150.0]:
				pts.append(Vector3(x, _h(x, z) + a, z))
				tags.append({"z": z, "downwind_m": d, "agl_m": a, "crest_x": c.x, "crest_h": c.y})
		z += 250.0
	var acc := await _snapshots(pts)
	var rows: Array = []
	for i in pts.size():
		rows.append([pts[i].x, pts[i].y, pts[i].z, acc[i][0], acc[i][1], acc[i][2], acc[i][3], acc[i][4], tags[i]])
	return {"rows": rows}


func _landing() -> Dictionary:
	var cfg: Dictionary = Config.get_config("locations/" + LOC)
	var out := {}
	for ls: Dictionary in cfg.landing_sites:
		var p2: Vector2 = _terrain.call("latlon_to_local", float(ls.lat), float(ls.lon))
		var pts: Array[Vector3] = []
		for a: float in [10.0, 30.0, 60.0]:
			pts.append(Vector3(p2.x, _h(p2.x, p2.y) + a, p2.y))
		var acc := await _snapshots(pts)
		var r: Array = []
		for i in pts.size():
			r.append({"agl": pts[i].y - _h(p2.x, p2.y), "u": acc[i][0], "w": acc[i][1], "v": acc[i][2],
				"h_ms": Vector2(acc[i][0], acc[i][2]).length()})
		out[String(ls.id)] = r
	return out


func _field() -> Object:
	return _air.get("field")


func _th_info(th: Object, start: Vector3) -> Dictionary:
	var src: Vector3 = th.get("src")
	var out := {"id": th.get("id"), "src": [src.x, src.y, src.z], "cls": int(_terrain.call("surface_at", src.x, src.z)),
		"strength": th.get("strength"), "radius": th.get("radius"), "top": th.get("top"), "env": th.get("env"),
		"static": th.get("is_static"), "d_start": Vector2(src.x - start.x, src.z - start.z).length(), "air": false}
	# Термик из поля (AirThermals): столбец источника, поток тепла столбца и шаг уровня.
	var f := _field()
	var air_ia := int(f.get_script().get_script_constant_map().get("_AIR_IA", 1 << 20))
	var cell: Vector2i = th.get("cell")
	var asrc: Object = f.get("air_src")
	if cell.x >= air_ia and asrc != null:
		out.air = true
		var v: Variant = asrc.get("index").get(Vector2i(cell.x - air_ia, cell.y))
		if v != null:
			var c: int = asrc.get("col")[int(v)]
			out["col_heat"] = asrc.get("col_heat")[c]
			out["col_phi"] = asrc.get("phi")[c]
			out["level_dx"] = asrc.get("level").get("dx")
			out["src_sun"] = float(_terrain.call("thermal_source_strength_at", src.x, src.z))
	return out


## Термики: снимки раз в 60 с за 15 мин — все термики поля (класс земли источника) и w на оси в ядре
## (300–1200 м над землёй, ниже верха), затем вылеты кружения.
func _thermals(start: Vector3) -> Dictionary:
	var seen := {}
	var cores: Array = []
	var t_begin: float = _air.get("time_s")
	for k in 16:
		if k > 0:
			await _advance(60.0)
		var f := _field()
		var all: Dictionary = f.get("thermals")
		for id in all:
			var th: Object = all[id]
			var info := _th_info(th, start)
			if not seen.has(id):
				seen[id] = info
			if float(info.d_start) > THERMAL_R or float(th.get("env")) < 0.5:
				continue
			for a in CORE_AGL:
				var y := float(th.get("src").y) + a
				if y > float(th.get("top")) - 50.0:
					continue
				var ax: Vector2 = th.call("axis_at", y)
				var gy := _h(ax.x, ax.y)
				var p := Vector3(ax.x, gy + a, ax.y)
				var v: Vector3 = _air.call("air_velocity_at", p)
				cores.append({"snap": k, "id": id, "agl": a, "w": v.y, "cls": info.cls, "strength": th.get("strength"),
					"env": th.get("env")})
	var flights: Array = []
	var nf := int(_a.get("climb-flights", 3))
	for i in nf:
		flights.append(await _climb_flight(start, i))
	return {"t_begin": t_begin, "thermals": seen.values(), "cores": cores, "flights": flights,
		"cloudbase_msl": _air.call("get_cloudbase_msl")}


## Поляра sport (эталонная масса): снижение при скорости v, км/ч.
func _sink(v_kmh: float) -> float:
	var w: Dictionary = Config.get_config("wings/sport")
	var pts: Array = w.polar.points_kmh_ms
	for j in pts.size() - 1:
		if v_kmh <= float(pts[j + 1][0]):
			var t := clampf((v_kmh - float(pts[j][0])) / (float(pts[j + 1][0]) - float(pts[j][0])), 0.0, 1.0)
			return lerpf(float(pts[j][1]), float(pts[j + 1][1]), t)
	return float(pts[-1][1])


## Простой пилот: со старта к лучшему термику (сила × огибающая × exp(−d/1,5 км)), кружение радиуса R вокруг
## оси на своей высоте (крен 30°, ~40 км/ч), выход — если за 60 с набор < 0,2 м/с или у верха; ≤ 15 мин,
## касание земли — конец. Воздух — Atmosphere.air_velocity_at без болтанки; планер сносится ветром.
func _climb_flight(start: Vector3, n: int) -> Dictionary:
	if n > 0:
		await _advance(300.0)
	var phi := deg_to_rad(BANK_DEG)
	var vc := CIRCLE_V_KMH / 3.6 / sqrt(cos(phi))
	var sink_c := _sink(vc * 3.6) / pow(cos(phi), 1.5)
	var R := vc * vc / (9.81 * tan(phi))
	var vg := GLIDE_V_KMH / 3.6
	var sink_g := _sink(GLIDE_V_KMH)
	# Взлёт: 60 м по курсу старта со снижением по лучшему качеству (разбег и отрыв не моделируются).
	var hd := deg_to_rad(float(_game.get("_start_heading")))
	var p := start + Vector3(sin(hd), 0.0, -cos(hd)) * 60.0 + Vector3(0.0, -60.0 * sink_g / vg, 0.0)
	var t := 0.0
	var max_gain := 0.0
	var target: Object = null
	var theta := 0.0
	var hist: Array = []
	var trace: Array = []
	var circ_t := 0.0
	var tried := {}
	var dt := STEP_DT
	var end := "time"
	var steps := 0
	while t < CLIMB_S:
		# Сначала — от склона по курсу старта (300 м), потом к термикам.
		var clear := Vector2(p.x - start.x, p.z - start.z).length() > 300.0
		if clear and (target == null or not is_instance_valid(target) or float(target.get("env")) <= 0.0):
			target = _pick(p, tried)
			circ_t = 0.0
			hist.clear()
		var v_air: Vector3 = _air.call("air_velocity_at", p)
		var vz := v_air.y
		var hv := Vector2(v_air.x, v_air.z)
		if target != null:
			var ax: Vector2 = target.call("axis_at", p.y)
			var d := Vector2(ax.x - p.x, ax.y - p.z)
			if d.length() > R * 1.5 and circ_t == 0.0:
				var dir := d.normalized()
				var step := dir * vg * dt + hv * dt
				p.x += step.x
				p.z += step.y
				vz -= sink_g
			else:
				circ_t += dt
				theta += vc / R * dt
				p.x = ax.x + R * cos(theta)
				p.z = ax.y + R * sin(theta)
				vz -= sink_c
				hist.append(vz)
				if hist.size() > int(60.0 / dt):
					hist.pop_front()
					var mean := 0.0
					for q: float in hist:
						mean += q / hist.size()
					if mean < 0.2 or p.y > float(target.get("top")) - 30.0:
						tried[target.get("id")] = true
						trace.append({"t": t, "leave": target.get("id"), "y": p.y, "mean60": mean})
						target = null
		else:
			var fw := Vector2(sin(hd), -cos(hd)) if not clear else Vector2.ZERO
			p.x += (fw.x * vg + hv.x) * dt
			p.z += (fw.y * vg + hv.y) * dt
			vz -= sink_g
		p.y += vz * dt
		max_gain = maxf(max_gain, p.y - start.y)
		_marker.global_position = p
		_air.call("step", dt)
		t += dt
		steps += 1
		if steps % 40 == 0:
			await get_tree().process_frame
		if steps % int(30.0 / dt) == 0:
			trace.append({"t": t, "y": snappedf(p.y, 0.1), "agl": snappedf(p.y - _h(p.x, p.z), 0.1),
				"target": target.get("id") if target != null else -1})
		if p.y - _h(p.x, p.z) < 2.0:
			end = "ground"
			break
	return {"max_gain_m": max_gain, "end": end, "t_end": t, "R_m": R, "sink_circle_ms": sink_c,
		"sink_glide_ms": sink_g, "log": trace}


func _pick(p: Vector3, tried: Dictionary) -> Object:
	var best: Object = null
	var best_s := 0.0
	var all: Dictionary = _field().get("thermals")
	for id in all:
		if tried.has(id):
			continue
		var th: Object = all[id]
		if float(th.get("env")) < 0.3 or float(th.get("top")) < p.y + 150.0:
			continue
		var ax: Vector2 = th.call("axis_at", p.y)
		var d := Vector2(ax.x - p.x, ax.y - p.z).length()
		if d > 3000.0 or not _reachable(p, ax, d):
			continue
		var s := float(th.get("strength")) * float(th.get("env")) * exp(-d / 1500.0)
		if s > best_s:
			best_s = s
			best = th
	return best


## Долетит ли по прямой с лучшим качеством поляры с запасом 30 м над рельефом (без ветра).
func _reachable(p: Vector3, ax: Vector2, d: float) -> bool:
	var ld := GLIDE_V_KMH / 3.6 / _sink(GLIDE_V_KMH)
	var n := int(ceil(d / 50.0))
	for k in range(1, n + 1):
		var f := float(k) / n
		var x := lerpf(p.x, ax.x, f)
		var z := lerpf(p.z, ax.y, f)
		if p.y - d * f / ld < _h(x, z) + 30.0:
			return false
	return true


func _shoot(path: String) -> Image:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_jpg(path, 0.88)
	print("shot: ", path)
	return img


## Доля пикселей, отличающихся от кадра без слоя больше чем на 0,15 по любому каналу (шаг 4 пикселя).
func _diff(a: Image, b: Image) -> float:
	if a == null or b == null or a.get_size() != b.get_size():
		return -1.0
	var n := 0
	var k := 0
	for y in range(0, a.get_height(), 4):
		for x in range(0, a.get_width(), 4):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			n += 1
			if maxf(absf(ca.r - cb.r), maxf(absf(ca.g - cb.g), absf(ca.b - cb.b))) > 0.15:
				k += 1
	return float(k) / maxf(n, 1)


func _place_cam(pos: Vector3, look: Vector3) -> void:
	if _cam == null:
		_cam = Camera3D.new()
		_cam.far = 60000.0
		_cam.fov = 60.0
		add_child(_cam)
	_cam.global_position = pos
	_cam.look_at(look, Vector3.UP)
	_cam.current = true


## F3 — вид со старта (позади и выше, по курсу старта); F6 — сверху-сбоку на зону.
func _shots(dir: String, start: Vector3) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	var site := String(_a.get("site", ""))
	var hd := deg_to_rad(float(_game.get("_start_heading")))
	var fwd := Vector3(sin(hd), 0.0, -cos(hd))
	var wfd: Node = _game.get_node_or_null("WindFieldDebug")
	if wfd != null:
		wfd.set("radius_m", 1600.0)
	var raw := String(_a.get("raw", ""))
	var raw3: Image = null
	var raw6: Image = null
	_place_cam(start - fwd * 500.0 + Vector3.UP * 260.0, start + fwd * 900.0)
	if raw != "":  # тот же вид без слоя — для числовой проверки, что слой на кадре есть
		DirAccess.make_dir_recursive_absolute(raw)
		await _wait(4.0)
		raw3 = await _shoot(raw.path_join(site + "_f3_raw.jpg"))
	if wfd != null:
		wfd.call("_toggle")
	await _wait(4.0)
	var f3: Image = await _shoot(dir.path_join(site + "_f3.jpg"))
	if wfd != null:
		wfd.call("_toggle")
	var ov: Object = _game.get("debug_overlays")
	var side := fwd.cross(Vector3.UP)
	var zone := start + fwd * 1500.0
	_place_cam(zone - side * 3500.0 - fwd * 1500.0 + Vector3.UP * 1600.0, zone)
	if raw != "":
		await _wait(4.0)
		raw6 = await _shoot(raw.path_join(site + "_f6_raw.jpg"))
	ov.call("toggle_thermals")
	await _wait(4.0)
	var f6: Image = await _shoot(dir.path_join(site + "_f6.jpg"))
	if raw != "":
		var fo := FileAccess.open(raw.path_join(site + "_frames.json"), FileAccess.WRITE)
		fo.store_string(JSON.stringify({"f3_overlay_frac": _diff(raw3, f3), "f6_overlay_frac": _diff(raw6, f6)}))
		fo.close()
