extends Node
## GPU-проверка тона и краёв средней травы (GR-16, tools/gpu_tests.sh --filter=grass_shell_edge): ровный
## луг, настоящий рельеф (TerrainRenderer: палитра terrain_look, поля рельефа, scene_look, солнце 45°)
## и настоящий GrassField (ближние травинки скрыты — сравнивается только средняя дистанция). Камера над
## лугом на 13, 30 и 60 м, четыре курса, два наклона. Каждый пиксель — точка луга на расстоянии r от
## камеры по горизонтали; по кольцам 2 м (0–80 м) — средний цвет кадра со средней травой и без неё
## (только рельеф). Числа, а не подгонка:
## (1) тон: на 30–50 м средняя яркость и цветность (rgb/сумма) с травой отличаются от рельефа ≤ 5 %;
## (2) нет кольца: отношение «с травой / без» между соседними кольцами меняется ≤ 3 % (яркость и
##     цветность), 0–80 м.
## (3) стык с ближними травинками (8–14 м): то же с ближним кольцом — нет скачка между кольцами 4–24 м;
## (4) ворс не ровный: разброс яркости пикселей (σ/среднее) на 15–30 м не ниже NOISE_MIN, выбросов
##     (|L − среднее кольца| > 50 %) не больше OUTLIER_MAX.
## Режим shell (G4 v2).

const SIZE := Vector2i(320, 180)
const FOV := 70.0
const RING_M := 2.0
const RINGS := 40
const MIN_PX := 40
const HEIGHTS: Array[float] = [13.0, 30.0, 60.0]
const PITCHES: Array[float] = [-28.0, -65.0]
const YAWS: Array[float] = [0.0, 90.0, 180.0, 270.0]
const TONE_TOL := 0.05
const STEP_TOL := 0.03
## Луг как на месте замечаний (Онгудай, 4_low_meadow): высота ~1650 м, южный склон SLOPE_DEG
## (сухость южных склонов dry_south_k, свет на склоне), terrain_look с переопределением локации.
const GROUND_H := 1650.0
const SLOPE_DEG := 12.0
const LOCATION := "ongudai"
const NOISE_MIN := 0.04
const OUTLIER_MAX := 0.02

var failures: PackedStringArray = []
var _vp: SubViewport
var _cam: Camera3D
var _field: GrassField
var _renderer: TerrainRenderer
var _layer: HeightLayer


func needs_gpu() -> bool:
	return true


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_grass_shell_edge_shell() -> void:
	await _edge("shell")


func test_grass_shell_edge_junction() -> void:
	await _edge("shell", true)


## near — ближние травинки видны (стык 8–14 м): кадр «вся трава» против «только рельеф».
func _edge(mode: String, near := false) -> void:
	_build(mode)
	for i in 4:
		await RenderingServer.frame_post_draw
	for hgt in HEIGHTS:
		var with_g := _rings()
		var no_g := _rings()
		for yaw in YAWS:
			for pitch in PITCHES:
				_pose(hgt, yaw, pitch)
				# ближние травинки — только в проверке стыка (GrassField сам включает видимость по высоте)
				_field.multimesh.visible_instance_count = -1 if near else 0
				_field.mid_layer.visible = true
				var a := await _shot()
				_field.mid_layer.visible = false
				_field.multimesh.visible_instance_count = 0
				var b := await _shot()
				_accumulate(a, with_g)
				_accumulate(b, no_g)
		if near:
			_judge_junction(mode, hgt, with_g, no_g)
		else:
			_judge(mode, hgt, with_g, no_g)
			_judge_noise(mode, hgt, with_g, no_g)
	_vp.queue_free()


func _rings() -> Dictionary:
	var s := PackedFloat64Array()
	s.resize(RINGS * 3)
	var n := PackedInt32Array()
	n.resize(RINGS)
	var l2 := PackedFloat64Array()
	l2.resize(RINGS * 2)
	var outl := PackedInt32Array()
	outl.resize(RINGS)
	return {"sum": s, "n": n, "l2": l2, "out": outl}


