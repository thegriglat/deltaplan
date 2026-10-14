extends Node
## SL-27 (GPU, tools/gpu_tests.sh --filter=relief_near_shadow): тень хребта у пилота. На Шымбулаке
## (15.12, полдень, солнце 23,6° на юге) вокруг пилота было светло, а дальше тень гор — правильная:
## ближе relief_shadow_near_m (2,2–3 км) тень горизонта рельефа гасилась в расчёте на тени Godot,
## а те от далёкого заслона у края своей дальности (затухание к shadow_max_distance) бледные — кольцо
## света. Теперь тень солнца = min(тень Godot, тень горизонта) на любой дальности.
## Синтетика: плато 3000 м под снегом (класс SNOW, декабрь), хребет +3000 м в 3 км к югу (вдоль X),
## солнце с юга 23,6°; камера в тени хребта, 300 м над плато, смотрит на север вниз 30°. Свет — как
## в игре на «Высоком» (4 сплита, 3000 м, атлас 4096, angular_distance/blur из world.json).
## Доля прямого солнца в точке: (кадр − кадр без солнца) / (кадр без теней − кадр без солнца),
## «без солнца» — энергия 0 (свет земли sl_ground_light — не прямое солнце, остаётся в обоих);
## по кольцам дальности для точек в глубокой тени (луч к солнцу по высотам, горизонт выше солнца
## на 3°) и на солнце.

const SIZE := Vector2i(960, 540)
const GRID := Vector2i(80, 45)
const SUN_AZ := 180.0
const SUN_EL := 23.6
const RIDGE_Z := 3000.0
const RIDGE_H := 3000.0
const BASE_H := 3000.0
const MIN_DIRECT := 0.08
## [от, до, м; «тень» / «солнце»; предел доли прямого солнца (тень — не больше, солнце — не меньше)]
const RINGS := [
	[300.0, 1500.0, "тень", 0.3],
	[1500.0, 2500.0, "тень", 0.3],
	[2500.0, 3500.0, "тень", 0.3],
	[5000.0, 7000.0, "солнце", 0.8],
]

var failures: PackedStringArray = []


func needs_gpu() -> bool:
	return true


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


static func _h(x: float, z: float) -> float:
	var d := (z - RIDGE_Z) / 1500.0
	return BASE_H + RIDGE_H * exp(-d * d) + 8.0 * sin(x / 600.0) * cos(z / 750.0)


static func _layer(id: String, n: int, step: float) -> HeightLayer:
	var o := -(n - 1) * step * 0.5
	var data := PackedFloat32Array()
	data.resize(n * n)
	for j in n:
		for i in n:
			data[j * n + i] = _h(o + i * step, o + j * step)
	return HeightLayer.from_heights(id, n, n, step, o, o, data)


static func _surf(l: HeightLayer) -> SurfaceLayer:
	var cd := PackedByteArray()
	cd.resize(l.width * l.height)
	cd.fill(SurfaceLayer.SNOW)
	return SurfaceLayer.from_classes(l.id, l.width, l.height, l.spacing, l.origin_x, l.origin_z, cd)


func _shot(vp: SubViewport) -> Image:
	for i in 20:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	return vp.get_texture().get_image()


static func _lum(img: Image, p: Vector2i) -> float:
	var c := img.get_pixelv(p)
	return (c.r + c.g + c.b) / 3.0


## Точка рельефа под пикселем (луч по высотам), INF — небо.
static func _hit(cam: Camera3D, px: Vector2) -> Vector3:
	var o := cam.project_ray_origin(px)
	var dir := cam.project_ray_normal(px)
	var s := 0.0
	var step := 5.0
	while s < 20000.0:
		var p := o + dir * s
		if p.y < _h(p.x, p.z):
			var lo := s - step
			var hi := s
			for i in 12:
				var m := 0.5 * (lo + hi)
				var q := o + dir * m
				if q.y < _h(q.x, q.z):
					hi = m
				else:
					lo = m
			return o + dir * hi
		s += step
		step = clampf(s * 0.004, 2.0, 40.0)
	return Vector3(INF, INF, INF)


## Угол горизонта к солнцу (луч по высотам), градусы.
static func _hz_true(p: Vector3, to_sun: Vector3) -> float:
	var d := Vector2(to_sun.x, to_sun.z).normalized()
	var h0 := _h(p.x, p.z)
	var best := -90.0
	var s := 25.0
	while s < 20000.0:
		best = maxf(best, rad_to_deg(atan((_h(p.x + d.x * s, p.z + d.y * s) - h0) / s)))
		s += maxf(25.0, s * 0.01)
	return best


