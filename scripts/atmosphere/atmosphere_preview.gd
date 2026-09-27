extends Node3D
## Тестовая сцена атмосферы: плоская земля, небо, облака над термиками.
## Запуск: godot --path . res://scenes/atmosphere/atmosphere_preview.tscn [-- параметры]
## (atmosphere_terrain_preview.tscn — то же над реальным рельефом «Алтай», ракурсы launch/high)
##   --weather=weak|medium|strong   пресет (по умолчанию medium)
##   --view=horizon|under|side|top|near   ракурс
##   --time=<с>                     время атмосферы (по умолчанию 3600)
##   --shot=<путь.png>              сохранить кадр и выйти
##   --wind=<км/ч>                  ветер
## Управление: WASD/QE — полёт, правая кнопка мыши — обзор, Shift — быстрее, 1..5 — ракурсы,
## T — время +60 с.

var _shot := ""
var _frames := 0
var _view := "horizon"
var _yaw := 0.0
var _pitch := 0.0
var _args: Dictionary = {}
## Стартовая площадка (при реальном рельефе): {position, heading_deg, ...}.
var _site: Dictionary = {}
## Замер: GPU-время кадра с облаками и без (--bench).
var _bench_on: Array[float] = []
var _bench_off: Array[float] = []

@onready var atmo: Atmosphere = $Atmosphere
@onready var cam: Camera3D = $Camera3D


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var kv := a.substr(2).split("=", true, 1)
			_args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	atmo.set_weather("weather/" + String(_args.get("weather", "medium")))
	if _args.has("cirrus"):
		atmo.weather.cirrus_cover = float(_args.cirrus)
	if _args.has("wind"):
		atmo.set_wind(float(_args.wind), float(atmo.weather.wind_from_deg))
	# Рельеф — чужой модуль: без статического типа, чтобы превью не зависело от его компиляции.
	var terrain := get_node_or_null("Terrain")
	if terrain != null and terrain.has_method("height_at"):
		# Реальный рельеф (сцена atmosphere_terrain_preview.tscn): термики от солнечных склонов.
		atmo.set_ground(
			Callable(terrain, "height_at"),
			Callable(terrain, "thermal_source_strength_at")
			if terrain.has_method("thermal_source_strength_at")
			else Callable(terrain, "sun_exposure_at"),
			Callable(terrain, "surface_at") if terrain.has_method("surface_at") else Callable()
		)
		atmo.set_sun_direction(terrain.call("sun_direction"))
		var sites: Array = terrain.call("get_start_sites")
		if not sites.is_empty():
			_site = sites[0]
	elif String(_args.get("ground", "")) == "ridge":
		# Хребет поперёк западного ветра (для волны): гребень вдоль Z на x = 0.
		atmo.set_ground(_ridge_h, func(_x: float, _z: float) -> float: return 0.8)
		_make_ridge_mesh()
	else:
		atmo.set_ground(
			func(_x: float, _z: float) -> float: return 0.0,
			func(x: float, z: float) -> float: return 0.75 + 0.25 * sin(x / 1300.0) * cos(z / 1700.0)
		)
	atmo.time_s = float(_args.get("time", "3600"))
	var origin: Vector3 = _site.get("position", Vector3.ZERO)
	atmo.set_focus(origin)
	atmo.step(0.0)
	_view = String(_args.get("view", "horizon"))
	if _view == "stages":
		_make_stages()
	elif _view in ["cb", "cbnear", "cbfar"]:
		_make_cb()
	elif _view == "dust":
		_make_dust()
	_shot = String(_args.get("shot", ""))
	if _shot != "":
		# Одинаковый кадр для скриншотов (оконный менеджер может выдать любое окно).
		get_window().mode = Window.MODE_WINDOWED
		get_window().size = Vector2i(1280, 720)
	_set_view(_view)
	if _args.has("bench"):
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		get_window().mode = Window.MODE_WINDOWED
		get_window().size = Vector2i(1920, 1080)
		RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)



func _bench_frame(layer: CloudLayer) -> void:
	if _frames < 20:
		return
	var gpu := RenderingServer.viewport_get_measured_render_time_gpu(
		get_viewport().get_viewport_rid()
	)
	if _frames < 140:
		_bench_on.append(gpu)
	elif _frames == 140:
		layer.visible = false
		if layer._effect != null:
			layer._effect.enabled = false
	elif _frames > 150 and _frames < 270:
		_bench_off.append(gpu)
	elif _frames >= 270:
		var on := 0.0
		for v in _bench_on:
			on += v
		var off := 0.0
		for v in _bench_off:
			off += v
		on /= _bench_on.size()
		off /= _bench_off.size()
		var n_th := atmo.field.thermals.size()
		print("CPU выбор облаков: %d мкс, термиков %d" % [layer.last_rebuild_us, n_th])
		print(
			(
				"BENCH %s %s: GPU кадр с облаками %.2f мс, без %.2f мс, облака %.2f мс (%dx%d)"
				% [
					_view,
					String(_args.get("weather", "medium")),
					on,
					off,
					on - off,
					get_viewport().size.x,
					get_viewport().size.y
				]
			)
		)
		get_tree().quit()


