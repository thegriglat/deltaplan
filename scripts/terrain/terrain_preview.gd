extends Node3D
## Тестовая сцена рельефа: камера на стартовой площадке смотрит вдоль склона.
## Аргументы (после --):
##   --location=<id>    локация (configs/locations/<id>.json), по умолчанию из сцены
##   --site=<id>        площадка (по умолчанию первая); --landing — камера над первой посадкой
##   --agl=<м>          поднять камеру над стартом
##   --yaw=<град>       добавка к курсу площадки
##   --pitch=<град>     наклон взгляда
##   --pos=x,y,z --look=x,y,z  произвольная камера
##   --latlon=<lat>,<lon> [--size_km=N]  рантайм-загрузка рельефа вокруг точки (FR-17)
##   --shot=<файл.png>  снять кадр и выйти
##   --shot-series=N[,интервал_с]  с --shot: N кадров через интервал (по умолчанию 1 с),
##                      файлы <файл>_0.png … (проверка бегущих волн ветра по траве)
##   --bench            пролёт камеры вдоль курса, вывод FPS и выход
##   --bench-static=N   N кадров неподвижно, печать JSON {gpu_ms_mean, gpu_ms_p95, n} и выход (T01)
##   --clearings        построить и применить маску просек (WorldClearings.build_for) для location
##   --no-trees, --no-shadows, --no-grass  отключить деревья / тени / траву (замер цены)
##   --wind=<км/ч>,<откуда°>  ветер для колыхания травы; --thermal=x,z,радиус,м/с — термик
##   --gusts[=<м/с>]    фейковая порывистость воздуха (air_fn, T05) — амплитуда пятен то растёт,
##                      то стихает, чтобы проверить усиление колыхания при порывистости
##   --inversion=<м>    высота инверсии (верх дымки = она + haze.top_margin_m), --no-haze
## Управление: WASD, Q/E, Shift, правая кнопка мыши — обзор.

var _args := {}
var _frames := 0
var _cfg: Dictionary
var _yaw := 0.0
var _pitch := 0.0
var _bench_t := 0.0
var _bench_frames := 0
var _bench_worst_ms := 0.0
var _bench_gpu_ms := 0.0
var _bench_static_samples: Array[float] = []
var _series_i := 0
var _series_t := 0.0

@onready var terrain: Terrain = $Terrain
@onready var cam: Camera3D = $Camera3D


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var kv := a.substr(2).split("=", true, 1)
			_args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	_cfg = Config.get_config("world").get("preview", {})
	SkyEnvironment.setup_camera(cam)
	cam.fov = float(_cfg.fov_deg)
	if _args.has("location") and String(_args.location) != terrain.location_id:
		terrain.load_location(String(_args.location))
	if _args.has("latlon"):
		var ll := String(_args.latlon).split(",")
		_frames = -100000  # не снимать, пока грузится
		await terrain.load_location_latlon(
			float(ll[0]), float(ll[1]), float(_args.get("size_km", "-1"))
		)
		_frames = 0
	terrain.wait_relief()  # поля рельефа (влажность, AO, тень) считаются в фоне — для кадров ждём
	terrain.renderer.lod_camera = cam
	_place_camera()
	for n: Node3D in [terrain.trees, terrain.impostors]:
		if _args.has("no-trees") and n != null:
			n.process_mode = Node.PROCESS_MODE_DISABLED
			n.visible = false
	_setup_wind()
	terrain.set_pilot(cam)
	if _args.has("clearings") and terrain.location_id != "":
		var c := WorldClearings.build_for(terrain.location_id)
		if c != null:
			terrain.set_clearings(c.image, c.origin, c.cell_m)
	RockScatter.attach(terrain, cam)
	ShrubScatter.attach(terrain, cam)
	if _args.has("no-grass") and terrain.grass != null:
		terrain.grass.process_mode = Node.PROCESS_MODE_DISABLED
		terrain.grass.visible = false
	var env := $Environment as SkyEnvironment
	if _args.has("no-shadows"):
		env.sun.shadow_enabled = false
	if _args.has("inversion"):
		env.set_inversion_height_msl(float(_args.inversion))
	if _args.has("no-haze") and env.haze != null:
		env.haze.visible = false
	if _args.has("bench") or _args.has("bench-static"):
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	print(
		(
			"Terrain preview: загрузка %.2f с, чанков %d"
			% [terrain.last_load_time_s, terrain.renderer.chunk_count()]
		)
	)