## Кольцо пикселя: луч камеры через центр пикселя до плоскости луга; -1 — небо или дальше 80 м.
func _ring_map() -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(SIZE.x * SIZE.y)
	var o := _cam.global_position
	for y in SIZE.y:
		for x in SIZE.x:
			var d := _cam.project_ray_normal(Vector2(x + 0.5, y + 0.5))
			var k := -1
			var s := _slope()
			var den := d.y - s * d.z
			if den < -1e-3:
				var t := (GROUND_H + s * o.z - o.y) / den
				var r := Vector2(d.x, d.z).length() * t
				k = int(r / RING_M) if r < RING_M * RINGS else -1
			out[y * SIZE.x + x] = k
	return out


func _accumulate(shot: Dictionary, acc: Dictionary) -> void:
	var data: PackedByteArray = shot.data
	var map: PackedInt32Array = shot.map
	var bpp: int = shot.bpp
	var s: PackedFloat64Array = acc.sum
	var n: PackedInt32Array = acc.n
	for i in map.size():
		var k := map[i]
		if k < 0:
			continue
		s[k * 3] += data[i * bpp]
		s[k * 3 + 1] += data[i * bpp + 1]
		s[k * 3 + 2] += data[i * bpp + 2]
		n[k] += 1
	acc.sum = s
	acc.n = n
	# разброс яркости пикселей по кольцам и выбросы относительно среднего кольца в этом кадре
	var lm := PackedFloat64Array()
	lm.resize(RINGS)
	var lc := PackedInt32Array()
	lc.resize(RINGS)
	var lum := PackedFloat32Array()
	lum.resize(map.size())
	for i in map.size():
		var l := 0.2126 * data[i * bpp] + 0.7152 * data[i * bpp + 1] + 0.0722 * data[i * bpp + 2]
		lum[i] = l
		if map[i] >= 0:
			lm[map[i]] += l
			lc[map[i]] += 1
	var l2: PackedFloat64Array = acc.l2
	var outl: PackedInt32Array = acc.out
	for i in map.size():
		var k := map[i]
		if k < 0:
			continue
		var mean := lm[k] / maxf(lc[k], 1.0)
		var dv := lum[i] - mean
		l2[k * 2] += dv * dv
		l2[k * 2 + 1] += mean * mean
		if absf(dv) > 0.5 * mean:
			outl[k] += 1
	acc.l2 = l2
	acc.out = outl


func _shot() -> Dictionary:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := _vp.get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	return {"data": img.get_data(), "map": _ring_map(), "bpp": 3}


func _mean(acc: Dictionary, k: int) -> Vector3:
	var c: int = acc.n[k]
	var s: PackedFloat64Array = acc.sum
	return Vector3(s[k * 3], s[k * 3 + 1], s[k * 3 + 2]) / maxf(float(c), 1.0) / 255.0


static func _lum(c: Vector3) -> float:
	return c.dot(Vector3(0.2126, 0.7152, 0.0722))


static func _chroma(c: Vector3) -> Vector3:
	return c / maxf(c.x + c.y + c.z, 1e-4)


## Яркость «с травой / без» и сдвиг цветности (|Δ(rgb/сумма)| / |rgb/сумма| рельефа) по кольцам.
func _judge(mode: String, hgt: float, wg: Dictionary, ng: Dictionary) -> void:
	var lum_k := PackedFloat32Array()
	var chr := PackedFloat32Array()
	var ok := PackedByteArray()
	var line := ""
	var near_l := 0.0
	var near_c := 0.0
	var near_n := 0
	for k in RINGS:
		var valid: bool = wg.n[k] >= MIN_PX and ng.n[k] >= MIN_PX
		ok.append(1 if valid else 0)
		var a := _mean(wg, k)
		var b := _mean(ng, k)
		var lk := _lum(a) / maxf(_lum(b), 1e-4)
		var cb := _chroma(b)
		var cd := (_chroma(a) - cb).length() / maxf(cb.length(), 1e-4)
		lum_k.append(lk)
		chr.append(cd)
		if valid:
			line += " %d:%.2f/%.2f" % [int(k * RING_M), lk, cd]
			var r := (k + 0.5) * RING_M
			if r >= 30.0 and r <= 50.0:
				near_l += lk
				near_c += cd
				near_n += 1
	var k20 := int(20.0 / RING_M)
	print("    shell_edge %s %d м: 20 м — rgb с травой %s, без %s" % [mode, int(hgt), _mean(wg, k20), _mean(ng, k20)])
	print("    shell_edge %s %d м: кольцо:яркость с травой/без / сдвиг цветности —%s" % [mode, int(hgt), line])
	if near_n > 0:
		near_l /= near_n
		near_c /= near_n
		print("    shell_edge %s %d м: 30–50 м — яркость %.3f, цветность %.3f" % [mode, int(hgt), near_l, near_c])
		check(absf(near_l - 1.0) <= TONE_TOL, "%s %d м: яркость на 30–50 м %.3f от рельефа" % [mode, int(hgt), near_l])
		check(near_c <= TONE_TOL, "%s %d м: цветность на 30–50 м сдвинута на %.3f" % [mode, int(hgt), near_c])
	else:
		check(false, "%s %d м: нет колец 30–50 м в кадрах" % [mode, int(hgt)])
	var worst_l := 0.0
	var worst_c := 0.0
	for k in RINGS - 1:
		if ok[k] == 0 or ok[k + 1] == 0:
			continue
		worst_l = maxf(worst_l, absf(lum_k[k + 1] - lum_k[k]))
		worst_c = maxf(worst_c, absf(chr[k + 1] - chr[k]))
	print("    shell_edge %s %d м: худший скачок между кольцами — яркость %.3f, цветность %.3f" % [mode, int(hgt), worst_l, worst_c])
	check(worst_l <= STEP_TOL, "%s %d м: скачок яркости между кольцами %.3f" % [mode, int(hgt), worst_l])
	check(worst_c <= STEP_TOL, "%s %d м: скачок цветности между кольцами %.3f" % [mode, int(hgt), worst_c])


