extends Node
## Проход камеры сквозь облако (CVW-2): смена цвета ДРУГИХ облаков при входе, выходе и у кромки.
## Полёт над стартом запускается как из меню, время атмосферы заморожено (как cloud_cut_shot),
## камера идёт по прямой через облако рядом со стартом на высоте его середины, взгляд вбок — на
## другие облака. Кадры идут подряд (dt = 1/60 с на кадр), мгла CloudWhiteout обновляется так же,
## как в game.gd::_process (update + apply к sky.world_env.environment).
## Запуск:
##   godot --path . --audio-driver Dummy --resolution 1920x1080 \
##     res://tools/shots/cloud_view_edge_shot.tscn -- --out=<каталог PNG> --csv=<measures.csv> \
##     [--loc=ongudai] [--hour=13] [--mode=game|nowhiteout|fixedfog] [--speed=40] [--step=12] \
##     [--air_s=600] [--pitch=2] [--side=auto|left|right] [--pre=300] [--post=300] [--tag=]
## mode: fogon — туман окружения включён с исходными параметрами, мгла не вызывается (проверка скачка от самого fog_enabled).
## mode: cloudfogfix — как game, но дымка облаков (cloud_layer) остаётся «по умолчанию»: проверка механизма.
## mode: game — мгла как в игре; nowhiteout — мгла не вызывается (туман окружения исходный);
## fixedfog — мгла считается, но apply не вызывается (проверка, что дело не в самом update).
## Строка CSV на снимок (контракт CVW-К1 + доп. колонки x_*, см. README). Код выхода 0/1.

const MAIN_SCENE := preload("res://scenes/main.tscn")
const TIMEOUT_S := 1500.0
const HEADER := (
	"frame,loc,hour,cam_x,cam_z,cam_y_msl,cam_agl,yaw_deg,pitch_deg,cloud_base_msl,"
	+ "cloud_top_msl,cover_cam,density_cam,whiteout_amount,fog_density,fog_r,fog_g,fog_b,"
	+ "fog_sky_affect,mean_r,mean_g,mean_b,luma_mean,luma_std,png,"
	+ "x_mode,x_s_m,x_edge_dist_m,x_in_density,x_own_frac,x_mask_frac,"
	+ "x_other_r,x_other_g,x_other_b,x_other_luma,x_other_noclouds_luma,"
	+ "x_bg_r,x_bg_g,x_bg_b,x_bg_luma,x_fog_height_density,x_nc_luma_mean"
)
const GW := 192
const GH := 108
const DT := 1.0 / 60.0

var _out := ""
var _csv := ""
var _location := "ongudai"
var _temp_c := 31.0
var _wind_kmh := 18.0
var _hour := 13.0
var _mode := "game"
var _speed := 40.0
var _step := 12.0
var _air_s := 600.0
var _pitch := 2.0
var _side := "auto"
var _pre := 300.0
var _post := 300.0
var _tag := ""
var _paths := "h,v"
var _save_nc := false
var _vmax := 1.0e9  ## --vmax=: потолок вертикального прохода, м над основанием
var _layer: CloudLayer = null
var _main: Node = null
var _vp: SubViewport = null  ## кадр с облаками
var _vp0: SubViewport = null  ## тот же вид без облаков (маска облаков)
var _root_cam: Camera3D = null
var _cam: Camera3D = null
var _cam0: Camera3D = null


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		if kv.size() != 2:
			continue
		match kv[0]:
			"out": _out = kv[1]
			"csv": _csv = kv[1]
			"loc": _location = kv[1]
			"temp": _temp_c = float(kv[1])
			"wind": _wind_kmh = float(kv[1]) * 3.6
			"hour": _hour = float(kv[1])
			"mode": _mode = kv[1]
			"speed": _speed = float(kv[1])
			"step": _step = float(kv[1])
			"air_s": _air_s = float(kv[1])
			"pitch": _pitch = float(kv[1])
			"side": _side = kv[1]
			"pre": _pre = float(kv[1])
			"post": _post = float(kv[1])
			"tag": _tag = kv[1]
			"paths": _paths = kv[1]
			"save_nc": _save_nc = kv[1] == "1"
			"vmax": _vmax = float(kv[1])
	if _out == "" or _csv == "":
		push_error("cloud_view_edge_shot: нужны --out= и --csv=")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	get_tree().create_timer(TIMEOUT_S).timeout.connect(_fail.bind("таймаут"))
	_run()


