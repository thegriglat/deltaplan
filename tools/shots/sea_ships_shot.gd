extends Node
## Кадры шлюза sea-ships (SEA-5): горизонт над морем с 300 и 1500 м и увеличенное судно на реальных местах.
## Ничего в игре не меняет: грузит место как игра, ждёт суда слоя (ShipPlacer через WorldObjects), ставит
## свободную камеру и снимает. Судно/направление — из WorldObjects.ships (те же записи, что в игре).
##   XDG_DATA_HOME=<профиль с местом> godot --path . --fullscreen --resolution 1920x1080 \
##     res://tools/shots/sea_ships_shot.tscn -- --place=lat,lon --tag=<имя> --out=<каталог> [--game-args=--hour=12]
## Для места: от старта (центр места) к ближайшему судну идём по лучу до моря (высота ≤ 1 м на 500 м вперёд),
## это точка берега. Кадры: горизонт с 300 и 1500 м над точкой, взгляд на ближайшее судно (и ещё на 2 судна
## в других направлениях); крупное судно — камера в 700 и 350 м от двух ближайших судов, 60 м над водой.
## Пишет <out>/<tag>_*.jpg (q 0,88) и <out>/<tag>_counts.json (судов всего, в кадре — по пирамиде видимости камеры).

const MAIN_SCENE := preload("res://scenes/main.tscn")

var _main: Node
var _game: Node
var _out := "/tmp"
var _tag := "place"
var _counts: Array = []
var _zoom_only := false
var _eve := false  # --mode=eve: один кадр с 300 м (час задаёт --game-args=--hour=20)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var place := ""
	var gargs: Array = []
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--place="):
			place = a.substr(8)
		elif a.begins_with("--out="):
			_out = a.substr(6)
		elif a == "--mode=zoom":
			_zoom_only = true
		elif a == "--mode=eve":
			_eve = true
		elif a.begins_with("--tag="):
			_tag = a.substr(6)
		elif a.begins_with("--game-args="):
			gargs = Array(a.substr(12).split(",", false))
	var args := PackedStringArray(["--autostart", "--autopilot", "--latlon=" + place, "--air-start=0,600", "--no-overlay"])
	args.append_array(PackedStringArray(gargs))
	_main = MAIN_SCENE.instantiate()
	_main.set("opts", LaunchOptions.parse(args))
	add_child(_main)
	for i in 12000:
		if int(_main.get("state")) == 2:
			break
		await get_tree().process_frame
	if int(_main.get("state")) != 2:
		print("sea_ships_shot: не долетели до FLYING")
		get_tree().quit(1)
		return
	_game = _main.get_node("Game")
	get_window().mode = Window.MODE_EXCLUSIVE_FULLSCREEN
	for i in 10:
		await get_tree().process_frame
	for cl in _main.find_children("*", "CanvasLayer", true, false):
		cl.visible = false
	for c in _main.find_children("*", "Control", true, false):
		if not c.get_parent() is Control:
			c.visible = false
	DirAccess.make_dir_recursive_absolute(_out)
	var wo: Node = _game.world_link.objects
	for i in 900:  # суда считает рабочий поток
		if int(wo.get("_ship_task")) < 0 and wo.get("ship_layer") != null:
			break
		await get_tree().process_frame
	var ships: Array = wo.get("ships")
	print("sea_ships_shot: ", _tag, " судов в записях ", ships.size())
	if ships.is_empty():
		get_tree().quit(2)
		return
	_game.camera.set_mode("free")
	await _shots(ships)
	var f := FileAccess.open("%s/%s_counts.json" % [_out, _tag], FileAccess.WRITE)
	f.store_string(JSON.stringify({"ships_total": ships.size(), "frames": _counts}, "  "))
	f.close()
	get_tree().quit(0)


func _h(x: float, z: float) -> float:
	return _game.terrain.height_at(x, z)


## Луч a→b над морем: высота ≤ 1 м во всех точках через 200 м.
func _clear(a: Vector2, b: Vector2) -> bool:
	var d := a.distance_to(b)
	var u := (b - a).normalized()
	var x := 0.0
	while x < d:
		var p := a + u * x
		if _h(p.x, p.y) > 1.0:
			return false
		x += 200.0
	return true


