extends Node
## SL-27: замер тени гор у пилота по числам (без скриншотов). Место из профиля (user://locations),
## солнце по дате/часу/месту, камера у пилота; свет — как в игре (sky_environment + пресет «Высокий»).
## Кадры: тени Godot вкл/выкл × тень горизонта (relief_shadow_strength) вкл/выкл × солнце 0 (только
## рассеянный). По сетке пикселей: точка мира (луч по высотам), истинная тень (луч к солнцу по
## высотам), горизонт канала A relief_tex; доли прямого солнца: godot, relief, вместе — по кольцам.
## godot --path . res://tools/terrain/shadow_probe.tscn -- [place] [lat] [lon] [month] [day] [hour]
##   [agl_m] [yaw_deg] [pitch_deg] [angular_distance_deg, по умолчанию из world.json]

const SIZE := Vector2i(1280, 720)
const GRID := Vector2i(96, 54)
const DEEP_DEG := 3.0
## доля прямого солнца меряется только там, где оно заметно (иначе 8 бит и свет земли — шум)
const MIN_DIRECT := 0.08
const RINGS := [0.0, 500.0, 1000.0, 1500.0, 2000.0, 2250.0, 2500.0, 2750.0, 3000.0, 3500.0, 4000.0, 5000.0, 7000.0, 10000.0]

var vp: SubViewport
var t: Terrain
var sun: DirectionalLight3D
var cam: Camera3D


func _ready() -> void:
	_run.call_deferred()


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _shot() -> Image:
	await _frames(30)
	await RenderingServer.frame_post_draw
	return vp.get_texture().get_image()


func _set_relief(on: bool) -> void:
	for m in t.renderer.materials():
		m.set_shader_parameter("relief_shadow_strength", 0.85 if on else 0.0)


func _run() -> void:
	var a := OS.get_cmdline_user_args()
	var place := a[0] if a.size() > 0 else "pt_+43.100_+077.100"
	var lat := float(a[1]) if a.size() > 1 else 43.12023
	var lon := float(a[2]) if a.size() > 2 else 77.11189
	var month := int(a[3]) if a.size() > 3 else 12
	var day := int(a[4]) if a.size() > 4 else 15
	var hour := float(a[5]) if a.size() > 5 else 12.0
	var agl := float(a[6]) if a.size() > 6 else 150.0
	var yaw := float(a[7]) if a.size() > 7 else 0.0
	var pitch := float(a[8]) if a.size() > 8 else -20.0
	var ang_over := float(a[9]) if a.size() > 9 else -1.0

	var world: Dictionary = Config.get_config("world")
	var sun_cfg: Dictionary = world.get("sun", {})
	RenderingServer.directional_shadow_atlas_set_size(4096, true)
	RenderingServer.directional_soft_shadow_filter_set_quality(RenderingServer.SHADOW_QUALITY_SOFT_HIGH)

	vp = SubViewport.new()
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

	t = Terrain.new()
	t.location_id = ""
	vp.add_child(t)
	if not t.load_location(place):
		print("PROBE нет места ", place)
		get_tree().quit(1)
		return
	var sp := SunClock.solar_position(lat, lon, SunClock.day_of_year(month, day), hour,
			float(t.location.get("utc_offset_h", NAN)))
	var to_sun := TerrainGeo.sun_direction(sp.x, sp.y)
	t.set_flight_date(month, day)
	t.set_sun(to_sun)
	t.wait_relief()

	sun = DirectionalLight3D.new()
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 3000.0
	sun.directional_shadow_split_1 = float(sun_cfg.shadow_split_1)
	sun.directional_shadow_split_2 = float(sun_cfg.shadow_split_2)
	sun.directional_shadow_split_3 = float(sun_cfg.shadow_split_3)
	sun.light_angular_distance = float(sun_cfg.get("angular_distance_deg", 0.0)) if ang_over < 0.0 else ang_over
	sun.shadow_blur = float(sun_cfg.get("shadow_blur", 1.0))
	sun.light_energy = 0.5
	sun.basis = Basis.looking_at(-to_sun, Vector3.UP)
	vp.add_child(sun)

	var p2 := t.latlon_to_local(lat, lon)
	var h0 := t.height_at(p2.x, p2.y)
	cam = Camera3D.new()
	cam.far = 80000.0
	cam.near = 0.5
	cam.fov = 70.0
	vp.add_child(cam)
	cam.position = Vector3(p2.x, h0 + agl, p2.y)
	cam.rotation_degrees = Vector3(pitch, yaw, 0.0)
	cam.make_current()
	t.renderer.lod_camera = cam
	print("PROBE место %s, пилот (%.0f, %.0f) h=%.0f, солнце az=%.1f° el=%.2f°, камера yaw %.0f pitch %.0f agl %.0f" % [
		place, p2.x, p2.y, h0, sp.x, sp.y, yaw, pitch, agl])
	# горизонт к солнцу у пилота и по кольцам к югу: канал A (что читает шейдер) против истинного луча
	for r: float in [0.0, 1000.0, 2000.0, 3000.0, 5000.0]:
		for ang: float in [0.0, 90.0, 180.0, 270.0]:
			var q := p2 + Vector2(sin(deg_to_rad(ang)), -cos(deg_to_rad(ang))) * r
			print("PROBE_HZ r=%5.0f dir=%3.0f hzA=%5.1f true=%5.1f sun=%.1f" % [
				r, ang, _hz_tex(q.x, q.y), _hz_true(q.x, q.y, to_sun), sp.y])
			if r == 0.0:
				break
	await _frames(150)

	sun.shadow_enabled = true
	_set_relief(true)
	var i_on_on := await _shot()
	_set_relief(false)
	var i_on_off := await _shot()
	sun.shadow_enabled = false
	var i_off_off := await _shot()
	_set_relief(true)
	var i_off_on := await _shot()
	# «без прямого солнца»: энергия 0, свет остаётся (light() рельефа добавляет и свет неба/земли
	# sl_ground_light для направленного света — он не прямое солнце и тенью не гасится)
	sun.light_energy = 0.0
	var i_amb := await _shot()
	sun.light_energy = 0.5

	# по кольцам: точки в истинной тени / на солнце
	var nb := RINGS.size() - 1
	var acc := []
	for k in nb:
		acc.append({"sh_n": 0, "sh_g": 0.0, "sh_r": 0.0, "sh_c": 0.0, "lit_n": 0, "lit_c": 0.0, "hz_in": 0, "dp_n": 0, "dp_g": 0.0, "dp_r": 0.0, "dp_c": 0.0, "dp_dh": 0.0, "dp_re": 0.0})
	for gy in GRID.y:
		for gx in GRID.x:
			var px := Vector2((gx + 0.5) * SIZE.x / GRID.x, (gy + 0.5) * SIZE.y / GRID.y)
			var w := _hit(px)
			if w.x == INF:
				continue
			var d := Vector2(w.x - p2.x, w.z - p2.y).length()
			var b := -1
			for k in nb:
				if d >= RINGS[k] and d < RINGS[k + 1]:
					b = k
			if b < 0:
				continue
			var ip := Vector2i(px)
			var amb := _lum(i_amb, ip)
			var full := _lum(i_off_off, ip) - amb
			if full < MIN_DIRECT:
				continue  # склон от солнца: прямого света нет и так
			var g := (_lum(i_on_off, ip) - amb) / full
			var r := (_lum(i_off_on, ip) - amb) / full
			var c := (_lum(i_on_on, ip) - amb) / full
			var shadowed := _shadow_true(w, to_sun)
			var e: Dictionary = acc[b]
			if shadowed:
				e.sh_n += 1
				e.sh_g += g
				e.sh_r += r
				e.sh_c += c
				if _hz_tex(w.x, w.z) > sp.y:
					e.hz_in += 1
				if _hz_true(w.x, w.z, to_sun) > sp.y + DEEP_DEG:
					e.dp_n += 1
					e.dp_g += g
					e.dp_r += r
					e.dp_c += c
					e.dp_dh += _hz_true(w.x, w.z, to_sun) - _hz_tex(w.x, w.z)
					var hz := _hz_tex(w.x, w.z)
					e.dp_re += lerpf(1.0, smoothstep(hz - 2.0, hz + 2.0, sp.y), 0.85)
			else:
				e.lit_n += 1
				e.lit_c += c
	for k in nb:
		var e: Dictionary = acc[k]
		var n := maxi(int(e.sh_n), 1)
		var nd := maxi(int(e.dp_n), 1)
		print("PROBE_RING %5.0f–%5.0f м: в тени %4d (горизонт A видит %3d) godot %.2f relief %.2f вместе %.2f | глубоко (горизонт > солнца + %.0f°) %4d godot %.2f relief %.2f (ожид. по A %.2f) вместе %.2f (точный − A %.1f°) | на солнце %4d вместе %.2f" % [
			RINGS[k], RINGS[k + 1], e.sh_n, e.hz_in, e.sh_g / n, e.sh_r / n, e.sh_c / n,
			DEEP_DEG, e.dp_n, e.dp_g / nd, e.dp_r / nd, e.dp_re / nd, e.dp_c / nd, e.dp_dh / nd,
			e.lit_n, e.lit_c / maxi(int(e.lit_n), 1)])
	get_tree().quit(0)


