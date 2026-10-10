extends Node3D
## Тестовая сцена объектов мира: рельеф + атмосфера + WorldObjects.
##   godot --path . res://scenes/world_objects/world_objects_preview.tscn -- [аргументы]
## Аргументы (после --):
##   --location=<id>  локация (по умолчанию из сцены — altai)
##   --view=start|landing|sock|track   ракурс (по умолчанию start); sock — крупно
##                    конус; track — тропа к старту, вид на склон с 150–400 м (VR-9, тропы старта)
##   --wind=<км/ч> --from=<град>   ветер (по умолчанию из пресета погоды)
##   --weather=weak|medium|strong
##   --time=<с>      подождать, пока ветроуказатели «оживут» (по умолчанию preview.settle_s)
##   --mask=<png>    сохранить маску просек (WorldClearings) локации и выйти
##   --shot=<png>    снять кадр и выйти;  --bench — GPU-время кадра с объектами и без, выход
## Управление: WASD/QE — полёт, Shift — быстрее, ПКМ — обзор, 1–5 — ракурсы.

const VIEWS: PackedStringArray = ["start", "landing", "sock", "track"]

var _args := {}
var _cfg: Dictionary
var _frames := 0
var _elapsed := 0.0
var _yaw := 0.0
var _pitch := 0.0
var _bench := {}

@onready var terrain: Terrain = $Terrain
@onready var atmo: Atmosphere = $Atmosphere
@onready var world: WorldObjects = $WorldObjects
@onready var cam: Camera3D = $Camera3D


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var kv := a.substr(2).split("=", true, 1)
			_args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	_cfg = Config.get_config("world_objects").preview
	SkyEnvironment.setup_camera(cam)
	cam.fov = float(_cfg.fov_deg)
	if _args.has("location") and _args.location != terrain.location_id:
		if Locations.is_builtin(String(_args.location)):
			await terrain.load_builtin(String(_args.location))  # нет в кеше — соберётся (нужна сеть)
		else:
			terrain.load_location(String(_args.location))
	atmo.set_weather("weather/" + String(_args.get("weather", "medium")))
	var from := float(_args.get("from", str(atmo.weather.wind_from_deg)))
	atmo.set_wind(float(_args.get("wind", str(atmo.weather.wind_speed_kmh))), from)
	atmo.set_ground(terrain.height_at, terrain.sun_exposure_at)
	atmo.set_sun_direction(terrain.sun_direction())
	if _args.has("mask"):
		var c := WorldClearings.build_for(terrain.location_id)
		c.image.save_png(String(_args.mask))
		print("Маска просек %s за %.2f с: %s" % [c.image.get_size(), c.build_time_s, _args.mask])
		get_tree().quit()
		return
	world.setup(terrain, atmo)
	terrain.renderer.lod_camera = cam
	_set_view(String(_args.get("view", "start")))
	if _args.has("shot") or _args.has("bench"):
		var sz: Array = _cfg.window_size
		get_window().size = Vector2i(int(sz[0]), int(sz[1]))
	if _args.has("bench"):
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)


func _set_view(view: String) -> void:
	var start: Dictionary = terrain.get_start_sites()[0]
	var landing: Dictionary = (
		world.get_landing_sites()[0] if not world.landing_sites.is_empty() else {}
	)
	var eye := Vector3.ZERO
	var target := Vector3.ZERO
	match view:
		"start":
			var ws := world.indicators[0]
			target = ws.pivot_position()
			var fwd := TerrainGeo.heading_vector(float(start.heading_deg))
			var d := float(_cfg.start_distance_m)
			eye = target - fwd * d + fwd.cross(Vector3.UP) * d * 0.5
			eye.y = terrain.height_at(eye.x, eye.z) + float(_cfg.eye_height_m)
			target = target.lerp(start.position, 0.35)
		"sock":
			# Сбоку от ветра: конус виден в профиль (как на фото для сравнения).
			target = world.indicators[0].pivot_position() + Vector3.DOWN * 1.2
			var wind := atmo.mean_wind_at(target)
			var side := Vector3(-wind.z, 0.0, wind.x).normalized()
			eye = target + side * float(_cfg.sock_distance_m)
			eye.y = target.y
		"track":
			# Камера ниже по склону (по heading_deg — направлению разбега вниз), смотрит на старт:
			# видно склон и тропу, сбегающую вниз к дороге/посёлку (VR-9, тропы старта).
			target = start.position
			var fwd := TerrainGeo.heading_vector(float(start.heading_deg))
			var d := float(_cfg.track_distance_m)
			eye = target + fwd * d + fwd.cross(Vector3.UP) * d * 0.3
			eye.y = terrain.height_at(eye.x, eye.z) + float(_cfg.track_agl_m)
		"landing":
			target = landing.position
			var ax := TerrainGeo.heading_vector(float(landing.axis_deg))
			eye = target - ax * float(_cfg.landing_distance_m)
			eye.y = terrain.height_at(eye.x, eye.z) + float(_cfg.landing_agl_m)
	cam.global_position = eye
	cam.look_at(target)
	_yaw = rad_to_deg(-cam.rotation.y)
	_pitch = rad_to_deg(cam.rotation.x)
	atmo.set_focus(eye)
	print("Вид '%s': камера %s → %s" % [view, eye.round(), target.round()])


