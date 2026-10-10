extends Node
## Кадры целой игры на реальном рельефе (OL-4): грузит место по координатам как игра, ждёт полёта, ставит
## свободную камеру у объекта OSM (дымящая труба, ЛЭП, мачта, ветряк, канатка) или у точки и снимает.
##   XDG_DATA_HOME=<профиль с местом> godot --path . --fullscreen --resolution 1920x1080 \
##     res://tools/shots/osm_place_shot.tscn -- --place=lat,lon --out=<каталог> [--game-args=--wind=6,--from=270] \
##     --shots="имя:вид:lat:lon:дистанция:высота_камеры:азимут:ожидание_с[:смещение_цели_м];…"
## вид: pt (точка), chimney (труба ≥ 90 м), power (линия ЛЭП), mast (вышка/мачта связи), wind (ветряк),
## cable (середина канатки). lat,lon — подсказка: берётся ближайший объект вида. Камера стоит на
## <дистанции> от цели, на высоте <высота_камеры> над землёй в цели, со стороны азимута (° от севера, куда
## смотрим из камеры на цель — камера на этой стороне), смотрит на цель (точка на 20 м над землёй).
## Ожидание — секунд симуляции после постановки (дым и шлейфы набирают силу ~10 с).

const MAIN_SCENE := preload("res://scenes/main.tscn")

var _main: Node
var _game: Node


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var place := ""
	var out := "/tmp"
	var gargs: Array = []
	var shots := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--place="):
			place = a.substr(8)
		elif a.begins_with("--out="):
			out = a.substr(6)
		elif a.begins_with("--game-args="):
			gargs = Array(a.substr(12).split(",", false))
		elif a.begins_with("--shots="):
			shots = a.substr(8)
	var args := PackedStringArray(["--autostart", "--autopilot", "--latlon=" + place, "--air-start=0,600", "--no-overlay"])
	args.append_array(PackedStringArray(gargs))
	_main = MAIN_SCENE.instantiate()
	_main.set("opts", LaunchOptions.parse(args))
	add_child(_main)
	for i in 9000:
		if int(_main.get("state")) == 2:
			break
		await get_tree().process_frame
	if int(_main.get("state")) != 2:
		print("osm_place_shot: не долетели до FLYING")
		get_tree().quit(1)
		return
	_game = _main.get_node("Game")
	get_window().mode = Window.MODE_EXCLUSIVE_FULLSCREEN
	for i in 10:
		await get_tree().process_frame
	print("osm_place_shot: окно ", get_window().size, " режим ", get_window().mode)
	for cl in _main.find_children("*", "CanvasLayer", true, false):
		cl.visible = false  # приборы и подписи — чистый кадр мира
	for c in _main.find_children("*", "Control", true, false):
		if not c.get_parent() is Control:
			c.visible = false
	DirAccess.make_dir_recursive_absolute(out)
	var lc: Dictionary = Locations.config(_game.terrain.location_id)
	var clat := float(lc.get("center_lat", 0.0))
	var clon := float(lc.get("center_lon", 0.0))
	var m := OsmGrid.m_per_deg()
	var mlon := m * cos(deg_to_rad(clat))
	var osm: OsmData = _game.world_link.objects.osm
	print("osm_place_shot: центр места ", clat, ",", clon, " домов ", osm.buildings.size(), " труб ", osm.verticals.size())
	var cam: CameraRig = _game.camera
	cam.set_mode("free")
	for spec in shots.split(";", false):
		var f := spec.split(":")
		var xz := Vector2((float(f[3]) - clon) * mlon, -(float(f[2]) - clat) * m)
		var tgt := _pick(osm, f[1], xz)
		var dist := float(f[4])
		var hcam := float(f[5])
		var az := deg_to_rad(float(f[6]))
		var wait_s := float(f[7])
		var gy: float = _game.terrain.height_at(tgt.x, tgt.y)
		var tgt3 := Vector3(tgt.x, gy + 20.0 + (float(f[8]) if f.size() > 8 else 0.0), tgt.y)
		var cx := tgt.x + sin(az) * dist
		var cz := tgt.y - cos(az) * dist
		var cpos := Vector3(cx, _game.terrain.height_at(cx, cz) + hcam, cz)
		print("osm_place_shot: ", f[0], " цель ", tgt, " (", f[1], ") камера ", cpos)
		_game.glider.reset_in_air(cpos + Vector3(sin(az) * 60.0, 40.0, -cos(az) * 60.0), rad_to_deg(az) + 180.0)  # слои мира — вокруг планера
		var t_end := Time.get_ticks_msec() + int(wait_s * 1000.0)
		var t_reset := Time.get_ticks_msec()
		while Time.get_ticks_msec() < t_end:
			await get_tree().process_frame
			if Time.get_ticks_msec() - t_reset > 700:
				_game.glider.reset_in_air(cpos + Vector3(sin(az) * 60.0, 40.0, -cos(az) * 60.0), rad_to_deg(az) + 180.0)
				t_reset = Time.get_ticks_msec()
			cam.global_transform = Transform3D(Basis(), cpos).looking_at(tgt3, Vector3.UP)
			cam.global_position = cpos
		for i in 4:
			await get_tree().process_frame
			cam.look_at_from_position(cpos, tgt3, Vector3.UP)
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("%s/%s.png" % [out, f[0]])
	get_tree().quit(0)


func _pick(osm: OsmData, kind: String, hint: Vector2) -> Vector2:
	var best := INF
	var res := hint
	match kind:
		"chimney", "mast", "wind":
			for v: Dictionary in osm.verticals:
				var ok: bool = (kind == "chimney" and v.t == "chimney" and float(v.h) >= 90.0) \
					or (kind == "mast" and v.t in ["mast", "tower"] and bool(v.comm)) or (kind == "wind" and v.t == "wind")
				var d := Vector2(v.x, v.z).distance_to(hint)
				if ok and d < best:
					best = d
					res = Vector2(v.x, v.z)
		"power":
			for l: Dictionary in osm.power:
				var p: PackedVector2Array = l.p
				for i in p.size():
					var d := p[i].distance_to(hint)
					if d < best:
						best = d
						res = p[i]
					if i > 0:
						var q := Geometry2D.get_closest_point_to_segment(hint, p[i - 1], p[i])
						if q.distance_to(hint) < best:
							best = q.distance_to(hint)
							res = q
		"cable":
			for a: Dictionary in osm.aerialways:
				var p: PackedVector2Array = a.p
				if a.t in ["gondola", "cable_car", "mixed_lift"] and p.size() > 1:
					var mid := p[p.size() / 2]
					var d := mid.distance_to(hint)
					if d < best:
						best = d
						res = mid
	print("osm_place_shot: ", kind, " ближайший на ", snappedf(best, 1.0) if best < INF else -1.0, " м от подсказки")
	return res