func _fail(why: String) -> void:
	print("cloud_view_edge_shot: FAIL (%s)" % why)
	await _quit(1)


func _quit(code: int) -> void:
	if is_instance_valid(_main):
		_main.queue_free()
	for i in 2:
		await get_tree().process_frame
	await get_tree().create_timer(0.1, true).timeout
	get_tree().quit(code)


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
	s.start_hour = _hour
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
	var t0: float = air.time_s
	var t := 0.0
	while t < _air_s:
		t += 5.0
		air.call("advance_to", t0 + t)
		await get_tree().process_frame
	var start: Dictionary = game.get_start()
	var p0: Vector3 = start.position
	_setup_views()
	var layer := air.get_node_or_null("Clouds") as CloudLayer
	_layer = layer
	if layer == null:
		_fail("нет слоя облаков")
		return
	# Облака у старта: выбрать камерой и дать слою их отобразить.
	_place(p0 + Vector3.UP * 1500.0, Vector3.FORWARD)
	_keep_visible(layer)
	for i in 90:
		await RenderingServer.frame_post_draw
		_keep_visible(layer)
	var raster: Dictionary = air.call("cloud_raster")
	print("cloud_view_edge_shot: записей облаков (Cb) %d, старт %.0f м MSL" % [layer.records().size(), p0.y])
	var pick := _pick_cloud(air, game, raster, p0)
	if pick.is_empty():
		_fail("нет подходящего облака на проходе")
		return
	var hdir: Vector3 = pick.dir
	var side_sign: int = _choose_side(raster, pick.org, hdir)
	var look_h: Vector3 = hdir.cross(Vector3.UP) * side_sign
	var look := look_h * cos(deg_to_rad(_pitch)) + Vector3.UP * sin(deg_to_rad(_pitch))
	var yaw_deg := rad_to_deg(atan2(look_h.x, -look_h.z))
	var picks: Array = []
	for kind in _paths.split(","):
		picks.append(pick if kind == "h" else _pick_vertical(pick, raster))
	var wo: CloudWhiteout = game.get("_whiteout")
	var env: Environment = game.sky.world_env.environment
	var f := FileAccess.open(_csv, FileAccess.READ_WRITE if FileAccess.file_exists(_csv) else FileAccess.WRITE)
	if f.get_length() == 0:
		f.store_line(HEADER)
	f.seek_end()
	for pk in picks:
		var path := _make_path(air, pk)
		var dir: Vector3 = path.dir
		print(
			(
				"cloud_view_edge_shot: проход %s (%s), s=[%.0f..%.0f] м, входы %s, выходы %s, сторона %d, yaw %.0f"
				% [pk.id, pk.kind, path.s0, path.s1, path.entries, path.exits, side_sign, yaw_deg]
			)
		)
		for mode in _mode.split(","):
			# Сброс: исходный туман окружения, мгла 0, камера у начала прохода, прогрев кадров.
			wo.amount = 0.0
			wo.apply(env)
			layer.set("_light_acc", -1.0e9 if mode == "cloudfogfix" else 0.0)
			if mode == "fogon":
				# Только включить туман окружения (fog_enabled), параметры исходные: мгла не вызывается.
				env.fog_enabled = true
			_place(path.origin + dir * float(path.s0), look)
			_keep_visible(layer)
			for i in 90:
				_tick_whiteout(game, air, path.origin + dir * float(path.s0), mode)
				await RenderingServer.frame_post_draw
			var n := await _pass(f, game, air, raster, path, look, yaw_deg, layer, mode, str(pk.kind))
			print("cloud_view_edge_shot: проход %s режим %s, снимков %d" % [pk.kind, mode, n])
	f.close()
	print("cloud_view_edge_shot: OK")
	await _quit(0)


