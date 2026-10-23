extends Node
## SNW-5: снежные флаги в игре — число источников, цена кадра, кадры. Не игровой код.
## Грузит место как игра (как tools/shots/osm_place_shot.gd), ставит свободную камеру в заданную точку,
## ждёт, считает источники (длина SnowPlume.model._list), меряет кадры, снимает картинку.
##   XDG_DATA_HOME=<профиль с местом> godot --path . --fullscreen --resolution 1920x1080 \
##     res://tools/research/snow_plume/SNW-5/snow_bench.tscn -- --latlon=lat,lon --out=<json> \
##     [--game-args=--wind=16,--from=270,--temp=-20] \
##     --poses="имя:lat:lon:дистанция:высота_камеры:азимут:ожидание_с:замер_с[:смещение_цели_м]" [--shotdir=<каталог>]
## Камера стоит на <дистанции> от цели со стороны азимута (° от севера), на <высоте_камеры> м над землёй
## в точке камеры, смотрит на цель (земля в цели + смещение). Замер — кадры в течение замер_с (0 — без).
## Пишет по строке JSON на позу в --out.

const MAIN_SCENE := preload("res://scenes/main.tscn")

var _main: Node
var _game: Node
var _out := ""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var latlon := ""
	var gargs: Array = []
	var poses := ""
	var shotdir := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--latlon="):
			latlon = a.substr(9)
		elif a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--game-args="):
			gargs = Array(a.substr(12).split(",", false))
		elif a.begins_with("--poses="):
			poses = a.substr(8)
		elif a.begins_with("--shotdir="):
			shotdir = a.substr(10)
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	var args := PackedStringArray(["--autostart", "--autopilot", "--latlon=" + latlon, "--air-start=0,600", "--no-overlay", "--bots=0"])
	args.append_array(PackedStringArray(gargs))
	_main = MAIN_SCENE.instantiate()
	_main.set("opts", LaunchOptions.parse(args))
	add_child(_main)
	for i in 9000:
		if int(_main.get("state")) == 2:
			break
		await get_tree().process_frame
	if int(_main.get("state")) != 2:
		print("snow_bench: не долетели до FLYING")
		get_tree().quit(1)
		return
	_game = _main.get_node("Game")
	get_window().mode = Window.MODE_EXCLUSIVE_FULLSCREEN
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	for i in 10:
		await get_tree().process_frame
	for cl in _main.find_children("*", "CanvasLayer", true, false):
		cl.visible = false
	for c in _main.find_children("*", "Control", true, false):
		if not c.get_parent() is Control:
			c.visible = false
	var lc: Dictionary = Locations.config(_game.terrain.location_id)
	var clat := float(lc.get("center_lat", 0.0))
	var clon := float(lc.get("center_lon", 0.0))
	var m := OsmGrid.m_per_deg()
	var mlon := m * cos(deg_to_rad(clat))
	var cam: CameraRig = _game.camera
	cam.set_mode("free")
	var t: Terrain = _game.terrain
	for spec in poses.split(";", false):
		var f := spec.split(":")
		var tgt := Vector2((float(f[2]) - clon) * mlon, -(float(f[1]) - clat) * m)
		if absf(float(f[1])) > 1000.0:  # координаты игры: поле 1 = z, поле 2 = x, м
			tgt = Vector2(float(f[2]), float(f[1]))
		var dist := float(f[3])
		var hcam := float(f[4])
		var az := deg_to_rad(float(f[5]))
		var wait_s := float(f[6])
		var meas_s := float(f[7])
		var off := float(f[8]) if f.size() > 8 else 0.0
		var tgt3 := Vector3(tgt.x, t.height_at(tgt.x, tgt.y) + off, tgt.y)
		var cx := tgt.x + sin(az) * dist
		var cz := tgt.y - cos(az) * dist
		var cpos := Vector3(cx, t.height_at(cx, cz) + hcam, cz)
		_pose(cam, cpos, tgt3, true)
		var t_end := Time.get_ticks_msec() + int(wait_s * 1000.0)
		var series := []
		var t_ser := Time.get_ticks_msec()
		var t_beg := t_ser
		while Time.get_ticks_msec() < t_end:
			await get_tree().process_frame
			_pose(cam, cpos, tgt3, false)
			if Time.get_ticks_msec() - t_ser >= 2000:
				t_ser = Time.get_ticks_msec()
				series.append([snappedf((t_ser - t_beg) / 1000.0, 0.1), _emitters().emitters, _scan_count()])
		var row := {series = series, name = f[0], cam = [cpos.x, cpos.y, cpos.z], tgt = [tgt3.x, tgt3.y, tgt3.z]}
		row.merge(_emitters())
		if meas_s > 0.0:
			row.merge(await _sample(meas_s, cam, cpos, tgt3))
		else:
			for i in 4:
				await get_tree().process_frame
				_pose(cam, cpos, tgt3, false)
		if shotdir != "":
			DirAccess.make_dir_recursive_absolute(shotdir)
			await RenderingServer.frame_post_draw
			var img := get_viewport().get_texture().get_image()
			var p := "%s/%s.jpg" % [shotdir, f[0]]
			img.save_jpg(p, 0.88)
			row["shot"] = p
		_write(row)
		print("snow_bench: ", JSON.stringify(row))
	get_tree().quit(0)


