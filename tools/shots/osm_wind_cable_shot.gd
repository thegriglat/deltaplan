extends Node3D
## Ветряки и кабинки канатки OSM (OL-3). Запуск:
##   godot --path . --resolution 1600x900 res://tools/shots/osm_wind_cable_shot.tscn -- --out=<png> [режим]
## Режимы: --synth=wind (один ветряк) | farm (ряд из 5) | cabin (линия канатки); --wind=vx,vz (м/с, воздух);
##   --sim=секунд (прокрутить состояние вперёд шагами 1/30 с); --cam=x,y,z --look=x,y,z (мир, м).
## Реальные данные: --tiles=<каталог с v1/> --lat= --lon= [--find=wind|cable — камера у ближайшего
## объекта, --off=dx,dy,dz смещение камеры от объекта]. Земля — плоскость (рельефа в репозитории нет).

func _v3(s: String) -> Vector3:
	var p := s.split(",")
	return Vector3(float(p[0]), float(p[1]), float(p[2]))


func _ready() -> void:
	var out := "osm_wind_cable.png"
	var root := "/home/greg/deltaplan_data/osm_tiles/world/out/v1"
	var lat := 51.6
	var lon := 73.1
	var synth := ""
	var find := ""
	var wind := Vector3(8, 0, 3)
	var sim := 0.0
	var cam_p := Vector3(0, 60, 220)
	var look := Vector3(0, 70, 0)
	var off := Vector3(0, 20, 250)
	var has_cam := false
	var cab_off := Vector3.INF
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
		elif a.begins_with("--tiles="):
			root = a.substr(8)
		elif a.begins_with("--lat="):
			lat = float(a.substr(6))
		elif a.begins_with("--lon="):
			lon = float(a.substr(6))
		elif a.begins_with("--synth="):
			synth = a.substr(8)
		elif a.begins_with("--find="):
			find = a.substr(7)
		elif a.begins_with("--wind="):
			var w := a.substr(7).split(",")
			wind = Vector3(float(w[0]), 0, float(w[1]))
		elif a.begins_with("--sim="):
			sim = float(a.substr(6))
		elif a.begins_with("--cam="):
			cam_p = _v3(a.substr(6))
			has_cam = true
		elif a.begins_with("--look="):
			look = _v3(a.substr(7))
		elif a.begins_with("--cabin_cam="):
			cab_off = _v3(a.substr(12))
		elif a.begins_with("--off="):
			off = _v3(a.substr(6))
	var d := OsmData.new()
	var hf := func(_x: float, _z: float) -> float: return 0.0
	if synth == "wind":
		d.verticals = [{"t": "wind", "comm": false, "x": 0.0, "z": 0.0, "h": 80.0}]
	elif synth == "farm":
		for i in 5:
			d.verticals.append({"t": "wind", "comm": false, "x": -600.0 + i * 300.0, "z": -100.0 * i, "h": 80.0})
	elif synth == "cabin":
		d.aerialways = [{"t": "gondola", "p": PackedVector2Array([Vector2(-900, 0), Vector2(0, 40), Vector2(900, 0)])}]
		hf = func(x: float, _z: float) -> float: return (x + 900.0) * 0.25
	else:
		var paths: Array = []
		for t in OsmGrid.neighbors(lat, lon):
			var p := root.path_join("%d/%d.dpt" % [t.x, t.y])
			if FileAccess.file_exists(p):
				paths.append(p)
		var tiles: Array = []
		for r: Variant in OsmData.decode_files(paths):
			if r is Dictionary and not (r as Dictionary).is_empty():
				tiles.append(r)
		d = OsmData.from_tiles_parallel(tiles, lat, lon, 20000.0)
		print("tiles ", tiles.size(), " ветряков ", d.verticals.filter(func(v): return v.t == "wind").size(),
			" канаток ", d.aerialways.size())
	var cfg := WorldObjects.load_config()
	var layer := OsmLayer.new()
	layer.build(d, cfg, hf, ObstacleIndex.new())
	# до слияния OL-2 (verticals.skip) старые ветряки OsmPilot убираем вручную
	var old := layer.get_node_or_null("Pilot/Verticals")
	if old != null:
		old.free()
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.55, 0.72, 0.92)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.62, 0.66, 0.72)
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-35, 40, 0)
	sun.shadow_enabled = true
	add_child(sun)
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(60000, 60000)
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.5, 0.52, 0.34)
	pm.material = gm
	ground.mesh = pm
	ground.position.y = -0.3
	if synth != "cabin":
		add_child(ground)
	add_child(layer)
	var cam := Camera3D.new()
	cam.far = 30000.0
	cam.fov = 60.0
	add_child(cam)
	cam.current = true
	if find != "" and synth == "":
		var target := Vector3.ZERO
		var best := INF
		if find == "wind":
			for v: Dictionary in d.verticals:
				if v.t == "wind" and Vector2(v.x, v.z).length() < best:
					best = Vector2(v.x, v.z).length()
					target = Vector3(v.x, 80.0, v.z)
		else:
			for a: Dictionary in d.aerialways:
				if a.t in ["gondola", "cable_car", "mixed_lift"] and (a.p as PackedVector2Array).size() > 1:
					var m: Vector2 = a.p[a.p.size() / 2]
					if m.length() < best:
						best = m.length()
						target = Vector3(m.x, 40.0, m.y)
		print("цель ", target, " расстояние ", best)
		cam_p = target + off
		look = target
		has_cam = true
	cam.position = cam_p
	cam.look_at(look, Vector3.UP)
	# L4: ветер подставным air_fn, затем прокрутка времени
	var air := func(_p: Vector3) -> Vector3: return wind
	for n in get_tree().get_nodes_in_group(&"osm_wind"):
		n.osm_wind(air, cam.position)
	var steps := int(sim * 30.0)
	for i in steps:
		for n in layer.get_children():
			if n.has_method("step"):
				n.step(1.0 / 30.0)
	if cab_off != Vector3.INF:
		var cc := layer.get_node_or_null("Cabins") as OsmCableCars
		if cc != null:
			var st: Array = cc.cabin_state(cc._lines[0].line, 1, cc._t)
			cam.position = (st[0] as Vector3) + cab_off
			cam.look_at((st[0] as Vector3) + Vector3(0, -2.5, 0), Vector3.UP)
	for n in get_tree().get_nodes_in_group(&"osm_wind"):
		if n is OsmWindTurbines and n.turbine_count() > 0:
			print("ветряк0: yaw ", n.yaw_of(0), " omega ", n.omega_of(0))
	for i in 6:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out)
	print("osm_wind_cable_shot: ", out)
	get_tree().quit(0)