## Ворс: σ яркости пикселей / среднее на 15–30 м (с травой и без), доля выбросов.
func _judge_noise(mode: String, hgt: float, wg: Dictionary, ng: Dictionary) -> void:
	var cv := [0.0, 0.0]
	var outs := 0
	var cnt := 0
	var accs := [wg, ng]
	for j in 2:
		var var_s := 0.0
		var mean_s := 0.0
		for k in RINGS:
			var r := (k + 0.5) * RING_M
			if r < 15.0 or r > 30.0:
				continue
			var a: Dictionary = accs[j]
			var_s += a.l2[k * 2]
			mean_s += a.l2[k * 2 + 1]
			if j == 0:
				outs += a.out[k]
				cnt += a.n[k]
		cv[j] = sqrt(var_s / maxf(mean_s, 1e-6))
	var share := float(outs) / maxf(cnt, 1.0)
	print("    shell_edge %s %d м: ворс 15–30 м — σ/среднее %.3f (рельеф %.3f), выбросов %.4f" % [mode, int(hgt), cv[0], cv[1], share])
	check(cv[0] >= NOISE_MIN, "%s %d м: ворс ровный, σ/среднее %.3f" % [mode, int(hgt), cv[0]])
	check(share <= OUTLIER_MAX, "%s %d м: выбросов яркости %.4f" % [mode, int(hgt), share])


## Стык (ближние травинки + средняя трава против рельефа): нет скачка между кольцами 4–24 м.
func _judge_junction(mode: String, hgt: float, wg: Dictionary, ng: Dictionary) -> void:
	var line := ""
	var prev_l := -1.0
	var prev_c := -1.0
	var worst_l := 0.0
	var worst_c := 0.0
	for k in RINGS:
		var r := (k + 0.5) * RING_M
		if r < 4.0 or r > 24.0:
			continue
		if wg.n[k] < MIN_PX or ng.n[k] < MIN_PX:
			prev_l = -1.0
			continue
		var a := _mean(wg, k)
		var b := _mean(ng, k)
		var lk := _lum(a) / maxf(_lum(b), 1e-4)
		var cb := _chroma(b)
		var cd := (_chroma(a) - cb).length() / maxf(cb.length(), 1e-4)
		line += " %d:%.2f/%.2f" % [int(k * RING_M), lk, cd]
		if prev_l >= 0.0:
			worst_l = maxf(worst_l, absf(lk - prev_l))
			worst_c = maxf(worst_c, absf(cd - prev_c))
		prev_l = lk
		prev_c = cd
	print("    shell_edge стык %s %d м:%s" % [mode, int(hgt), line])
	print("    shell_edge стык %s %d м: худший скачок — яркость %.3f, цветность %.3f" % [mode, int(hgt), worst_l, worst_c])
	check(worst_l <= STEP_TOL, "стык %s %d м: скачок яркости %.3f" % [mode, int(hgt), worst_l])
	check(worst_c <= STEP_TOL, "стык %s %d м: скачок цветности %.3f" % [mode, int(hgt), worst_c])