var _t_reset := 0


func _pose(cam: CameraRig, cpos: Vector3, tgt: Vector3, force: bool) -> void:
	var now := Time.get_ticks_msec()
	if force or now - _t_reset > 700:
		var d := (Vector2(tgt.x, tgt.z) - Vector2(cpos.x, cpos.z)).normalized()
		_game.glider.reset_in_air(cpos + Vector3(-d.x * 60.0, 40.0, -d.y * 60.0), rad_to_deg(atan2(d.x, -d.y)))
		_t_reset = now
	cam.global_transform = Transform3D(Basis(), cpos).looking_at(tgt, Vector3.UP)
	cam.global_position = cpos


func _emitters() -> Dictionary:
	var n: Node = _game.terrain.get_node_or_null("SnowPlume")
	if n == null or n.get("model") == null:
		return {plume_node = false, emitters = 0}
	var lst: Array = n.model._list
	var items := []
	var t_sum := 0.0
	for e: Dictionary in lst:
		var p: Vector3 = e.pos
		var tc := float(_game.air_temp_c_at(p.y)) if _game.has_method("air_temp_c_at") else NAN
		t_sum += tc
		items.append({x = snappedf(p.x, 1.0), y = snappedf(p.y, 1.0), z = snappedf(p.z, 1.0), u10 = snappedf(e.u10, 0.01),
			u_t = snappedf(e.u_t, 0.01), intensity = snappedf(e.intensity, 0.01), snow = snappedf(e.snow, 0.01), t_c = snappedf(tc, 0.1)})
	return {plume_node = true, emitters = lst.size(), items = items, t_mean_c = snappedf(t_sum / maxf(1.0, lst.size()), 0.1),
		scan_count = n.model.scan_count()}


func _sample(dur: float, cam: CameraRig, cpos: Vector3, tgt: Vector3) -> Dictionary:
	var vp_rid := get_viewport().get_viewport_rid()
	var frame := PackedFloat64Array()
	var gpu := PackedFloat64Array()
	var cpu := PackedFloat64Array()
	var proc := PackedFloat64Array()
	var t0 := Time.get_ticks_usec()
	var t_prev := t0
	while (Time.get_ticks_usec() - t0) < dur * 1e6:
		await RenderingServer.frame_post_draw
		_pose(cam, cpos, tgt, false)
		var now := Time.get_ticks_usec()
		frame.append((now - t_prev) / 1000.0)
		t_prev = now
		gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(vp_rid))
		cpu.append(RenderingServer.viewport_get_measured_render_time_cpu(vp_rid))
		proc.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	return {frames = frame.size(), frame_ms = _mean(frame), frame_ms_1pct = _worst1(frame), gpu_ms = _mean(gpu),
		gpu_ms_1pct = _worst1(gpu), cpu_render_ms = _mean(cpu), process_ms = _mean(proc),
		draw_calls = Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)}


static func _mean(a: PackedFloat64Array) -> float:
	if a.is_empty():
		return 0.0
	var s := 0.0
	for v in a:
		s += v
	return s / a.size()


static func _worst1(a: PackedFloat64Array) -> float:
	if a.is_empty():
		return 0.0
	var s := a.duplicate()
	s.sort()
	var n1 := maxi(1, int(ceil(s.size() * 0.01)))
	return _mean(s.slice(s.size() - n1, s.size()))


func _write(row: Dictionary) -> void:
	if _out == "":
		return
	DirAccess.make_dir_recursive_absolute(_out.get_base_dir())
	var f := FileAccess.open(_out, FileAccess.READ_WRITE if FileAccess.file_exists(_out) else FileAccess.WRITE)
	f.seek_end()
	f.store_line(JSON.stringify(row))
	f.close()


func _scan_count() -> int:
	var n: Node = _game.terrain.get_node_or_null("SnowPlume")
	return n.model.scan_count() if n != null and n.get("model") != null else -1