## Мгла — как в game.gd::_process (update + apply); возвращает плотность у камеры.
func _tick_whiteout(game: Game, air: Node, pos: Vector3, mode: String) -> float:
	var wo: CloudWhiteout = game.get("_whiteout")
	var env: Environment = game.sky.world_env.environment
	var d := float(air.call("cloud_density_at", pos))
	if mode != "nowhiteout" and (d > 0.0 or wo.amount > 0.0):
		wo.update(d, DT)
		if mode == "game" or mode == "cloudfogfix":
			wo.apply(env)
		if mode == "cloudfogfix" and _layer != null:
			# Облака берут дымку из окружения только при fog_enabled (cloud_layer._update_light):
			# обновляем их свет при выключенном тумане — параметры дымки облаков остаются «по умолчанию»,
			# а сцена (небо, рельеф) получает мглу как в игре.
			var on := env.fog_enabled
			env.fog_enabled = false
			_layer.call("_update_light")
			env.fog_enabled = on
	return d


func _pass(
	f: FileAccess, game: Game, air: Node, raster: Dictionary, path: Dictionary, look: Vector3,
	yaw_deg: float, layer: CloudLayer, mode: String, kind: String
) -> int:
	var dir: Vector3 = path.dir
	var s_now: float = path.s0
	var next_shot: float = path.s0
	var idx := 0
	while s_now <= path.s1:
		var pos: Vector3 = path.origin + dir * s_now
		_place(pos, look)
		if idx % 20 == 0:
			_keep_visible(layer)
		var d := _tick_whiteout(game, air, pos, mode)
		var edge := _edge_dist(path, s_now)
		var step := _step if absf(edge) <= 100.0 else maxf(_step * 5.0, 60.0)
		if s_now >= next_shot:
			await _shoot_row(f, game, air, raster, pos, yaw_deg, d, edge, s_now, idx, mode + "_" + kind)
			next_shot = s_now + step
			idx += 1
		else:
			await RenderingServer.frame_post_draw
		s_now += _speed * DT
	return idx


func _setup_views() -> void:
	_vp = SubViewport.new()
	_vp.size = Vector2i(1920, 1080)
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_vp)
	_cam = Camera3D.new()
	_vp.add_child(_cam)
	SkyEnvironment.setup_camera(_cam)
	_cam.make_current()
	# Второй вид (без компоситора облаков) — только на снимках: по разности находим пиксели облаков.
	_vp0 = SubViewport.new()
	_vp0.size = Vector2i(1920, 1080)
	_vp0.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_vp0)
	_cam0 = Camera3D.new()
	_vp0.add_child(_cam0)
	SkyEnvironment.setup_camera(_cam0)
	_cam0.make_current()
	_root_cam = Camera3D.new()
	add_child(_root_cam)
	SkyEnvironment.setup_camera(_root_cam)
	_root_cam.make_current()
	get_viewport().disable_3d = true


func _place(p: Vector3, look: Vector3) -> void:
	_cam.look_at_from_position(p, p + look * 1000.0)
	_cam0.global_transform = _cam.global_transform
	_root_cam.global_transform = _cam.global_transform
	if _root_cam.compositor != null:
		_cam.compositor = _root_cam.compositor


func _keep_visible(layer: CloudLayer) -> void:
	layer.set("_instant", true)
	layer.set("_acc", 1.0e9)