## Ветер и термик для проверки колыхания (в игре их даёт Atmosphere).
func _setup_wind() -> void:
	var w := Vector3.ZERO
	if _args.has("wind"):
		var p := String(_args.wind).split(",")
		var from := TerrainGeo.heading_vector(float(p[1]))
		w = -from * float(p[0]) / 3.6
	var th: Array[Dictionary] = []
	if _args.has("thermal"):
		var q := String(_args.thermal).split(",")
		var x := float(q[0])
		var z := float(q[1])
		(
			th
			. append(
				{
					"source": Vector3(x, terrain.height_at(x, z), z),
					"radius_m": float(q[2]),
					"strength_ms": float(q[3]),
					"envelope": 1.0,
				}
			)
		)
	var air_fn := Callable()
	if _args.has("gusts"):
		var gust_amp := float(_args.gusts) if String(_args.gusts) != "1" else 3.0
		var cross := (
			Vector3(-w.z, 0.0, w.x).normalized() if w != Vector3.ZERO else Vector3(1.0, 0.0, 0.0)
		)
		air_fn = func(_pos: Vector3) -> Vector3:
			var s := 0.5 + 0.5 * sin(Time.get_ticks_msec() / 1000.0 * 0.4)
			return w + cross * gust_amp * s
	terrain.set_wind_sources(
		func(_pos: Vector3) -> Vector3: return w,
		func(_pos: Vector3, _r: float) -> Array[Dictionary]: return th,
		air_fn
	)


func _place_camera() -> void:
	var sites := terrain.get_start_sites()
	var site: Dictionary = sites[0]
	for s in sites:
		if s.id == _args.get("site", ""):
			site = s
	_yaw = float(site.heading_deg) + float(_args.get("yaw", "0"))
	_pitch = float(_args.get("pitch", str(_cfg.pitch_deg)))
	var p: Vector3 = (
		site.position + Vector3.UP * (float(_cfg.eye_height_m) + float(_args.get("agl", "0")))
	)
	cam.global_position = p
	_apply_rot()
	var lands := terrain.get_landing_sites()
	if _args.has("landing") and not lands.is_empty():
		cam.global_position = (
			(lands[0].position as Vector3)
			+ Vector3.UP * (float(_cfg.eye_height_m) + float(_args.get("agl", "0")))
		)
	if _args.has("pos"):
		cam.global_position = _vec(_args.pos)
	if _args.has("look"):
		cam.look_at(_vec(_args.look))
		_yaw = rad_to_deg(-cam.rotation.y)
		_pitch = rad_to_deg(cam.rotation.x)
	print(
		(
			"Камера: %s, земля %.0f м, курс %.0f°"
			% [
				cam.global_position,
				terrain.height_at(cam.global_position.x, cam.global_position.z),
				_yaw
			]
		)
	)


func _apply_rot() -> void:
	cam.rotation = Vector3(deg_to_rad(_pitch), deg_to_rad(-_yaw), 0.0)


func _vec(s: String) -> Vector3:
	var p := s.split(",")
	return Vector3(float(p[0]), float(p[1]), float(p[2]))


