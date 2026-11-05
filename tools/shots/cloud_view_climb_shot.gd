extends Node
## CVW-1: подъём в ясном столбце у облаков — кадры и замеры (контракт CVW-К1, CSV).
## Полёт над стартом запускается как из меню, время атмосферы замораживается, камера ставится
## в ясный столбец (cover≈0, рядом есть облака) и поднимается по серии высот AGL: ниже основания,
## у основания, внутри слоя, над вершинами, выше до 4000 м. Взгляд к горизонту и вниз.
## Запуск:
##   XDG_DATA_HOME=~/.cache/dp-xdg/cloud-view-CVW-1 .dpcli/dpcli lock cpu CVW-1 -- godot --path . \
##     --audio-driver Dummy --resolution 1920x1080 res://tools/shots/cloud_view_climb_shot.tscn -- \
##     --out=<каталог кадров> --csv=<measures.csv> [--loc=ongudai] [--hours=13,18] [--pitches=-3,-30] \
##     [--temp=31] [--wind=5] [--air_s=600] [--variants=main,nowo,nohaze,noclouds,nofog,bare] [--agl=…]
## Варианты (отделяют кандидатов причины): nowo - без CloudWhiteout; nohaze - дымка выключена;
## noclouds - без прохода облаков (compositor); nofog - туман Environment выключен; bare - всё сразу.
## Код игры не меняется, всё в памяти стенда. Подготовка: --air_s - список времён атмосферы, с (перебор, пока не найдётся ясный столбец).
## Дополнительные колонки x_*: x_haze_top_msl, x_fog_enabled, x_ground_msl, x_cover_max_near,
## x_cloud_recs, x_sky_r/g/b (средний цвет верхней четверти кадра), x_flags,
## x_visible_density (CVW-К3: плотность рисуемых облаков в точке камеры, как её берёт game.gd; −1 —
## облака не рисуются), x_amount_coarse (мгла по грубому полю, как до CVW-4, для сравнения).
## Вариант pass (CVW-4): проход камеры по прямой через центр рисуемого облака рядом с ясным столбцом
## (строки с префиксом pass_, колонка agl - смещение вдоль прохода). --after=<after.json> пишет итог:
## clear_amount_max (макс. мгла main в ясном столбце), in_cloud_amount_max (макс. мгла на проходе).

const MAIN_SCENE := preload("res://scenes/main.tscn")
const TIMEOUT_S := 5000.0
const HEADER := "frame,loc,hour,cam_x,cam_z,cam_y_msl,cam_agl,yaw_deg,pitch_deg,cloud_base_msl,cloud_top_msl,cover_cam,density_cam,whiteout_amount,fog_density,fog_r,fog_g,fog_b,fog_sky_affect,mean_r,mean_g,mean_b,luma_mean,luma_std,png"
const XCOLS := "x_haze_top_msl,x_fog_enabled,x_ground_msl,x_cover_max_near,x_cloud_recs,x_sky_r,x_sky_g,x_sky_b,x_flags,x_visible_density,x_amount_coarse"

var _out := ""
var _csv := ""
var _location := "ongudai"
var _temp_c := 31.0
var _wind_kmh := 18.0
var _hours: PackedFloat64Array = [13.0, 18.0]
var _pitches: PackedFloat64Array = [-3.0, -30.0]
var _air_s := 600.0
var _air_list: PackedFloat64Array = [600.0, 1200.0, 1800.0, 2700.0, 3600.0, 5400.0]
var _use_whiteout := true
var _use_clouds := true
var _use_haze := true
var _use_fog := true
var _tag := ""
var _w := 960
var _settle := 25
var _variants: PackedStringArray = ["main"]
var _no_cloud_pass := false
var _agl_override: PackedFloat64Array = []
var _main: Node = null
var _vp: SubViewport = null
var _root_cam: Camera3D = null
var _lines: PackedStringArray = []
var _wo := CloudWhiteout.new()
var _wo_c := CloudWhiteout.new()
var _after := ""
var _edge_rows: Array = []
var _res := {"rec_frames": 0, "rec_in_cloud_amount_max": 0.0, "rec_clear_amount_max": 0.0, "rec_clear_frames": 0, "rec_kind": -1, "rec_time_s": 0.0, "clear_amount_max": 0.0, "clear_amount_coarse_max": 0.0, "in_cloud_amount_max": 0.0, "in_cloud_amount_coarse_max": 0.0}


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		if kv.size() != 2:
			continue
		match kv[0]:
			"out":
				_out = kv[1]
			"csv":
				_csv = kv[1]
			"loc":
				_location = kv[1]
			"temp":
				_temp_c = float(kv[1])
			"wind":
				_wind_kmh = float(kv[1]) * 3.6
			"hours":
				_hours = _floats(kv[1])
			"pitches":
				_pitches = _floats(kv[1])
			"air_s":
				_air_list = _floats(kv[1])
			"whiteout":
				_use_whiteout = kv[1] == "1"
			"clouds":
				_use_clouds = kv[1] == "1"
			"haze":
				_use_haze = kv[1] == "1"
			"fog":
				_use_fog = kv[1] == "1"
			"width":
				_w = int(kv[1])
			"settle":
				_settle = int(kv[1])
			"variants":
				_variants = kv[1].split(",")
			"after":
				_after = kv[1]
			"agl":
				_agl_override = _floats(kv[1])
	if _out == "" or _csv == "":
		push_error("cloud_view_climb_shot: нужны --out= и --csv=")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	get_tree().create_timer(TIMEOUT_S).timeout.connect(_fail.bind("таймаут"))
	_run()