## Горизонтальный проход: по растру поля облаков (cover/depth, base_msl) — столбцы ближе 12 км от
## старта, линии через столбец в 8 направлениях на высоте середины слоя (base + depth/2 столбца),
## плотность cloud_density_many (грубое поле: cover × профиль, то же, что игра подаёт в мглу)
## через 4 м; окно 2400 м с наибольшим размахом плотности (max − min). Камера выше рельефа ≥ 30 м.
func _pick_cloud(air: Node, game: Game, raster: Dictionary, p0: Vector3) -> Dictionary:
	if int(raster.get("version", 0)) <= 0:
		return {}
	var nx := int(raster.nx)
	var ny := int(raster.ny)
	var dx := float(raster.dx)
	var base := float(raster.base_msl)
	var cover: PackedFloat32Array = raster.cover
	var depth: PackedFloat32Array = raster.depth
	var cols: Array = []
	var cmax := 0.0
	for iz in ny:
		for ix in nx:
			var c := cover[iz * nx + ix]
			cmax = maxf(cmax, c)
			var x := float(raster.x0) + ix * dx
			var z := float(raster.z0) + iz * dx
			var dh := Vector2(x - p0.x, z - p0.z).length()
			if c > 0.1 and depth[iz * nx + ix] > 300.0 and dh < 12000.0:
				cols.append([dh, x, z, c, depth[iz * nx + ix]])
	cols.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var cs := PackedFloat32Array()
	for c in cols:
		cs.append(c[3])
	cs.sort()
	print(
		"cloud_view_edge_shot: растр %dx%d dx=%.0f base=%.0f cover max %.2f; столбцов %d, cover p10/p50/p90 %.2f/%.2f/%.2f"
		% [nx, ny, dx, base, cmax, cols.size(), cs[cs.size() / 10], cs[cs.size() / 2], cs[cs.size() * 9 / 10]]
	)
	var best := {}
	var best_score := -1.0
	var n := 2000
	var win := 600
	for k in mini(cols.size(), 60):
		var col: Array = cols[k]
		var y: float = base + float(col[4]) * 0.5
		var gy := float(game.terrain.height_at(col[1], col[2]))
		if y - gy < 30.0:
			continue
		for di in 8:
			var ang := PI * di / 8.0
			var dir := Vector3(cos(ang), 0.0, sin(ang))
			var org := Vector3(col[1], y, col[2])
			var pts := PackedVector3Array()
			for j in n:
				pts.append(org + dir * (-4000.0 + 4.0 * j))
			var dens: PackedFloat32Array = air.call("cloud_density_many", pts)
			for j0 in range(0, n - win, 100):
				var lo := 2.0
				var hi := -1.0
				for j in range(j0, j0 + win):
					lo = minf(lo, dens[j])
					hi = maxf(hi, dens[j])
				var sc := hi - lo
				if sc > best_score:
					best_score = sc
					best = {
						"id": "col%d_d%d" % [k, di], "dir": dir, "org": org, "kind": "h",
						"s_a": -4000.0 + 4.0 * j0, "s_b": -4000.0 + 4.0 * (j0 + win), "col": col,
						"dmin": lo, "dmax": hi,
					}
	print("cloud_view_edge_shot: горизонтальный проход %s, плотность %.2f..%.2f" % [best.get("id", "-"), best.get("dmin", -1.0), best.get("dmax", -1.0)])
	return best


## Вертикальный проход через слой над тем же столбцом: от base − 300 до base + depth + 300.
func _pick_vertical(h: Dictionary, raster: Dictionary) -> Dictionary:
	var col: Array = h.col
	var base := float(raster.base_msl)
	var org := Vector3(col[1], base, col[2])
	return {
		"id": "v_" + str(h.id), "dir": Vector3.UP, "org": org, "kind": "v",
		"s_a": -300.0, "s_b": minf(float(col[4]) + 300.0, _vmax), "col": col,
	}


## Линия прохода и плотность на ней через 2 м: границы входа/выхода по порогу 0,05.
func _make_path(air: Node, pick: Dictionary) -> Dictionary:
	var dir: Vector3 = pick.dir
	var org: Vector3 = pick.org
	var s_lo: float = float(pick.s_a)
	var s_hi: float = float(pick.s_b)
	var n := int((s_hi - s_lo) / 2.0)
	var pts := PackedVector3Array()
	for j in n:
		pts.append(org + dir * (s_lo + 2.0 * j))
	var dens: PackedFloat32Array = air.call("cloud_density_many", pts)
	var inside := PackedByteArray()
	var entries: Array = []
	var exits: Array = []
	var prev := false
	for j in n:
		var inn := dens[j] > 0.05
		inside.append(1 if inn else 0)
		if inn and not prev:
			entries.append(snappedf(s_lo + 2.0 * j, 1.0))
		if not inn and prev:
			exits.append(snappedf(s_lo + 2.0 * j, 1.0))
		prev = inn
	return {
		"dir": dir, "origin": org, "s_lo": s_lo, "inside": inside, "s0": s_lo, "s1": s_hi - 2.0,
		"entries": entries, "exits": exits,
	}