func _process(delta: float) -> void:
	_frames += 1
	if _frames < 0:
		return
	if _args.has("bench"):
		_bench(delta)
		return
	if _args.has("bench-static"):
		_bench_static()
		return
	if _args.has("shot") and _args.has("shot-series"):
		_shot_series(delta)
		return
	if _args.has("shot") and _frames == int(_cfg.shot_delay_frames):
		var img := get_viewport().get_texture().get_image()
		img.save_png(String(_args.shot))
		print("Скриншот: ", _args.shot)
		get_tree().quit()
		return
	var v := Vector3(
		(
			Input.get_axis(&"ui_left", &"ui_right")
			+ float(Input.is_key_pressed(KEY_D))
			- float(Input.is_key_pressed(KEY_A))
		),
		float(Input.is_key_pressed(KEY_E)) - float(Input.is_key_pressed(KEY_Q)),
		float(Input.is_key_pressed(KEY_S)) - float(Input.is_key_pressed(KEY_W))
	)
	if v != Vector3.ZERO:
		var speed := float(_cfg.fly_speed_ms) * (5.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0)
		cam.global_position += cam.global_basis * v.normalized() * speed * delta
		var ground := terrain.height_at(cam.global_position.x, cam.global_position.z)
		cam.global_position.y = maxf(cam.global_position.y, ground + 1.0)


## Серия кадров через равные промежутки времени (--shot-series=N[,интервал_с]).
func _shot_series(delta: float) -> void:
	if _frames < int(_cfg.shot_delay_frames):
		return
	var p := String(_args["shot-series"]).split(",")
	var n := int(p[0])
	var interval := float(p[1]) if p.size() > 1 else 1.0
	_series_t -= delta
	if _series_t > 0.0:
		return
	_series_t += interval
	var f := String(_args.shot).get_basename() + "_%d.png" % _series_i
	get_viewport().get_texture().get_image().save_png(f)
	print("Скриншот: ", f)
	_series_i += 1
	if _series_i >= n:
		get_tree().quit()


func _bench(delta: float) -> void:
	if _frames < 10:
		return
	_bench_t += delta
	_bench_frames += 1
	_bench_worst_ms = maxf(_bench_worst_ms, delta * 1000.0)
	_bench_gpu_ms += RenderingServer.viewport_get_measured_render_time_gpu(
		get_viewport().get_viewport_rid()
	)
	cam.global_position += -cam.global_basis.z * float(_cfg.bench_speed_ms) * delta
	if _bench_t >= float(_cfg.bench_duration_s):
		print(
			(
				(
					"BENCH: средний FPS %.1f, GPU %.2f мс/кадр, худший кадр %.1f мс, LOD %s, "
					+ "примитивов %d, draw calls %d"
				)
				% [
					_bench_frames / _bench_t,
					_bench_gpu_ms / _bench_frames,
					_bench_worst_ms,
					terrain.renderer.lod_histogram(),
					RenderingServer.get_rendering_info(
						RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME
					),
					RenderingServer.get_rendering_info(
						RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME
					)
				]
			)
		)
		get_tree().quit()


## Замер GPU на неподвижной камере (T01): N кадров после разгона, среднее и 95-й перцентиль.
func _bench_static() -> void:
	if _frames < 10:
		return
	_bench_static_samples.append(
		RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid())
	)
	if _bench_static_samples.size() >= int(_args["bench-static"]):
		var arr := _bench_static_samples.duplicate()
		arr.sort()
		var mean := 0.0
		for v in arr:
			mean += v
		mean /= arr.size()
		var p95_i := clampi(ceili(0.95 * arr.size()) - 1, 0, arr.size() - 1)
		var res := {
			"gpu_ms_mean": mean,
			"gpu_ms_p95": arr[p95_i],
			"gpu_ms_p10": arr[int(0.1 * arr.size())],
			"n": arr.size(),
			"w": get_viewport().size.x,
		}
		print("BENCH_STATIC_JSON:" + JSON.stringify(res))
		get_tree().quit()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		var k := float(_cfg.mouse_sensitivity_deg)
		_yaw += event.relative.x * k
		_pitch = clampf(_pitch - event.relative.y * k, -89.0, 89.0)
		_apply_rot()
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		get_tree().quit()