func _floats(s: String) -> PackedFloat64Array:
	var r := PackedFloat64Array()
	for x in s.split(","):
		r.append(float(x))
	return r


func _fail(why: String) -> void:
	print("cloud_view_climb_shot: FAIL (%s)" % why)
	await _quit(1)


func _quit(code: int) -> void:
	if is_instance_valid(_main):
		_main.queue_free()
	for i in 2:
		await get_tree().process_frame
	await get_tree().create_timer(0.1, true).timeout
	get_tree().quit(code)


## CloudField.sample по растру (билинейно внутри сетки, вне — ближайшая ячейка): [cover, base, top].
static func field_sample(r: Dictionary, x: float, z: float) -> Vector3:
	var nx := int(r.nx)
	var ny := int(r.ny)
	var dx := float(r.dx)
	var u := (x - float(r.x0)) / dx
	var v := (z - float(r.z0)) / dx
	var i0 := clampi(int(floor(u)), 0, nx - 1)
	var j0 := clampi(int(floor(v)), 0, ny - 1)
	var i1 := mini(i0 + 1, nx - 1)
	var j1 := mini(j0 + 1, ny - 1)
	var fx := clampf(u - i0, 0.0, 1.0)
	var fy := clampf(v - j0, 0.0, 1.0)
	var cov: PackedFloat32Array = r.cover
	var dep: PackedFloat32Array = r.depth
	var c := _bil(cov, nx, i0, i1, j0, j1, fx, fy)
	var d := _bil(dep, nx, i0, i1, j0, j1, fx, fy)
	return Vector3(c, float(r.base_msl), float(r.base_msl) + d)


static func _bil(a: PackedFloat32Array, nx: int, i0: int, i1: int, j0: int, j1: int, fx: float, fy: float) -> float:
	var t := lerpf(a[j0 * nx + i0], a[j0 * nx + i1], fx)
	var b := lerpf(a[j1 * nx + i0], a[j1 * nx + i1], fx)
	return lerpf(t, b, fy)