## Со знаком: + внутри (м до ближайшего «вне»), − снаружи (м до ближайшего «внутри»), по линии.
func _edge_dist(path: Dictionary, s: float) -> float:
	var ins: PackedByteArray = path.inside
	var j := clampi(int(round((s - float(path.s_lo)) / 2.0)), 0, ins.size() - 1)
	var cur := ins[j]
	var k := 0
	while true:
		k += 1
		var lo := j - k
		var hi := j + k
		if lo < 0 and hi >= ins.size():
			return 1.0e4 * (1.0 if cur == 1 else -1.0)
		if (lo >= 0 and ins[lo] != cur) or (hi < ins.size() and ins[hi] != cur):
			return 2.0 * k * (1.0 if cur == 1 else -1.0)
	return 0.0


## Сторона взгляда: где больше столбцов cover > 0,3 в конусе ±40° и до 15 км.
func _choose_side(raster: Dictionary, org: Vector3, dir: Vector3) -> int:
	if _side == "left":
		return -1
	if _side == "right":
		return 1
	var nx := int(raster.nx)
	var ny := int(raster.ny)
	var dx := float(raster.dx)
	var cover: PackedFloat32Array = raster.cover
	var score := {1: 0.0, -1: 0.0}
	for iz in ny:
		for ix in nx:
			if cover[iz * nx + ix] < 0.3:
				continue
			var to := Vector3(float(raster.x0) + ix * dx - org.x, 0.0, float(raster.z0) + iz * dx - org.z)
			var l := to.length()
			if l < 800.0 or l > 15000.0:
				continue
			for sg in [1, -1]:
				var lk: Vector3 = dir.cross(Vector3.UP) * sg
				if rad_to_deg(lk.angle_to(to)) < 40.0:
					score[sg] += cover[iz * nx + ix]
	print("cloud_view_edge_shot: сторона: вправо %.1f, влево %.1f" % [score[1], score[-1]])
	return 1 if score[1] >= score[-1] else -1


func _shoot_row(
	f: FileAccess, game: Game, air: Node, raster: Dictionary, pos: Vector3, yaw_deg: float,
	d: float, edge: float, s: float, idx: int, mode: String
) -> void:
	# Снимок без облаков — для маски. Рендерим оба вида в одном кадре.
	_vp0.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := _vp.get_texture().get_image()
	var img0 := _vp0.get_texture().get_image()
	var name := "%s_h%02d_%s_%03d.png" % [_location, int(_hour * 10), mode + _tag, idx]
	var path := "%s/%s" % [_out, name]
	img.save_png(path)
	if _save_nc:
		img0.save_png(path.replace(".png", "_nc.png"))
	var wo: CloudWhiteout = game.get("_whiteout")
	var env: Environment = game.sky.world_env.environment
	var st := _stats(img, img0, pos, air)
	var agl := pos.y - float(game.terrain.height_at(pos.x, pos.z))
	var cover := _raster_at(raster, "cover", pos)
	var depth := _raster_at(raster, "depth", pos)
	var base := float(raster.get("base_msl", NAN))
	var top := base + depth if not is_nan(depth) and not is_nan(base) else NAN
	var row: Array = [
		name, _location, _hour, pos.x, pos.z, pos.y, agl, yaw_deg, _pitch, base, top, cover, d,
		wo.amount, env.fog_density, env.fog_light_color.r, env.fog_light_color.g,
		env.fog_light_color.b, env.fog_sky_affect, st.mr, st.mg, st.mb, st.lm, st.ls, path,
		mode + _tag, s, edge, 1 if d > 0.05 else 0, st.inbox, st.mask_frac,
		st.or, st.og, st.ob, st.ol, st.ol0, st.br, st.bg, st.bb, st.bl, env.fog_height_density, st.l0,
	]
	f.store_line(",".join(row.map(_fmt)))
	f.flush()