func test_ridge_shadow_reaches_pilot() -> void:
	var world: Dictionary = Config.get_config("world")
	var sun_cfg: Dictionary = world.get("sun", {})
	RenderingServer.directional_shadow_atlas_set_size(4096, true)
	RenderingServer.directional_soft_shadow_filter_set_quality(RenderingServer.SHADOW_QUALITY_SOFT_HIGH)
	var vp := SubViewport.new()
	vp.size = SIZE
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.own_world_3d = true
	add_child(vp)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.5, 0.6, 0.8)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.5, 0.6, 0.8)
	env.ambient_light_energy = 0.3
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)

	var to_sun := TerrainGeo.sun_direction(SUN_AZ, SUN_EL)
	var t := Terrain.new()
	t.location_id = ""
	vp.add_child(t)
	var ls: Array[HeightLayer] = [_layer("detail", 561, 25.0), _layer("far", 401, 100.0)]
	var cfg := {
		"render": {
			"detail": {"chunk_cells": 80, "lod_distances_m": [1500.0, 3500.0, 7000.0], "skirt_depth_m": 300.0},
			"far": {"chunk_cells": 100, "lod_distances_m": [12000.0, 25000.0], "skirt_depth_m": 400.0},
		},
	}
	t.setup(cfg, ls, 43.1, 77.1, [_surf(ls[0]), _surf(ls[1])])
	t.set_flight_date(12, 15)
	t.set_sun(to_sun)
	t.wait_relief()

	var sun := DirectionalLight3D.new()
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 3000.0  # пресет «Высокий»
	sun.directional_shadow_split_1 = float(sun_cfg.shadow_split_1)
	sun.directional_shadow_split_2 = float(sun_cfg.shadow_split_2)
	sun.directional_shadow_split_3 = float(sun_cfg.shadow_split_3)
	sun.light_angular_distance = float(sun_cfg.get("angular_distance_deg", 0.0))
	sun.shadow_blur = float(sun_cfg.get("shadow_blur", 1.0))
	sun.light_energy = 0.5  # снег без пересвета в 8 битах
	sun.basis = Basis.looking_at(-to_sun, Vector3.UP)
	vp.add_child(sun)

	var cam := Camera3D.new()
	cam.far = 60000.0
	cam.near = 0.5
	cam.fov = 70.0
	vp.add_child(cam)
	cam.position = Vector3(0.0, _h(0.0, 0.0) + 300.0, 0.0)
	cam.rotation_degrees = Vector3(-30.0, 0.0, 0.0)
	cam.make_current()
	t.renderer.lod_camera = cam
	for i in 120:
		await get_tree().process_frame

	var img := await _shot(vp)
	sun.shadow_opacity = 0.0  # не shadow_enabled = false: смена набора пайплайнов — Godot висит на выходе
	for m in t.renderer.materials():
		m.set_shader_parameter("relief_shadow_strength", 0.0)
	var img_open := await _shot(vp)
	sun.light_energy = 0.0
	var img_amb := await _shot(vp)

	var sums := []
	for r in RINGS:
		sums.append([0.0, 0])
	for gy in GRID.y:
		for gx in GRID.x:
			var px := Vector2((gx + 0.5) * SIZE.x / GRID.x, (gy + 0.5) * SIZE.y / GRID.y)
			var w := _hit(cam, px)
			if w.x == INF:
				continue
			var ip := Vector2i(px)
			var amb := _lum(img_amb, ip)
			var full := _lum(img_open, ip) - amb
			if full < MIN_DIRECT:
				continue
			var frac := (_lum(img, ip) - amb) / full
			var d := Vector2(w.x - cam.position.x, w.z - cam.position.z).length()
			var hz := _hz_true(w, to_sun)
			for k in RINGS.size():
				var r: Array = RINGS[k]
				if d < float(r[0]) or d >= float(r[1]):
					continue
				var want_shadow := String(r[2]) == "тень"
				if (want_shadow and hz > SUN_EL + 3.0) or (not want_shadow and hz < SUN_EL - 3.0):
					sums[k][0] += frac
					sums[k][1] += 1
	for k in RINGS.size():
		var r: Array = RINGS[k]
		var n := int(sums[k][1])
		var mean := float(sums[k][0]) / maxi(n, 1)
		print("         %4.0f–%4.0f м, %s: точек %d, доля прямого солнца %.2f (предел %.2f)" % [
			r[0], r[1], r[2], n, mean, r[3]])
		check(n >= 10, "%.0f–%.0f м: мало точек (%d)" % [r[0], r[1], n])
		if String(r[2]) == "тень":
			check(mean <= float(r[3]), "%.0f–%.0f м в тени хребта: доля прямого солнца %.2f > %.2f" % [
				r[0], r[1], mean, r[3]])
		else:
			check(mean >= float(r[3]), "%.0f–%.0f м на солнце: доля прямого солнца %.2f < %.2f" % [
				r[0], r[1], mean, r[3]])
	t.wait_relief()
	vp.queue_free()