## Уклон плоскости луга dh/dz: высота убывает к +Z (на юг) — склон смотрит на юг.
static func _slope() -> float:
	return -tan(deg_to_rad(SLOPE_DEG))


func _pose(hgt: float, yaw: float, pitch: float) -> void:
	var b := Basis.from_euler(Vector3(deg_to_rad(pitch), deg_to_rad(yaw), 0.0), EULER_ORDER_YXZ)
	var p := Vector3(0.7, GROUND_H - 0.4 * _slope() + hgt, -0.4)
	_cam.global_transform = Transform3D(b, p)


## Ровный луг 320×320 м (шаг 2 м), все клетки — луг; рельеф и трава — из тех же конфигов, что в игре.
func _build(mode: String) -> void:
	var n := 161
	var step := 2.0
	var o := -float(n - 1) * step * 0.5
	var hs := PackedFloat32Array()
	hs.resize(n * n)
	for j in n:
		for i in n:
			hs[j * n + i] = GROUND_H + _slope() * (o + j * step)
	_layer = HeightLayer.from_heights("t", n, n, step, o, o, hs)
	var sn := 80
	var ss := 4.0
	var cls := PackedByteArray()
	cls.resize(sn * sn)
	cls.fill(SurfaceLayer.GRASS)
	var surf := SurfaceLayer.from_classes("s", sn, sn, ss, -sn * ss * 0.5, -sn * ss * 0.5, cls)
	var world: Dictionary = Config.get_config("world")
	var loc: Dictionary = Config.get_config("locations/" + LOCATION)
	var look: Dictionary = Config._deep_merge(world.get("terrain_look", {}), loc.get("terrain_look", {}))
	var sun_dir := Vector3(0.0, sin(deg_to_rad(45.0)), cos(deg_to_rad(45.0))).rotated(Vector3.UP, deg_to_rad(30.0))
	look["sun_dir"] = sun_dir
	var relief := TerrainRelief.compute(_layer, world.get("surface", {}).get("relief", {}), 210.0)

	_vp = SubViewport.new()
	_vp.own_world_3d = true
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.msaa_3d = Viewport.MSAA_2X
	_vp.size = SIZE
	add_child(_vp)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.5, 0.6, 0.8)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.45, 0.5, 0.6)
	var we := WorldEnvironment.new()
	we.environment = env
	_vp.add_child(we)
	var sun := DirectionalLight3D.new()
	_vp.add_child(sun)
	sun.look_at_from_position(Vector3.ZERO, -sun_dir, Vector3.UP)
	_cam = Camera3D.new()
	_cam.far = 2000.0
	_cam.fov = FOV
	_vp.add_child(_cam)
	_cam.make_current()

	_renderer = TerrainRenderer.new()
	_vp.add_child(_renderer)
	_renderer.lod_camera = _cam
	var rcfg := {"t": {"chunk_cells": 32, "lod_distances_m": [2000.0], "skirt_depth_m": 2.0}}
	var layers: Array[HeightLayer] = [_layer]
	var surfs: Array[SurfaceLayer] = [surf]
	var reliefs: Array[TerrainRelief] = [relief]
	_renderer.build(layers, surfs, rcfg, look, world.get("rendering", {}), reliefs)

	var cfg: Dictionary = (Config.get_config("vegetation").grass as Dictionary).duplicate(true)
	cfg.mid.mode = mode
	_field = GrassField.new()
	_field.camera = _cam
	_vp.add_child(_field)
	var spots: Array[Vector4] = []
	_field.setup(_layer, _renderer.height_textures[0], surf, _renderer.surface_textures[0], look, cfg, spots)
	_field.set_relief(relief)
	_field.multimesh.visible_instance_count = 0   # ближние травинки — не предмет проверки

	var sl: Dictionary = (world.get("scene_look", {}) as Dictionary).duplicate(true)
	sl["lat_deg"] = 50.0
	sl["doy"] = 180
	sl["treeline_h"] = Terrain.treeline_height(50.0, sl)
	sl.merge(TerrainRenderer.scene_look_sky(sun_dir), true)
	_renderer.apply_scene_look(sl)
	_field.apply_scene_look(sl)