## Ряд статичных облаков в разных стадиях: зарождение, рост, зрелость, начало распада, распад.
func _make_stages() -> void:
	atmo.set_thermal_mode("static")
	atmo.set_wind(5.0, 270.0)
	var layer := atmo.get_node_or_null("Clouds") as CloudLayer
	var stages := [
		Vector3(0.15, 0, 0.5),
		Vector3(0.5, 0, 1),
		Vector3(1, 0, 1),
		Vector3(1, 0.35, 0.3),
		Vector3(1, 0.75, 0)
	]
	for i in stages.size():
		var id := atmo.add_static_thermal(-3600.0 + i * 1800.0, -4000.0, 4.0, 100.0)
		if layer != null:
			layer.model.stage_override[id] = stages[i]
	atmo.step(0.0)


## Зрелое облако среднего размера из тех, что реально рисуются (после слияния наложившихся).
static func _ridge_h(x: float, z: float) -> float:
	var ridge := 1100.0 * exp(-pow(x / 2200.0, 2.0)) * (0.8 + 0.2 * cos(z / 5000.0))
	return 300.0 + ridge


## Сетка рельефа хребта (60 × 60 км) — только для превью волны.
func _make_ridge_mesh() -> void:
	var ground := get_node_or_null("Ground") as MeshInstance3D
	if ground != null:
		ground.visible = false
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := 160
	var size := 60000.0
	var cell := size / n
	for j in n:
		for i in n:
			var x0 := -size * 0.5 + i * cell
			var z0 := -size * 0.5 + j * cell
			var q := [Vector3(x0, 0, z0), Vector3(x0 + cell, 0, z0),
				Vector3(x0 + cell, 0, z0 + cell), Vector3(x0, 0, z0 + cell)]
			for k in [0, 1, 2, 0, 2, 3]:
				var v: Vector3 = q[k]
				st.add_vertex(Vector3(v.x, _ridge_h(v.x, v.z), v.z))
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.35, 0.42, 0.28)
	mat.roughness = 1.0
	mi.material_override = mat
	add_child(mi)


## Молодой сильный термик с пылевым вихрем в 600 м от камеры.
func _make_dust() -> void:
	atmo.weather.dust_devil_chance = 1.0
	var dd := atmo.get_node_or_null("DustDevils") as DustDevils
	if dd != null:
		dd.model.setup(atmo.cfg.dust, atmo.weather)
	for k in 3:
		var id := atmo.add_static_thermal(600.0 + k * 350.0, -600.0 - k * 500.0, 4.5 - k * 0.6, 120.0)
		var th: AtmoThermal = atmo.field.thermals[id]
		th.is_static = false
		th.t_grow = 400.0
		th.t_mature = 600.0
		th.t_decay = 200.0
		# Момент жизни вихря: перебираем рождение так, чтобы вихрь был в середине жизни.
		for b in 400:
			th.t_birth = atmo.time_s - b
			var d := dd.model.devil(th, atmo.time_s, Callable(), Vector2.ZERO) if dd else {}
			if not d.is_empty() and float(d.age) > 0.35 and float(d.age) < 0.6:
				break
	atmo.step(1.0)


## Зрелый Cb в разгаре бури к северу — наковальня, вирга, фронт порывов.
func _make_cb() -> void:
	var id := atmo.add_static_thermal(14000.0, -9000.0, 4.5, 150.0)
	var th: AtmoThermal = atmo.field.thermals[id]
	th.is_cb = true
	th.suck = 0.4
	th.overdevelop = 1.0
	th.cloud_depth = float(atmo.weather.get("cb_top_above_base_m", 8000.0))
	th.t_birth = atmo.time_s - 3500.0
	th.t_grow = 300.0
	th.t_mature = 4000.0
	th.t_decay = 600.0
	atmo.step(1.0)


func _strongest_cloud(max_dist: float) -> AtmoThermal:
	var layer := atmo.get_node_or_null("Clouds") as CloudLayer
	if layer == null:
		return null
	var best: AtmoThermal = null
	var best_score := -1.0
	for e: Array in layer.model.select(atmo.field.thermals, atmo.time_s, Vector3.ZERO):
		var th: AtmoThermal = e[1]
		var st: Vector3 = e[2]
		var c: Vector2 = e[3]
		if st.x < 0.8 or st.y > 0.1 or c.length() > max_dist:
			continue
		# Ближе к типичному размеру (~1,2 км) — лучше для показа.
		var score := 1.0 / (1.0 + absf(float(e[4]) - 600.0))
		if score > best_score:
			best_score = score
			best = th
	return best