func _shots(ships: Array) -> void:
	var gp: Vector3 = _game.glider.global_position
	var start := Vector2(gp.x, gp.z)
	# точка берега: ближайшая к старту вода (≥ 600 м моря дальше по лучу) по 72 лучам
	var shore := start
	var best := INF
	for k in 72:
		var dir := Vector2.from_angle(TAU * k / 72.0)
		var d := 0.0
		while d < 60000.0 and d < best:
			var ok := true
			for j in 7:
				var p := start + dir * (d + j * 100.0)
				if _h(p.x, p.y) > 1.0:
					ok = false
					break
			if ok:
				best = d
				shore = start + dir * d
				break
			d += 100.0
	print("sea_ships_shot: старт ", start, " точка берега ", shore, " (", snappedf(best, 1.0), " м от старта)")
	var order: Array = ships.duplicate()
	order.sort_custom(func(a, b): return shore.distance_to(Vector2(a.x, a.z)) < shore.distance_to(Vector2(b.x, b.z)))
	var near: Dictionary = order[0]
	print("sea_ships_shot: ближайшее судно ", near.type, " на ", snappedf(shore.distance_to(Vector2(float(near.x), float(near.z))), 1.0), " м от берега")
	# горизонт — только на суда по чистому морю (вдоль луча берег→судно нет суши), иначе взгляд упирается в остров
	var vis: Array = []
	for s: Dictionary in order:
		if _clear(shore, Vector2(float(s.x), float(s.z))):
			vis.append(s)
	print("sea_ships_shot: судов по чистому морю от точки берега ", vis.size(), " из ", ships.size())
	var shore_ok := not vis.is_empty()  # нет судов по чистому морю от берега — кадры «с берега» пропускаем, только «у судна»
	if vis.is_empty():
		vis = order
	near = vis[0]
	var targets: Array = [near]
	for s: Dictionary in vis:  # ещё два судна в других направлениях (угол ≥ 45° от уже взятых)
		if targets.size() >= 3:
			break
		var ok := true
		for t: Dictionary in targets:
			var a: float = (Vector2(float(s.x), float(s.z)) - shore).angle_to(Vector2(float(t.x), float(t.z)) - shore)
			if absf(rad_to_deg(a)) < 45.0:
				ok = false
		if ok:
			targets.append(s)
	var n := 0
	# «у судна»: камера над морем в ≤ 8 км от ближайшего судна (шаг от судна назад к берегу по воде), горизонт на судно
	var nt0 := Vector2(float(near.x), float(near.z))
	var ray0 := (shore - nt0).normalized()
	var back_m := 0.0
	while back_m < 8000.0 and _h(nt0.x + ray0.x * (back_m + 200.0), nt0.y + ray0.y * (back_m + 200.0)) <= 1.0:
		back_m += 200.0
	var cn := nt0 + ray0 * back_m
	print("sea_ships_shot: камера «у судна» ", snappedf(back_m, 1.0), " м от ближайшего судна")
	if _eve:
		var cpe := Vector3(cn.x, float(near.get("y", 0.0)) + 300.0, cn.y)
		await _snap("%s_near_300m" % _tag, cpe, Vector3(nt0.x, cpe.y, nt0.y), true, ships)
		return
	if not _zoom_only:
		for h in [300.0, 1500.0]:
			n += 1
			await _snap("%s_near_%dm_%d" % [_tag, int(h), n], Vector3(cn.x, float(near.get("y", 0.0)) + h, cn.y), Vector3(nt0.x, float(near.get("y", 0.0)) + h, nt0.y), true, ships)
	for h in ([] if (_zoom_only or not shore_ok) else [300.0, 1500.0]):
		for t: Dictionary in targets:
			n += 1
			var tp := Vector3(float(t.x), 0.0, float(t.z))
			var cpos := Vector3(shore.x, float(t.get("y", 0.0)) + h, shore.y)
			await _snap("%s_horizon_%dm_%d" % [_tag, int(h), n], cpos, Vector3(tp.x, cpos.y - 0.0, tp.z), true, ships)
	# увеличение: узкий FOV 8°, камера 3 и 6 км от ближайшего судна на высоте 300 м над водой, вдоль луча от берега
	var nt := Vector2(float(near.x), float(near.z))
	var ray := (nt - shore).normalized()
	for dd in [6000.0, 3000.0]:
		var dcam := minf(dd, shore.distance_to(nt))
		var cxy := nt - ray * dcam
		var cp3 := Vector3(cxy.x, float(near.get("y", 0.0)) + 300.0, cxy.y)
		var tp3 := Vector3(nt.x, float(near.get("y", 0.0)) + 15.0, nt.y)
		await _snap("%s_zoom_%dkm" % [_tag, int(dd / 1000.0)], cp3, tp3, false, ships, 8.0)
	if _zoom_only:
		return
	n = 0
	for dist in [700.0, 350.0]:
		for t: Dictionary in targets.slice(0, 2):
			n += 1
			# камера сбоку от судна: перпендикуляр к курсу, чтобы видеть борт
			var hd := float(t.heading_rad)
			var fwd := Vector2(sin(hd), -cos(hd))
			var side := Vector2(-fwd.y, fwd.x)
			var cxz: Vector2 = Vector2(float(t.x), float(t.z)) + side * float(dist)
			var cpos := Vector3(cxz.x, float(t.get("y", 0.0)) + 60.0, cxz.y)
			var tp := Vector3(float(t.x), float(t.get("y", 0.0)) + 15.0, float(t.z))
			await _snap("%s_ship_%dm_%d" % [_tag, int(dist), n], cpos, tp, false, ships)


