extends Node
## GPU-проверка покрытия ближних травинок (GN-К1, tools/gpu_tests.sh --filter=grass_near):
## режим «Осмотреться» из меню паузы — дерево на паузе, камера отведена от пилота на 18 м.
## Настоящий GrassField на ровном лугу, два SubViewport: A — с травой, B — без (земля та же).
## Пиксель травинки — max по каналам |A − B| > 4/255; земля кадра на 3…12 м от камеры делится
## на сектора по азимуту (8 × 15°); доля травинок по сектору. Условия: min ≥ 0,5·max; сектора
## вне тени заслонки (крыло ≈ 10 × 2 м, солнце как в 15 ч) не беднее тех, что под тенью;
## без заслонки доля вне тени отличается от кадра с заслонкой не более чем на 30 %.

const W := 320
const H := 180
const CAM_DIST_M := 18.0
const CAM_H_M := 2.0
const PITCH_DEG := -35.0
const FOV_DEG := 90.0
const R_NEAR := 3.0
const R_FAR := 12.0
const SECTORS := 8
const SECTOR_DEG := 15.0
const TOL := 4
const GROUND_Y := 100.0
const SUN_DIR := Vector3(-0.45, -0.75, 0.48)   # к земле; ~15 ч, солнце на юго-западе

var failures: PackedStringArray = []
var _layer: HeightLayer
var _views: Array[SubViewport] = []
var _cams: Array[Camera3D] = []
var _fields: Array[GrassField] = []
var _casters: Array[MeshInstance3D] = []
var _pilot: Node3D


func needs_gpu() -> bool:
	return true


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_grass_near_cover_look_around_paused() -> void:
	_build()
	# до паузы камера у пилота (как в полёте), несколько кадров — трава строит кольцо вокруг неё
	_place_cam(Vector3(0.0, GROUND_Y + CAM_H_M, 0.0), 0.0)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_tree().paused = true   # меню паузы → «Осмотреться»: камера уходит от пилота
	var cam_pos := Vector3(CAM_DIST_M, GROUND_Y + CAM_H_M, 0.0)
	_place_cam(cam_pos, 0.0)   # смотрит вдоль −z, по касательной к кольцу вокруг пилота
	var caster_c := Vector3(cam_pos.x, GROUND_Y + 4.0, cam_pos.z - 7.0)
	var with := await _sectors(caster_c, true, cam_pos)
	var without := await _sectors(caster_c, false, cam_pos)
	get_tree().paused = false
	var sh: Array = with.share
	var shadow: Array = with.shadow
	var mx := 0.0
	var mn := 1.0
	for s in SECTORS:
		mx = maxf(mx, sh[s])
		mn = minf(mn, sh[s])
	var lit := _mean(sh, shadow, false)
	var dark := _mean(sh, shadow, true)
	var lit0 := _mean(without.share, shadow, false)
	print("    grass_near: доли по секторам с заслонкой %s" % _fmt(sh))
	print("    grass_near: доли по секторам без заслонки %s" % _fmt(without.share))
	print("    grass_near: min %.3f max %.3f, вне тени %.3f, под тенью %.3f, вне тени без заслонки %.3f" % [mn, mx, lit, dark, lit0])
	check(mx > 0.2, "в кадре есть травинки: max доля %.3f" % mx)
	check(mn >= 0.5 * mx, "min сектора %.3f < 0,5 · max %.3f" % [mn, mx])
	if dark >= 0.0:
		check(lit >= 0.5 * dark, "вне тени %.3f < 0,5 · под тенью %.3f" % [lit, dark])
	check(absf(lit - lit0) <= 0.3 * maxf(lit, lit0), "заслонка меняет долю вне тени: %.3f → %.3f" % [lit0, lit])
	_teardown()


func _mean(share: Array, shadow: Array, under: bool) -> float:
	var sum := 0.0
	var n := 0
	for s in SECTORS:
		if shadow[s] == under:
			sum += share[s]
			n += 1
	return sum / n if n > 0 else -1.0


func _fmt(a: Array) -> String:
	var parts: PackedStringArray = []
	for v: float in a:
		parts.append("%.2f" % v)
	return "[" + ", ".join(parts) + "]"


