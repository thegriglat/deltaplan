extends Node
## Кадры теней облаков на земле: главная сцена с автостартом и прогнозом из аргументов игры
## (как forecast_shot: --temp= --wind= --hour= --location=), затем виды своей камерой:
## high — 200 м под кромкой, взгляд круто вниз; mid — оттуда же взгляд вдаль вниз;
## low — 40 м над склоном, взгляд на долину; top — 4 км над кромкой, отвесно вниз.
## Интерфейс скрыт. Нужно окно (настоящий рендер):
##   XDG_DATA_HOME=$(mktemp -d) godot --path . --audio-driver Dummy --resolution 1920x1080 \
##     res://tools/shots/cloud_shadow_shot.tscn -- --autostart --bots=0 --temp=26 --wind=3 \
##     --hour=12 --location=ongudai --out=/tmp/cs --tag=before [--wait=20]
## --preset=low|medium|high — пресет графики (пишется во временный профиль!); --gpu=N — после
## каждого вида N кадров замера времени GPU (кадр и карта теней); --no-shadows — без теней облаков.
## Пишет <out>/<tag>_high.png, <tag>_mid.png, <tag>_low.png (и карту теней <tag>_<вид>_map.png).
## Код выхода 0/1.

const MAIN_SCENE := preload("res://scenes/main.tscn")
const TIMEOUT_S := 200.0

var _out := ""
var _tag := "shadow"
var _wait := 20.0
var _gpu_frames := 0
var _main: Node = null
var _game: Game = null


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		var v := kv[1] if kv.size() > 1 else ""
		match kv[0]:
			"--out":
				_out = v
			"--tag":
				_tag = v
			"--wait":
				_wait = float(v)
			"--gpu":
				_gpu_frames = int(v)
			"--preset":
				GraphicsPresets.select(v)
			"--no-shadows":
				UserSettings.save_patch("atmosphere", {"clouds": {"shadows": false}})
				Config.reload()
	if _out == "":
		push_error("cloud_shadow_shot: нужен --out=")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	get_tree().create_timer(TIMEOUT_S, true, false, true).timeout.connect(_fail.bind("таймаут"))
	_run()


func _fail(why: String) -> void:
	print("cloud_shadow_shot: FAIL (%s)" % why)
	await _quit(1)


func _quit(code: int) -> void:
	if is_instance_valid(_main):
		_main.queue_free()
	for i in 2:
		await get_tree().process_frame
	get_tree().quit(code)


func _run() -> void:
	_main = MAIN_SCENE.instantiate()
	add_child(_main)
	for i in 4000:
		if int(_main.get("state")) == 2:  # State.FLYING
			break
		await get_tree().process_frame
	if int(_main.get("state")) != 2:
		_fail("не долетели до FLYING (нужен --autostart)")
		return
	_game = _main.get_node("Game")
	for n in _main.get_node("UI").get_children():
		if n is CanvasItem:
			(n as CanvasItem).visible = false
	_game.overlay.visible = false
	_game.set("_crashed", true)
	await get_tree().create_timer(_wait, true, false, true).timeout
	var cam := Camera3D.new()
	add_child(cam)
	SkyEnvironment.setup_camera(cam)
	cam.current = true
	var start: Dictionary = _game.get_start()
	var sp: Vector3 = start.position
	var fwd := TerrainGeo.heading_vector(float(start.heading_deg))
	cam.fov = 70.0
	# Под кромкой (выше — в облаке): 200 м ниже кромки.
	var cb := float(_game.air.call("get_cloudbase_msl"))
	var hi := cb - sp.y - 200.0
	print(
		(
			"cloud_shadow_shot: кромка %.0f м, старт %.0f м, камера на %.0f м над стартом"
			% [cb, sp.y, hi]
		)
	)
	var eye := sp - fwd * 300.0 + Vector3.UP * hi
	cam.look_at_from_position(eye, eye + fwd * 1500.0 + Vector3.DOWN * 2000.0, Vector3.UP)
	await _shoot("high")
	cam.look_at_from_position(eye, eye + fwd * 3000.0 + Vector3.DOWN * 1100.0, Vector3.UP)
	await _shoot("mid")
	eye = sp + Vector3.UP * 40.0
	cam.look_at_from_position(eye, eye + fwd * 1000.0 + Vector3.DOWN * 120.0, Vector3.UP)
	await _shoot("low")
	# Сверху над облаками, отвесно вниз: тени рядом со своими облаками (сдвиг от солнца).
	eye = Vector3(sp.x, cb + 4000.0, sp.z)
	cam.look_at_from_position(eye, eye + Vector3.DOWN * 1000.0, fwd)
	await _shoot("top")
	print("cloud_shadow_shot: OK %s" % _tag)
	await _quit(0)


func _shoot(view: String) -> void:
	for i in 60:
		await RenderingServer.frame_post_draw
	var path := "%s/%s_%s.png" % [_out, _tag, view]
	var img := get_viewport().get_texture().get_image()
	print("cloud_shadow_shot: %s (%s)" % [path, error_string(img.save_png(path))])
	if _gpu_frames > 0:
		await _measure(view)
	# Карта теней облаков (CloudShadowMap) рядом с кадром — для отладки.
	var sm := get_tree().root.find_child("ShadowMap", true, false)
	if sm != null and sm.get_child_count() > 0 and sm.get_child(0) is SubViewport:
		var mp := (sm.get_child(0) as SubViewport).get_texture().get_image()
		mp.save_png("%s/%s_%s_map.png" % [_out, _tag, view])


## Среднее время кадра на GPU (главное окно и SubViewport карты теней) и CPU перерисовки карты.
func _measure(view: String) -> void:
	var main_vp := get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(main_vp, true)
	var sm := get_tree().root.find_child("ShadowMap", true, false)
	var map_vp := RID()
	if sm != null and sm.get_child(0) is SubViewport:
		# На время замера карта рисуется каждый кадр (иначе замер SubViewport пуст).
		(sm.get_child(0) as SubViewport).render_target_update_mode = SubViewport.UPDATE_ALWAYS
		map_vp = (sm.get_child(0) as SubViewport).get_viewport_rid()
		RenderingServer.viewport_set_measure_render_time(map_vp, true)
	for i in 10:
		await RenderingServer.frame_post_draw
	var g_main := 0.0
	var g_map := 0.0
	var n_map := 0
	var cpu := 0.0
	for i in _gpu_frames:
		await RenderingServer.frame_post_draw
		g_main += RenderingServer.viewport_get_measured_render_time_gpu(main_vp)
		if map_vp.is_valid():
			var gm := RenderingServer.viewport_get_measured_render_time_gpu(map_vp)
			if gm > 0.0:
				g_map += gm
				n_map += 1
			cpu += float(sm.get("last_update_us"))
	var fmt := "cloud_shadow_shot: GPU %s: кадр %.2f мс, карта теней %.3f мс (в %d из %d кадров)"
	fmt += ", CPU карты %.3f мс"
	print(
		(
			fmt
			% [
				view,
				g_main / _gpu_frames,
				g_map / maxi(n_map, 1),
				n_map,
				_gpu_frames,
				cpu / _gpu_frames / 1000.0
			]
		)
	)