## Свободная камера держит углы в _free_rot (рыскание, тангаж) и каждый кадр собирает по ним поворот — задаём их же.
func _aim(cam: CameraRig, cpos: Vector3, look: Vector3) -> void:
	var d := look - cpos
	cam.set("_free_rot", Vector2(atan2(-d.x, -d.z), atan2(d.y, Vector2(d.x, d.z).length())))
	cam.global_position = cpos
	cam.look_at_from_position(cpos, look, Vector3.UP)


func _snap(name: String, cpos: Vector3, tp: Vector3, horizon: bool, ships: Array, fov: float = 0.0) -> void:
	var cam: CameraRig = _game.camera
	var fov0 := cam.fov
	if fov > 0.0:
		cam.fov = fov
	var look := tp
	if horizon:  # на горизонт: на уровне камеры, чуть вниз
		var dv := Vector3(tp.x - cpos.x, 0.0, tp.z - cpos.z).normalized()
		look = cpos + dv * 1000.0 + Vector3(0.0, -35.0, 0.0)
	var back := (cpos - look).normalized()
	var gpos := cpos + Vector3(back.x, 0.0, back.z).normalized() * 80.0 + Vector3(0.0, -30.0, 0.0)
	var yaw := rad_to_deg(atan2(-back.x, back.z))
	_game.glider.reset_in_air(gpos, yaw)
	var t_end := Time.get_ticks_msec() + 5000
	var t_reset := Time.get_ticks_msec()
	while Time.get_ticks_msec() < t_end:
		await get_tree().process_frame
		if Time.get_ticks_msec() - t_reset > 700:
			_game.glider.reset_in_air(gpos, yaw)
			t_reset = Time.get_ticks_msec()
		_aim(cam, cpos, look)
		if fov > 0.0:
			cam.fov = fov
	for i in 4:
		await get_tree().process_frame
		_aim(cam, cpos, look)
		if fov > 0.0:
			cam.fov = fov
	await RenderingServer.frame_post_draw
	var vp := get_viewport().get_camera_3d()
	var inf := 0
	var infar := 0
	var lod_far: float = ShipLayer.lod_end(ShipLayer.render_params(), 2)
	for s: Dictionary in ships:
		var p := Vector3(float(s.x), float(s.get("y", 0.0)) + 10.0, float(s.z))
		if vp.is_position_in_frustum(p) and not vp.is_position_behind(p) and p.distance_to(vp.global_position) < lod_far:
			inf += 1
			if p.distance_to(vp.global_position) > 25000.0:
				infar += 1
	var dbg: Vector3 = (tp - cam.global_position)
	print("sea_ships_shot: dbg ", name, " cam ", cam.global_position, " до цели ", snappedf(dbg.length(), 1.0), " угол к оси ", snappedf(rad_to_deg((-cam.global_transform.basis.z).angle_to(dbg)), 0.01), " fov ", cam.fov, " near ", cam.near, " far ", cam.far)
	cam.fov = fov0
	get_viewport().get_texture().get_image().save_jpg("%s/%s.jpg" % [_out, name], 0.88)
	_counts.append({"frame": name, "ships_in_frustum": inf, "of_them_beyond_25km": infar, "cam": [cpos.x, cpos.y, cpos.z]})
	print("sea_ships_shot: ", name, " судов в кадре ", inf)