func _build() -> void:
	var n := 160
	var step := 2.0
	var o := -float(n) * step * 0.5
	var hs := PackedFloat32Array()
	hs.resize(n * n)
	hs.fill(GROUND_Y)
	var img := Image.create(n, n, false, Image.FORMAT_RF)
	img.fill(Color(GROUND_Y, 0, 0))
	_layer = HeightLayer.from_heights("t", n, n, step, o, o, hs)
	var htex := ImageTexture.create_from_image(img)
	var sn := 80
	var ss := 4.0
	var cls := PackedByteArray()
	cls.resize(sn * sn)
	cls.fill(SurfaceLayer.GRASS)
	var simg := Image.create(sn, sn, false, Image.FORMAT_R8)
	simg.fill(Color(SurfaceLayer.GRASS / 255.0, 0, 0))
	var surf := SurfaceLayer.from_classes("s", sn, sn, ss, -sn * ss * 0.5, -sn * ss * 0.5, cls)
	var stex := ImageTexture.create_from_image(simg)
	var cfg: Dictionary = (Config.get_config("vegetation").grass as Dictionary).duplicate(true)
	var look: Dictionary = Config.get_config("world").get("terrain_look", {})
	_pilot = Node3D.new()
	add_child(_pilot)
	_pilot.global_position = Vector3(0.0, GROUND_Y, 0.0)
	for k in 2:
		var vp := SubViewport.new()
		vp.own_world_3d = true
		vp.size = Vector2i(W, H)
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		add_child(vp)
		var env := Environment.new()
		env.background_mode = Environment.BG_COLOR
		env.background_color = Color(0.5, 0.6, 0.8)
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = Color(0.6, 0.65, 0.7)
		var we := WorldEnvironment.new()
		we.environment = env
		vp.add_child(we)
		var sun := DirectionalLight3D.new()
		sun.look_at_from_position(Vector3.ZERO, SUN_DIR, Vector3.UP)
		sun.shadow_enabled = true
		vp.add_child(sun)
		var ground := MeshInstance3D.new()
		var plane := PlaneMesh.new()
		plane.size = Vector2(300.0, 300.0)
		ground.mesh = plane
		var gm := StandardMaterial3D.new()
		gm.albedo_color = Color(0.35, 0.5, 0.2)
		ground.material_override = gm
		ground.position = Vector3(0.0, GROUND_Y, 0.0)
		vp.add_child(ground)
		var caster := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(10.0, 0.1, 2.0)
		caster.mesh = box
		caster.visible = false
		vp.add_child(caster)
		var cam := Camera3D.new()
		cam.far = 500.0
		cam.fov = FOV_DEG
		vp.add_child(cam)
		if k == 0:
			var g := GrassField.new()
			g.camera = cam
			g.pilot = _pilot
			vp.add_child(g)
			g.setup(_layer, htex, surf, stex, look, cfg, [] as Array[Vector4])
			_fields.append(g)
		_views.append(vp)
		_cams.append(cam)
		_casters.append(caster)


func _teardown() -> void:
	get_tree().paused = false
	for vp in _views:
		vp.queue_free()
	_pilot.queue_free()
	_views.clear()
	_cams.clear()
	_fields.clear()
	_casters.clear()


func _place_cam(p: Vector3, yaw: float) -> void:
	var b := Basis.from_euler(Vector3(deg_to_rad(PITCH_DEG), deg_to_rad(yaw), 0.0), EULER_ORDER_YXZ)
	for c in _cams:
		c.global_transform = Transform3D(b, p)


## Доли травинок по секторам кадра; shadow[s] — сектор в основном под тенью заслонки.
func _sectors(caster_c: Vector3, caster_on: bool, cam_pos: Vector3) -> Dictionary:
	for c in _casters:
		c.visible = caster_on
		c.global_position = caster_c
	for i in 3:
		await RenderingServer.frame_post_draw
	var a := _views[0].get_texture().get_image()
	var b := _views[1].get_texture().get_image()
	if a.get_format() != b.get_format():
		b.convert(a.get_format())
	var cam := _cams[0]
	var total: Array[int] = []
	var grass: Array[int] = []
	var shaded: Array[int] = []
	for s in SECTORS:
		total.append(0)
		grass.append(0)
		shaded.append(0)
	for y in H:
		for x in W:
			var ray := cam.project_ray_normal(Vector2(x + 0.5, y + 0.5))
			if ray.y > -0.01:
				continue
			var t := (GROUND_Y - cam_pos.y) / ray.y
			var pt := cam_pos + ray * t
			var d := Vector2(pt.x - cam_pos.x, pt.z - cam_pos.z)
			var r := d.length()
			if r < R_NEAR or r > R_FAR:
				continue
			var az := rad_to_deg(atan2(d.x, -d.y))   # от оси камеры (−z), вправо +
			var s := int(floor(az / SECTOR_DEG + SECTORS / 2.0))
			if s < 0 or s >= SECTORS:
				continue
			total[s] += 1
			var pa := a.get_pixel(x, y)
			var pb := b.get_pixel(x, y)
			var dl := maxf(maxf(absf(pa.r - pb.r), absf(pa.g - pb.g)), absf(pa.b - pb.b))
			if dl > TOL / 255.0:
				grass[s] += 1
			if _in_shadow(pt, caster_c):
				shaded[s] += 1
	var share: Array = []
	var shadow: Array = []
	for s in SECTORS:
		share.append(float(grass[s]) / maxi(total[s], 1))
		shadow.append(total[s] > 0 and shaded[s] * 5 > total[s])
	return {"share": share, "shadow": shadow}


## Точка земли в тени заслонки (ось-выровненный ящик 10 × 0,1 × 2 м): луч к солнцу пересекает ящик.
func _in_shadow(pt: Vector3, c: Vector3) -> bool:
	var dir := -SUN_DIR.normalized()
	var lo := c - Vector3(5.0, 0.05, 1.0)
	var hi := c + Vector3(5.0, 0.05, 1.0)
	var t0 := 0.0
	var t1 := 1e9
	for ax in 3:
		if absf(dir[ax]) < 1e-6:
			if pt[ax] < lo[ax] or pt[ax] > hi[ax]:
				return false
		else:
			var ta := (lo[ax] - pt[ax]) / dir[ax]
			var tb := (hi[ax] - pt[ax]) / dir[ax]
			t0 = maxf(t0, minf(ta, tb))
			t1 = minf(t1, maxf(ta, tb))
	return t0 <= t1