func _run() -> void:
	var main: Node = MAIN_SCENE.instantiate()
	_main = main
	add_child(main)
	var game: Game = main.get_node("Game")
	for i in 60:
		await get_tree().process_frame
	var s := FlightSettings.defaults()
	s.location_id = _location
	s.site_id = ""
	s.temperature_c = _temp_c
	s.wind_speed_kmh = _wind_kmh
	s.start_hour = _hours[0]
	if not await game.start(s):
		_fail("полёт не запустился")
		return
	game.set_physics_process(false)
	game.set_process(false)
	for n in main.get_node("UI").get_children():
		if n is CanvasItem:
			(n as CanvasItem).visible = false
	var air: Node = game.air
	air.set_physics_process(false)
	air.set("time_s", 0.0)
	var start: Dictionary = game.get_start()
	var sun: Vector3 = game.sky.clock.to_sun()
	var sun_yaw := rad_to_deg(atan2(sun.x, -sun.z))
	_vp = SubViewport.new()
	_vp.size = Vector2i(_w, _w * 9 / 16)
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_vp)
	var cam := Camera3D.new()
	_vp.add_child(cam)
	SkyEnvironment.setup_camera(cam)
	cam.make_current()
	_root_cam = Camera3D.new()
	add_child(_root_cam)
	SkyEnvironment.setup_camera(_root_cam)
	_root_cam.make_current()
	get_viewport().disable_3d = true
	var layer := air.get_node_or_null("Clouds") as CloudLayer
	var env: Environment = game.sky.world_env.environment
	_wo.setup(game.get("_cfg").get("cloud_whiteout", {}))
	_wo_c.setup(game.get("_cfg").get("cloud_whiteout", {}))
	var sp: Vector3 = start.position
	var raster: Dictionary = {}
	var col := {}
	# Время атмосферы перебирается по возрастанию, пока в поле не найдётся ясный столбец у облаков.
	for t_air in _air_list:
		game.set_world_time(t_air)
		# Поле облачности считается в крейте фоном: ждать, пока оно догонит время мира.
		for k in 1200:
			await get_tree().create_timer(0.5, true, false, true).timeout
			raster = air.call("cloud_raster")
			if int(raster.get("version", 0)) > 0 and float(raster.get("time_s", 0.0)) >= t_air - 60.0:
				break
		print("cloud_view_climb_shot: время атмосферы %.0f, поле t=%.0f основание %.0f" % [t_air, float(raster.get("time_s", -1.0)), float(raster.get("base_msl", -1.0))])
		if int(raster.get("version", 0)) <= 0:
			continue
		col = _find_clear(raster, sp, game, 2)
		if not col.is_empty():
			_air_s = t_air
			break
	if col.is_empty():
		col = _find_clear(raster, sp, game)
	if col.is_empty() and _variants == PackedStringArray(["recs"]):
		col = {"x": sp.x, "z": sp.z, "top": float(raster.get("base_msl", 2000.0)) + 1000.0, "cmax": 0.0}
	if col.is_empty():
		_fail("нет ясного столбца у облаков")
		return
	for i in 60:
		await get_tree().process_frame
	var cx: float = col.x
	var cz: float = col.z
	var gh: float = game.terrain.height_at(cx, cz)
	var fs := field_sample(raster, cx, cz)
	var base: float = fs.y
	# Толщина слоя - по ближайшим облакам (в ясном столбце depth мало).
	var top_ref: float = col.top
	print(
		(
			"cloud_view_climb_shot: столбец (%.0f, %.0f) земля %.0f м, cover %.3f, основание %.0f, вершины %.0f, макс. cover рядом %.2f"
			% [cx, cz, gh, fs.x, base, top_ref, col.cmax]
		)
	)
	var base_agl := base - gh
	var top_agl := top_ref - gh
	var agls := PackedFloat64Array()
	if _agl_override.size() > 0:
		agls = _agl_override
	else:
		var mid := 0.5 * (base_agl + top_agl)
		agls = PackedFloat64Array(
			[
				300.0,
				base_agl - 500.0,
				base_agl - 150.0,
				base_agl - 50.0,
				base_agl + 50.0,
				base_agl + 0.25 * (top_agl - base_agl),
				mid,
				base_agl + 0.75 * (top_agl - base_agl),
				top_agl - 50.0,
				top_agl + 50.0,
				top_agl + 300.0,
				top_agl + 800.0,
				maxf(top_agl + 1500.0, 2500.0),
				3000.0,
				3500.0,
				4000.0
			]
		)
		agls = _sorted_unique(agls)
	var haze_mat: ShaderMaterial = game.sky.haze_material()
	var haze_ext: Variant = haze_mat.get_shader_parameter("extinction") if haze_mat != null else null
	_lines.append(HEADER + "," + XCOLS)
	# Варианты: main - как в игре; nowo - без CloudWhiteout; nohaze - дымка выключена;
	# noclouds - без прохода облаков; nofog - туман Environment выключен; bare - всё выключено.
	var variants: Array = [
		["main", true, true, true, true],
		["nowo", false, true, true, true],
		["nohaze", true, false, true, true],
		["noclouds", true, true, false, true],
		["nofog", true, true, true, false],
		["bare", false, false, false, false],
	]
	var n := 0
	for v in variants:
		if not (v[0] in _variants):
			continue
		_use_whiteout = v[1]
		_use_haze = v[2]
		_use_clouds = v[3]
		_use_fog = v[4]
		var vtag: String = v[0]
		var full: bool = vtag == "main"
		for hour in _hours:
			if not full and hour != _hours[0]:
				continue
			game.sky.clock.set_hour(hour)
			var sun_h: Vector3 = game.sky.clock.to_sun()
			var syaw := rad_to_deg(atan2(sun_h.x, -sun_h.z))
			var dir := TerrainGeo.heading_vector(syaw)
			for pitch in _pitches:
				if (not full or hour != _hours[0]) and pitch != _pitches[0]:
					continue
				var look := dir * cos(deg_to_rad(pitch)) + Vector3.UP * sin(deg_to_rad(pitch))
				for agl in agls:
					var p := Vector3(cx, gh + agl, cz)
					# Состояние варианта: мгла сбрасывается (apply при amount 0 возвращает исходный туман).
					_wo.amount = 0.0
					_wo.apply(env)
					if haze_mat != null:
						haze_mat.set_shader_parameter("extinction", haze_ext if _use_haze else 0.0)
					_no_cloud_pass = not _use_clouds
					_place(cam, p, look)
					if layer != null:
						layer.set("_instant", true)
						layer.set("_acc", 1.0e9)
					for i in _settle:
						await RenderingServer.frame_post_draw
						_place(cam, p, look)
					# Как game.gd._process: плотность в точке камеры, мгла - экспонента, затем apply.
					var d_coarse := float(air.call("cloud_density_at", cam.global_position))
					var d := _game_density(layer, air, cam.global_position)
					var d_vis := layer.visible_density_at(cam.global_position) if layer != null else -1.0
					_wo_c.amount = 0.0
					for k in 40:
						_wo_c.update(d_coarse, 0.1)
					if _use_whiteout:
						for k in 40:
							_wo.update(d, 0.1)
						_wo.apply(env)
					if not _use_fog:
						env.fog_enabled = false
					for i in 8:
						await RenderingServer.frame_post_draw
					var name := "climb_%s_%02d_p%d_%05d.png" % [vtag, int(hour), int(-pitch), int(agl)]
					var path := "%s/%s" % [_out, name]
					await _shoot(path)
					var st := _stats(path)
					var sm := field_sample(raster, cx, cz)
					var recs := layer.records().size() if layer != null else -1
					var row: Array = [
						name, _location, hour, cx, cz, p.y, agl, syaw, pitch, sm.y, sm.z, sm.x, d_coarse,
						_wo.amount, env.fog_density, env.fog_light_color.r, env.fog_light_color.g,
						env.fog_light_color.b, env.fog_sky_affect, st.r, st.g, st.b, st.luma, st.std,
						path, game.sky.get_haze_top_msl(), int(env.fog_enabled), gh, col.cmax, recs,
						st.sr, st.sg, st.sb, vtag, d_vis, _wo_c.amount
					]
					_lines.append(",".join(PackedStringArray(row.map(_fmt))))
					n += 1
					if vtag == "main":
						_res.clear_amount_max = maxf(_res.clear_amount_max, _wo.amount)
						_res.clear_amount_coarse_max = maxf(_res.clear_amount_coarse_max, _wo_c.amount)
					_flush()
	if "pass" in _variants:
		n += await _pass_series(game, air, layer, env, cam, haze_mat, haze_ext, cx, cz, gh, base, top_ref, raster)
	if "recs" in _variants:
		n += await _recs_series(game, air, layer, env, cam, haze_mat, haze_ext, cx, cz, gh, raster)
	_flush()
	if _after != "":
		var af := FileAccess.open(_after, FileAccess.WRITE)
		af.store_string(JSON.stringify(_res, "\t") + "\n")
		af.close()
	print("cloud_view_climb_shot: OK, кадров %d, %s" % [n, _csv])
	await _quit(0)