func _lum(img: Image, p: Vector2i) -> float:
	var c := img.get_pixelv(p)
	return (c.r + c.g + c.b) / 3.0


## Точка рельефа под пикселем (луч по height_at), INF — небо.
func _hit(px: Vector2) -> Vector3:
	var o := cam.project_ray_origin(px)
	var dir := cam.project_ray_normal(px)
	var s := 0.0
	var step := 5.0
	while s < 30000.0:
		var p := o + dir * s
		if p.y < t.height_at(p.x, p.z):
			# уточнение
			var lo := s - step
			var hi := s
			for i in 12:
				var m := 0.5 * (lo + hi)
				var q := o + dir * m
				if q.y < t.height_at(q.x, q.z):
					hi = m
				else:
					lo = m
			return o + dir * hi
		s += step
		step = clampf(s * 0.004, 2.0, 40.0)
	return Vector3(INF, INF, INF)


## Истинная тень: луч к солнцу по высотам до 40 км.
func _shadow_true(p: Vector3, to_sun: Vector3) -> bool:
	var s := 30.0
	while s < 40000.0:
		var q := p + to_sun * s
		if q.y > 6000.0:
			return false
		if t.height_at(q.x, q.z) > q.y + 1.0:
			return true
		s += maxf(25.0, s * 0.01)
	return false


func _hz_true(x: float, z: float, to_sun: Vector3) -> float:
	var h := t.height_at(x, z)
	var d := Vector2(to_sun.x, to_sun.z).normalized()
	var best := -90.0
	var s := 25.0
	while s < 40000.0:
		best = maxf(best, rad_to_deg(atan((t.height_at(x + d.x * s, z + d.y * s) - h) / s)))
		s += maxf(25.0, s * 0.01)
	return best


func _hz_tex(x: float, z: float) -> float:
	var r := t.reliefs[0]
	var i := clampi(roundi((x - r.origin_x) / r.cell_m), 0, r.width - 1)
	var j := clampi(roundi((z - r.origin_z) / r.cell_m), 0, r.height - 1)
	return r.texture_bytes()[(j * r.width + i) * 4 + 3] * TerrainRelief.HORIZON_MAX_DEG / 255.0