func _process(delta: float) -> void:
	_frames += 1
	if _args.has("bench"):
		_run_bench()
		return
	_elapsed += delta
	var settle := float(_args.get("time", str(_cfg.settle_s)))
	if _args.has("shot") and _elapsed >= settle and _frames >= int(_cfg.shot_delay_frames):
		_print_indicators()
		get_viewport().get_texture().get_image().save_png(String(_args.shot))
		print("Скриншот: ", _args.shot)
		get_tree().quit()
		return
	_fly(delta)


func _print_indicators() -> void:
	for ind: WindIndicator in world.indicators.slice(0, 6):
		var m := ind.model
		var air := atmo.air_velocity_at(ind.pivot_position())
		print(
			(
				"%s: воздух %s м/с, скорость %.1f, наполнение %.2f, курс конуса %.0f°, болтание %.2f"
				% [
					ind.name,
					air.snapped(Vector3.ONE * 0.1),
					m.speed_ms,
					m.fill,
					fposmod(rad_to_deg(atan2(m.pointing().x, -m.pointing().z)), 360.0),
					m.flutter_amp
				]
			)
		)


func _fly(delta: float) -> void:
	var v := Vector3(
		float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A)),
		float(Input.is_key_pressed(KEY_E)) - float(Input.is_key_pressed(KEY_Q)),
		float(Input.is_key_pressed(KEY_S)) - float(Input.is_key_pressed(KEY_W))
	)
	if v != Vector3.ZERO:
		var speed := float(_cfg.fly_speed_ms) * (5.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0)
		cam.global_position += cam.global_basis * v.normalized() * speed * delta
		atmo.set_focus(cam.global_position)


## Замер: N кадров с объектами, N без — средний GPU, мс.
func _run_bench() -> void:
	var n := int(_cfg.bench_frames)
	if _frames < 20:
		return
	var gpu := RenderingServer.viewport_get_measured_render_time_gpu(
		get_viewport().get_viewport_rid()
	)
	var phase := "on" if _frames < 20 + n else "off"
	if _frames == 20 + n:
		world.visible = false
	if _frames >= 20 + 2 * n:
		var on := float(_bench.get("on", 0.0)) / n
		var off := float(_bench.get("off", 0.0)) / n
		print(
			(
				"BENCH %s: GPU с объектами %.3f мс, без %.3f мс, разница %.3f мс"
				% [_args.get("view", "start"), on, off, on - off]
			)
		)
		get_tree().quit()
		return
	_bench[phase] = float(_bench.get(phase, 0.0)) + gpu


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		var k := float(_cfg.mouse_sensitivity_deg)
		_yaw += event.relative.x * k
		_pitch = clampf(_pitch - event.relative.y * k, -89.0, 89.0)
		cam.rotation = Vector3(deg_to_rad(_pitch), deg_to_rad(-_yaw), 0.0)
	elif event is InputEventKey and event.pressed:
		if event.keycode >= KEY_1 and event.keycode < KEY_1 + VIEWS.size():
			_set_view(VIEWS[event.keycode - KEY_1])
		elif event.keycode == KEY_ESCAPE:
			get_tree().quit()