## Плотность, которую подаёт в CloudWhiteout game.gd (CVW-К3): рисуемые облака, иначе грубое поле.
static func _game_density(layer: CloudLayer, air: Node, pos: Vector3) -> float:
	var d := layer.visible_density_at(pos) if layer != null else -1.0
	return d if d >= 0.0 else float(air.call("cloud_density_at", pos))


## CVW-4: центр рисуемого облака рядом с ясным столбцом — точка сетки с плотностью ≥ 0,9 (по
## visible_density_at), ближайшая к столбцу; уровни — 30 и 50 % слоя над основанием.
func _find_visible_cloud(layer: CloudLayer, cx: float, cz: float, base: float, top: float) -> Vector3:
	var best := Vector3.ZERO
	var bd := 1.0e30
	var th := maxf(top - base, 600.0)
	for fr: float in [0.3, 0.5]:
		var y := base + th * fr
		for ix in range(-60, 61):
			for iz in range(-60, 61):
				var x := cx + ix * 100.0
				var z := cz + iz * 100.0
				var dd := Vector2(x - cx, z - cz).length()
				if dd >= bd:
					continue
				if layer.visible_density_at(Vector3(x, y, z)) >= 0.9:
					bd = dd
					best = Vector3(x, y, z)
	return best


## CVW-4: проход камеры вдоль оси x через центр рисуемого облака: от −1000 до +1000 м, шаг 100 м.
func _pass_series(
	game: Game, air: Node, layer: CloudLayer, env: Environment, cam: Camera3D, haze_mat: ShaderMaterial,
	haze_ext: Variant, cx: float, cz: float, gh: float, base: float, top: float, raster: Dictionary,
	center := Vector3.ZERO, tag := "pass", offs: Array = [], look_dir := Vector3.ZERO
) -> int:
	var c := center if center != Vector3.ZERO else _find_visible_cloud(layer, cx, cz, base, top)
	if c == Vector3.ZERO:
		print("cloud_view_climb_shot: pass - рисуемое облако с плотностью >= 0,9 рядом не найдено")
		return 0
	print("cloud_view_climb_shot: pass - центр облака (%.0f, %.0f, %.0f), %.0f м от столбца" % [c.x, c.y, c.z, Vector2(c.x - cx, c.z - cz).length()])
	_use_whiteout = true
	_use_haze = true
	_use_clouds = true
	_use_fog = true
	_no_cloud_pass = false
	if haze_mat != null:
		haze_mat.set_shader_parameter("extinction", haze_ext)
	var hour := _hours[0]
	game.sky.clock.set_hour(hour)
	var sun_h: Vector3 = game.sky.clock.to_sun()
	var syaw := rad_to_deg(atan2(sun_h.x, -sun_h.z))
	var pitch := _pitches[0]
	var look := TerrainGeo.heading_vector(syaw) * cos(deg_to_rad(pitch)) + Vector3.UP * sin(deg_to_rad(pitch))
	if look_dir != Vector3.ZERO:
		look = look_dir
	var is_edge := tag.begins_with("recsedge")
	var n := 0
	if offs.is_empty():
		offs = range(-1000, 1001, 100)
	for off: int in offs:
		var p := Vector3(c.x + off, c.y, c.z)
		_wo.amount = 0.0
		_wo.apply(env)
		_place(cam, p, look)
		if tag.begins_with("recs"):
			layer.field_params["cf_on"] = 0.0  # только записи: слой поля облачности не рисуется и не считается
		for i in _settle:
			await RenderingServer.frame_post_draw
			_place(cam, p, look)
			if tag.begins_with("recs"):
				layer.field_params["cf_on"] = 0.0
		var d_coarse := float(air.call("cloud_density_at", p))
		var d_vis := layer.visible_density_at(p)
		var d := d_vis if d_vis >= 0.0 else d_coarse
		_wo_c.amount = 0.0
		for k in 40:
			_wo_c.update(d_coarse, 0.1)
		if not is_edge:
			for k in 40:
				_wo.update(d, 0.1)
		_wo.apply(env)
		for i in 8:
			await RenderingServer.frame_post_draw
		var name := "%s_%05d.png" % [tag, off + 10000]
		var path := "%s/%s" % [_out, name]
		await _shoot(path)
		var st := _stats(path)
		var sm := field_sample(raster, p.x, p.z)
		var row: Array = [
			tag + "_" + name, _location, hour, p.x, p.z, p.y, off, syaw, pitch, sm.y, sm.z, sm.x, d_coarse,
			_wo.amount, env.fog_density, env.fog_light_color.r, env.fog_light_color.g,
			env.fog_light_color.b, env.fog_sky_affect, st.r, st.g, st.b, st.luma, st.std,
			path, game.sky.get_haze_top_msl(), int(env.fog_enabled), gh, 0.0, layer.records().size(),
			st.sr, st.sg, st.sb, tag, d_vis, _wo_c.amount
		]
		_lines.append(",".join(PackedStringArray(row.map(_fmt))))
		if is_edge:
			_edge_rows.append([float(off), d_vis, st.luma])
		if tag == "pass":
			_res.in_cloud_amount_max = maxf(_res.in_cloud_amount_max, _wo.amount)
			_res.in_cloud_amount_coarse_max = maxf(_res.in_cloud_amount_coarse_max, _wo_c.amount)
		elif tag == "recs" or tag == "recsgap":
			var nrec := layer.records().filter(func(r: PackedFloat32Array) -> bool: return r.size() >= 21 and r[20] > 0.0).size()
			if nrec > 0 and d_vis > 0.0:
				_res.rec_frames += 1
			if d_vis > 0.5:
				_res.rec_in_cloud_amount_max = maxf(_res.rec_in_cloud_amount_max, _wo.amount)
			elif d_vis == 0.0:
				_res.rec_clear_frames += 1
				_res.rec_clear_amount_max = maxf(_res.rec_clear_amount_max, _wo.amount)
		n += 1
		_flush()
	return n


