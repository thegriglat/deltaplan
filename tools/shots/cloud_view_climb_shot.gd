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
## x_cloud_recs, x_sky_r/g/b (средний цвет верхней четверти кадра), x_flags.

const MAIN_SCENE := preload("res://scenes/main.tscn")
const TIMEOUT_S := 5000.0
const HEADER := "frame,loc,hour,cam_x,cam_z,cam_y_msl,cam_agl,yaw_deg,pitch_deg,cloud_base_msl,cloud_top_msl,cover_cam,density_cam,whiteout_amount,fog_density,fog_r,fog_g,fog_b,fog_sky_affect,mean_r,mean_g,mean_b,luma_mean,luma_std,png"
const XCOLS := "x_haze_top_msl,x_fog_enabled,x_ground_msl,x_cover_max_near,x_cloud_recs,x_sky_r,x_sky_g,x_sky_b,x_flags"

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
					var d := float(air.call("cloud_density_at", cam.global_position))
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
						name, _location, hour, cx, cz, p.y, agl, syaw, pitch, sm.y, sm.z, sm.x, d,
						_wo.amount, env.fog_density, env.fog_light_color.r, env.fog_light_color.g,
						env.fog_light_color.b, env.fog_sky_affect, st.r, st.g, st.b, st.luma, st.std,
						path, game.sky.get_haze_top_msl(), int(env.fog_enabled), gh, col.cmax, recs,
						st.sr, st.sg, st.sb, vtag
					]
					_lines.append(",".join(PackedStringArray(row.map(_fmt))))
					n += 1
					_flush()
	_flush()
	print("cloud_view_climb_shot: OK, кадров %d, %s" % [n, _csv])
	await _quit(0)


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