static func _fmt(v: Variant) -> String:
	if v is float:
		if is_nan(v):
			return ""
		return String.num(v, 5)
	return str(v)


func _raster_at(raster: Dictionary, ch: String, p: Vector3) -> float:
	if int(raster.get("version", 0)) <= 0 or not raster.has(ch):
		return NAN
	var nx := int(raster.nx)
	var ny := int(raster.ny)
	var ix := int(round((p.x - float(raster.x0)) / float(raster.dx)))
	var iz := int(round((p.z - float(raster.z0)) / float(raster.dx)))
	if ix < 0 or iz < 0 or ix >= nx or iz >= ny:
		return NAN
	return float((raster[ch] as PackedFloat32Array)[iz * nx + ix])


static func _lin(c: Color) -> Color:
	return c.srgb_to_linear()


## Статистика кадра: весь кадр (линейные), пиксели облаков (разность с видом без облаков > порога)
## без «своего» облака (на луче есть плотность > 0,05 ближе 500 м) — «другие облака», и фон.
func _stats(img: Image, img0: Image, _pos: Vector3, _air: Node) -> Dictionary:
	var w := img.get_width()
	var h := img.get_height()
	var r := {}
	var n := GW * GH
	var sum := Vector3.ZERO
	var l_sum := 0.0
	var l_sq := 0.0
	var l0_sum := 0.0
	var o_sum := Vector3.ZERO
	var o_n := 0
	var o0_l := 0.0
	var b_sum := Vector3.ZERO
	var b_n := 0
	var m_n := 0
	for j in GH:
		for i in GW:
			var x := int((i + 0.5) / GW * w)
			var y := int((j + 0.5) / GH * h)
			var c := _lin(img.get_pixel(x, y))
			var c0 := _lin(img0.get_pixel(x, y))
			var l := 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
			sum += Vector3(c.r, c.g, c.b)
			l_sum += l
			l_sq += l * l
			l0_sum += 0.2126 * c0.r + 0.7152 * c0.g + 0.0722 * c0.b
			var diff := maxf(absf(c.r - c0.r), maxf(absf(c.g - c0.g), absf(c.b - c0.b)))
			if diff > 0.01:
				m_n += 1
				o_sum += Vector3(c.r, c.g, c.b)
				o_n += 1
				o0_l += 0.2126 * c0.r + 0.7152 * c0.g + 0.0722 * c0.b
			else:
				b_sum += Vector3(c.r, c.g, c.b)
				b_n += 1
	r.mr = sum.x / n
	r.mg = sum.y / n
	r.mb = sum.z / n
	r.lm = l_sum / n
	r.ls = sqrt(maxf(l_sq / n - r.lm * r.lm, 0.0))
	r.l0 = l0_sum / n
	r.inbox = NAN  ## x_own_frac: не определяется (поле плотности гладкое, «своё» облако не выделить)
	r.mask_frac = float(m_n) / n
	var nan := NAN
	r.or = o_sum.x / o_n if o_n > 20 else nan
	r.og = o_sum.y / o_n if o_n > 20 else nan
	r.ob = o_sum.z / o_n if o_n > 20 else nan
	r.ol = (0.2126 * r.or + 0.7152 * r.og + 0.0722 * r.ob) if o_n > 20 else nan
	r.ol0 = o0_l / o_n if o_n > 20 else nan
	r.br = b_sum.x / b_n if b_n > 20 else nan
	r.bg = b_sum.y / b_n if b_n > 20 else nan
	r.bb = b_sum.z / b_n if b_n > 20 else nan
	r.bl = (0.2126 * r.br + 0.7152 * r.bg + 0.0722 * r.bb) if b_n > 20 else nan
	return r