func _set_view(v: String) -> void:
	var cb := atmo.get_cloudbase_msl()
	var th := _strongest_cloud(6000.0)
	var layer := atmo.get_node_or_null("Clouds") as CloudLayer
	var c := Vector2.ZERO
	if th != null and layer != null:
		c = layer.model.center(th, atmo.time_s)
	var o: Vector3 = _site.get("position", Vector3.ZERO)
	if not _site.is_empty() and v in ["horizon", "launch", "high"]:
		# С площадки вдоль курса старта: облака над горами.
		var hd := deg_to_rad(float(_site.get("heading_deg", 0.0)))
		var fwd := Vector3(sin(hd), 0.0, -cos(hd))
		var up := 30.0 if v != "high" else 900.0
		_place(o + Vector3(0, up, 0), o + fwd * 8000.0 + Vector3(0, cb - o.y, 0) * 0.6)
		return
	match v:
		"under":
			_place(Vector3(c.x - 500, cb - 250, c.y + 300), Vector3(c.x, cb + 100, c.y))
		"side":
			_place(Vector3(c.x - 2500, cb + 50, c.y + 1200), Vector3(c.x, cb + 250, c.y))
		"top":
			_place(Vector3(-6000, cb + 3500, 6000), Vector3(0, 0, -2000))
		"birds":
			# Рядом с сильным термиком на высоте птиц.
			var bf := atmo.get_node_or_null("Birds") as BirdFlock
			if bf != null:
				bf._choose_flocks()
				if not bf._flocks.is_empty():
					bf._place_birds()
					var bp := bf._mm.get_instance_transform(0).origin
					var bt: AtmoThermal = bf._flocks[0][0]
					var ax := bt.axis_at(bp.y)
					_place(Vector3(ax.x - 45, bp.y - 45, ax.y + 30), Vector3(ax.x, bp.y, ax.y))
					print(
						"birds: камера ",
						cam.position,
						" птица ",
						bp,
						" птиц ",
						bf._mm.instance_count
					)
		"cb":
			# Солнце сбоку-сзади (азимут 200°): объём башни виден по светотени.
			_place(Vector3(0, 700, 0), Vector3(14000, 4500, -9000))
		"cbfar":
			_place(Vector3(-30000, 400, 24000), Vector3(14000, 4000, -9000))
		"cbnear":
			_place(Vector3(8000, 1500, -3000), Vector3(14000, 4000, -9000))
		"dust":
			_place(Vector3(250, 15, -150), Vector3(700, 70, -700))
		"wave":
			# С подветренной стороны хребта вдоль ветра — лентикуляры в гребнях волн.
			_place(Vector3(26000, 1700, 10000), Vector3(6000, 3600, -2000))
			for cr: Dictionary in atmo.wave.crests(Vector3(10000, 0, 0), 20000.0, 60.0):
				print("гребень волны ", cr.pos, " η ", cr.eta)
		"stages":
			_place(Vector3(0, cb - 450, 0), Vector3(0, cb + 350, -4000))
		"sun":
			# Против солнца: серебристая кайма.
			_place(Vector3(c.x + 1800, cb - 200, c.y - 2200), Vector3(c.x, cb + 350, c.y))
		"near":
			_place(Vector3(c.x - 1200, cb - 120, c.y + 500), Vector3(c.x, cb + 150, c.y))
		_:
			_place(Vector3(0, 900, 0), Vector3(-3000, 1500, -10000))


func _place(pos: Vector3, target: Vector3) -> void:
	cam.position = pos
	cam.look_at(target)
	_yaw = cam.rotation.y
	_pitch = cam.rotation.x


func _process(delta: float) -> void:
	var layer := atmo.get_node_or_null("Clouds") as CloudLayer
	if layer == null or layer.textures_ready():
		_frames += 1
	if _args.has("bench") and layer != null:
		_bench_frame(layer)
		return
	if _shot != "" and _frames == 30:
		var img := get_viewport().get_texture().get_image()
		img.save_png(_shot)
		var bfl := atmo.get_node_or_null("Birds") as BirdFlock
		if bfl != null and bfl._mm.instance_count > 0:
			print("bird0 ", bfl._mm.get_instance_transform(0).origin, " cam ", cam.global_position)
		print(
			"saved ",
			_shot,
			" clouds=",
			atmo.get_node("Clouds").get_child_count() if atmo.has_node("Clouds") else 0
		)
		get_tree().quit()
	var speed := 400.0 if Input.is_key_pressed(KEY_SHIFT) else 80.0
	var mv := Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		mv.z -= 1
	if Input.is_key_pressed(KEY_S):
		mv.z += 1
	if Input.is_key_pressed(KEY_A):
		mv.x -= 1
	if Input.is_key_pressed(KEY_D):
		mv.x += 1
	if Input.is_key_pressed(KEY_E):
		mv.y += 1
	if Input.is_key_pressed(KEY_Q):
		mv.y -= 1
	cam.position += cam.global_transform.basis * mv * speed * delta


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		_yaw -= event.relative.x * 0.004
		_pitch = clampf(_pitch - event.relative.y * 0.004, -1.5, 1.5)
		cam.rotation = Vector3(_pitch, _yaw, 0)
	elif event is InputEventKey and event.pressed:
		var views := ["horizon", "under", "side", "top", "near"]
		if event.keycode >= KEY_1 and event.keycode <= KEY_5:
			_set_view(views[event.keycode - KEY_1])
		elif event.keycode == KEY_T:
			atmo.time_s += 60.0