## CVW-5: облака-записи (кучевые, Cb, линзы). Перебирает времена атмосферы (--air_s), пока слой не рисует
## запись с видимостью > 0 и плотностью >= 0,5 в её центре; проход камеры вдоль x через центр.
## Просвет: кадры прохода, где visible_density_at == 0 (камера вне всех рисуемых облаков).
func _recs_series(
	game: Game, air: Node, layer: CloudLayer, env: Environment, cam: Camera3D, haze_mat: ShaderMaterial,
	haze_ext: Variant, cx: float, cz: float, gh: float, raster: Dictionary
) -> int:
	var c := Vector3.ZERO
	for t_air in _air_list:
		game.set_world_time(t_air)
		# облака считаются фоном: ждать, пока атмосфера отдаст объекты на этот момент
		for k in 240:
			if (air.call("cloud_objects", Vector3.ZERO, -1.0, t_air) as PackedFloat32Array).size() > 0:
				break
			await get_tree().create_timer(0.5, true, false, true).timeout
		layer.set("_instant", true)
		for i in 240:
			_place(cam, Vector3(cx, gh + 1500.0, cz), Vector3.FORWARD)  # глаз выбора облаков - у столбца
			layer.set("_acc", 1.0e9)
			await get_tree().process_frame
		# записи рисуются в пределах дальности от глаза: глаз - к ближайшей записи (3 км от центра)
		var near := Vector3.ZERO
		var nd := 1.0e30
		for r in layer.records():
			var dd0 := Vector2(r[0] - cx, r[2] - cz).length()
			if dd0 < nd:
				nd = dd0
				near = Vector3(r[0] - 3000.0, gh + 1500.0, r[2])
		if near != Vector3.ZERO:
			for i in 240:
				_place(cam, near, Vector3.FORWARD)
				layer.set("_acc", 1.0e9)
				await get_tree().process_frame
		var best := 1.0e30
		var objs: PackedFloat32Array = air.call("cloud_objects", Vector3.ZERO, -1.0, t_air)
		print("cloud_view_climb_shot: recs - объектов-облаков в атмосфере %d" % objs.size())
		for r in layer.records():
			print("cloud_view_climb_shot: recs - запись kind %d vis %.2f центр (%.0f, %.0f, %.0f) основание %.0f высота %.0f ось (%.0f, %.0f) бокс %.0f %.0f d=%.0f" % [int(r[19] + 0.5), r[20], r[0], r[1], r[2], r[8], r[9], r[10], r[11], r[6], r[7], Vector2(r[0] - cx, r[2] - cz).length()])
			for fr: float in [0.3, 0.4, 0.5, 0.6]:
				var q := Vector3(r[0], r[8] + fr * maxf(r[9], 10.0), r[2])
				var dd := Vector2(q.x - cx, q.z - cz).length()
				if dd < best and r[20] > 0.5 and layer._rec_density(r, q) >= 0.5:  # именно запись, не слой поля
					best = dd
					c = q
					_res.rec_kind = int(r[19] + 0.5)
		print("cloud_view_climb_shot: recs - время %.0f, записей %d, центр %s" % [t_air, layer.records().size(), c])
		if c != Vector3.ZERO:
			_res.rec_time_s = t_air
			break
	if c == Vector3.ZERO:
		return 0
	# обзор записи снаружи: кадр для сверки, что она рисуется (12 км до центра, взгляд на центр)
	for dist: float in [12000.0, 5000.0]:
		var vp := Vector3(c.x - dist, c.y + 800.0, c.z)
		layer.field_params["cf_on"] = 0.0
		for i in 40:
			_place(cam, vp, (c - vp).normalized())
			layer.field_params["cf_on"] = 0.0
			await RenderingServer.frame_post_draw
		await _shoot("%s/recs_view_%d.png" % [_out, int(dist)])
		print("cloud_view_climb_shot: recs - обзор %d м: записей %d, плотность в центре %.2f" % [int(dist), layer.records().size(), layer.visible_density_at(c)])
	var n: int = await _pass_series(game, air, layer, env, cam, haze_mat, haze_ext, cx, cz, gh, 0.0, 0.0, raster, c, "recs")
	# Просвет: от центра вдоль +x до первой точки вне всех рисуемых облаков (шаг 250 м), там 6 кадров
	var g := c
	while layer.visible_density_at(g) != 0.0 and g.x - c.x < 40000.0:
		g.x += 250.0
	print("cloud_view_climb_shot: recs - просвет в %.0f м от центра записи" % (g.x - c.x))
	if layer.visible_density_at(g) == 0.0:
		n += await _pass_series(game, air, layer, env, cam, haze_mat, haze_ext, cx, cz, gh, 0.0, 0.0, raster, g, "recsgap", [0, 100, 200, 300, 400, 500])
	for sgn in [1, -1]:
		n += await _edge_scan(game, air, layer, env, cam, haze_mat, haze_ext, cx, cz, gh, raster, c, sgn)
	if _res.has("edge_in_m") and _res.has("edge_out_m"):
		_res["edge_offset_measured_m"] = maxf(absf(_res.edge_in_m), absf(_res.edge_out_m))
	return n


## Граница записи вдоль x: CPU-кромка (visible_density = 0,5) и видимая (середина скачка яркости кадра
## при выходе/входе камеры; обзор от облака, мгла выключена), шаг 10 м, ±150 м. sgn +1 - выход, -1 - вход.
func _edge_scan(
	game: Game, air: Node, layer: CloudLayer, env: Environment, cam: Camera3D, haze_mat: ShaderMaterial,
	haze_ext: Variant, cx: float, cz: float, gh: float, raster: Dictionary, c: Vector3, sgn: int
) -> int:
	var e := c
	while layer.visible_density_at(e) >= 0.5 and absf(e.x - c.x) < 40000.0:
		e.x += 25.0 * sgn
	var key := "out" if sgn > 0 else "in"
	var offs: Array = []
	for o in range(-150, 151, 10):
		offs.append(int(e.x - c.x) + o)
	_edge_rows.clear()
	var n: int = await _pass_series(game, air, layer, env, cam, haze_mat, haze_ext, cx, cz, gh, 0.0, 0.0, raster, c, "recsedge_" + key, offs, Vector3(sgn, 0, 0))
	# crossing(d=0.5) по CPU и середина скачка яркости по кадрам
	var lo := 1.0e9
	var hi := -1.0e9
	for r: Array in _edge_rows:
		lo = minf(lo, r[2])
		hi = maxf(hi, r[2])
	var mid := 0.5 * (lo + hi)
	var cpu_x := NAN
	var vis_x := NAN
	for i in range(1, _edge_rows.size()):
		var a: Array = _edge_rows[i - 1]
		var b: Array = _edge_rows[i]
		if is_nan(cpu_x) and (a[1] - 0.5) * (b[1] - 0.5) <= 0.0 and a[1] != b[1]:
			cpu_x = lerpf(a[0], b[0], (0.5 - a[1]) / (b[1] - a[1]))
		if is_nan(vis_x) and (a[2] - mid) * (b[2] - mid) <= 0.0 and a[2] != b[2]:
			vis_x = lerpf(a[0], b[0], (mid - a[2]) / (b[2] - a[2]))
	print("cloud_view_climb_shot: recs - кромка %s: CPU %.1f м, видимая %.1f м, яркость %.3f...%.3f" % [key, cpu_x, vis_x, lo, hi])
	_res["edge_%s_rows" % key] = _edge_rows.duplicate()
	if is_nan(cpu_x) or is_nan(vis_x) or hi - lo < 0.02:
		_res["edge_%s_unreliable" % key] = true
	else:
		_res["edge_%s_m" % key] = vis_x - cpu_x
	return n


static func _fmt(v: Variant) -> String:
	if v is float:
		return String.num(v, 6)
	return str(v)


static func _sorted_unique(a: PackedFloat64Array) -> PackedFloat64Array:
	var l: Array = []
	for x in a:
		if x > 20.0:
			l.append(snappedf(x, 1.0))
	l.sort()
	var o := PackedFloat64Array()
	for x in l:
		if o.is_empty() or x - o[o.size() - 1] >= 20.0:
			o.append(x)
	return o


## Ясная ячейка с облаками рядом; ближайшая к старту. Ступени условий ослабляются, пока не найдётся:
## [порог ясности, чистый радиус вокруг, м; радиус поиска облаков, м; порог облака; дальность от старта, м].
func _find_clear(r: Dictionary, sp: Vector3, game: Game, n_tiers: int = 4) -> Dictionary:
	var nx := int(r.nx)
	var ny := int(r.ny)
	var dx := float(r.dx)
	var cov: PackedFloat32Array = r.cover
	var dep: PackedFloat32Array = r.depth
	var nz := 0
	var cmx := 0.0
	var cmn := 1.0
	var csum := 0.0
	for c in cov:
		if c > 0.05:
			nz += 1
		cmx = maxf(cmx, c)
		cmn = minf(cmn, c)
		csum += c
	print("cloud_view_climb_shot: растр %dx%d dx=%.0f, ячеек cover>0.05: %d, cover мин. %.3f ср. %.3f макс. %.2f, фон %.2f" % [nx, ny, dx, nz, cmn, csum / cov.size(), cmx, float(r.bg_cover[0])])
	var tiers: Array = [
		[0.02, 300.0, 1500.0, 0.5, 4000.0],
		[0.03, 150.0, 2500.0, 0.3, 6000.0],
		[0.05, 0.0, 3500.0, 0.2, 12000.0],
		[0.10, 0.0, 6000.0, 0.1, 1.0e6],
	]
	for tier in tiers.slice(0, n_tiers):
		var best := {}
		var bd := 1.0e30
		var rn := int(ceil(float(tier[2]) / dx))
		var rc := int(ceil(float(tier[1]) / dx))
		for j in range(0, ny):
			for i in range(0, nx):
				var x := float(r.x0) + i * dx
				var z := float(r.z0) + j * dx
				var dd := Vector2(x - sp.x, z - sp.z).length()
				if dd > float(tier[4]) or dd >= bd or cov[j * nx + i] >= float(tier[0]):
					continue
				var ok := true
				if rc > 0:
					for jj in range(maxi(0, j - rc), mini(ny, j + rc + 1)):
						for ii in range(maxi(0, i - rc), mini(nx, i + rc + 1)):
							if cov[jj * nx + ii] > 0.05:
								ok = false
				if not ok:
					continue
				var cmax := 0.0
				var tmax := 0.0
				for jj in range(maxi(0, j - rn), mini(ny, j + rn + 1)):
					for ii in range(maxi(0, i - rn), mini(nx, i + rn + 1)):
						var c := cov[jj * nx + ii]
						cmax = maxf(cmax, c)
						if c > float(tier[3]):
							tmax = maxf(tmax, dep[jj * nx + ii])
				if cmax < float(tier[3]):
					continue
				bd = dd
				best = {"x": x, "z": z, "cmax": cmax, "top": float(r.base_msl) + tmax}
		if not best.is_empty():
			print("cloud_view_climb_shot: ступень поиска %s" % [tier])
			return best
	return {}


func _flush() -> void:
	var f := FileAccess.open(_csv, FileAccess.WRITE)
	f.store_string("\n".join(_lines) + "\n")
	f.close()


func _place(cam: Camera3D, p: Vector3, look: Vector3) -> void:
	cam.look_at_from_position(p, p + look * 1000.0)
	_root_cam.global_transform = cam.global_transform
	if _root_cam.compositor != null:
		cam.compositor = null if _no_cloud_pass else _root_cam.compositor


func _shoot(path: String) -> void:
	for i in 6:
		await RenderingServer.frame_post_draw
	var img := _vp.get_texture().get_image()
	img.save_png(path)


## Средние линейные 0..1 по кадру; sr/sg/sb - верхняя четверть кадра (небо при pitch -3).
func _stats(path: String) -> Dictionary:
	var img := Image.load_from_file(path)
	img.convert(Image.FORMAT_RGB8)
	var w := img.get_width()
	var h := img.get_height()
	var sr := 0.0
	var sg := 0.0
	var sb := 0.0
	var sl := 0.0
	var sl2 := 0.0
	var tr := 0.0
	var tg := 0.0
	var tb := 0.0
	var n := 0
	var nt := 0
	for y in range(0, h, 4):
		for x in range(0, w, 4):
			var c := img.get_pixel(x, y).srgb_to_linear()
			sr += c.r
			sg += c.g
			sb += c.b
			var l := 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
			sl += l
			sl2 += l * l
			n += 1
			if y < h / 4:
				tr += c.r
				tg += c.g
				tb += c.b
				nt += 1
	var m := sl / n
	return {
		"r": sr / n, "g": sg / n, "b": sb / n, "luma": m,
		"std": sqrt(maxf(sl2 / n - m * m, 0.0)),
		"sr": tr / nt, "sg": tg / nt, "sb": tb / nt
	}
