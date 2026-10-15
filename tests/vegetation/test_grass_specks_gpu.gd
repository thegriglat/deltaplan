extends Node
## GPU-проверка «чёрной сыпи» и яркости травы (GR-14, tools/gpu_tests.sh --filter=grass_specks):
## настоящий GrassField на ровном лугу, MSAA 2× (как пресеты medium/high), глаз 1,5 м.
## (1) Сыпь: в полосах кадра, где луч зрения падает на землю в 2–8 м и 8–30 м, пикселей темнее
## половины медианы полосы — не больше SPECK_MAX, в режимах blades и shell. До GR-14 при MSAA
## тонкая травинка закрашивалась в центре пикселя вне треугольника, varying'и экстраполировались
## (поперёк листа ±5 → край в минус, нормаль в ноль): 0,24 % на 2–8 м и 1,1 % на 8–30 м (blades),
## без MSAA — 0. (2) Яркость: своя нормаль травинки (GR-6) с leaf_tilt_gain даёт ту же среднюю
## яркость ближней травы, что нормаль полога (leaf_tilt_deg 0, множитель 1), ±BRIGHT_TOL при высоте
## солнца 25/45/65° (среднее по четырём азимутам).

const EYE_M := 1.5
const SPECK_MAX := 0.0005
const BRIGHT_TOL := 0.03

var failures: PackedStringArray = []
var _layer: HeightLayer


func needs_gpu() -> bool:
	return true


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_grass_specks_blades() -> void:
	await _specks("blades")


func test_grass_specks_shell() -> void:
	await _specks("shell")


func test_grass_specks_tilt_brightness() -> void:
	var size := Vector2i(480, 270)
	for elev: float in [25.0, 45.0, 65.0]:
		var tot := [0.0, 0.0]
		for az: float in [0.0, 90.0, 180.0, 270.0]:
			for v in 2:
				var vp := _build("blades", size)
				var mat: ShaderMaterial = (vp.get_meta("grass") as GrassField).material
				if v == 1:
					mat.set_shader_parameter("leaf_tilt_deg", 0.0)
					mat.set_shader_parameter("leaf_tilt_gain", 1.0)
				(vp.get_meta("sun") as DirectionalLight3D).rotation_degrees = Vector3(-elev, az, 0.0)
				var img := await _render(vp, 60.0, -25.0)
				var l := 0.0
				for y in range(size.y / 2, size.y):
					for x in size.x:
						l += img.get_pixel(x, y).get_luminance()
				tot[v] += l
				vp.queue_free()
				await RenderingServer.frame_post_draw
		var k: float = tot[0] / maxf(tot[1], 1e-6)
		print("    grass_specks: солнце %d°: яркость своя нормаль / нормаль полога %.3f" % [int(elev), k])
		check(absf(k - 1.0) <= BRIGHT_TOL, "солнце %d°: яркость ближней травы %.3f от нормали полога" % [int(elev), k])


func _specks(mode: String) -> void:
	var size := Vector2i(960, 540)
	var fov := 60.0
	var pitch := -4.0
	var vp := _build(mode, size)
	var img := await _render(vp, fov, pitch)
	for band: Vector2 in [Vector2(2.0, 8.0), Vector2(8.0, 30.0)]:
		var lums := PackedFloat32Array()
		for y in size.y:
			var t := (0.5 - (y + 0.5) / size.y) * 2.0 * tan(deg_to_rad(fov) * 0.5)
			var below := -(deg_to_rad(pitch) + atan(t))
			if below <= 0.0:
				continue
			var dist := EYE_M / tan(below)
			if dist < band.x or dist > band.y:
				continue
			for x in size.x:
				lums.append(img.get_pixel(x, y).get_luminance())
		check(lums.size() > 1000, "%s: полоса %d–%d м в кадре: %d пикселей" % [mode, band.x, band.y, lums.size()])
		var s := lums.duplicate()
		s.sort()
		var med: float = s[s.size() / 2] if s.size() > 0 else 0.0
		var dark := 0
		for l in lums:
			if l < 0.5 * med:
				dark += 1
		var share := float(dark) / maxi(lums.size(), 1)
		print("    grass_specks %s: %d–%d м — тёмных точек %.4f %% (медиана яркости %.3f)" % [mode, band.x, band.y, share * 100.0, med])
		check(share <= SPECK_MAX, "%s %d–%d м: тёмных точек %.4f %%" % [mode, band.x, band.y, share * 100.0])
	vp.queue_free()
	await RenderingServer.frame_post_draw


func _render(vp: SubViewport, fov: float, pitch: float) -> Image:
	var cam: Camera3D = vp.get_meta("cam")
	cam.fov = fov
	var p := Vector3(0.3, _layer.sample(0.3, 0.2) + EYE_M, 0.2)
	cam.global_transform = Transform3D(Basis.from_euler(Vector3(deg_to_rad(pitch), 0.0, 0.0), EULER_ORDER_YXZ), p)
	for k in 3:
		await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	img.convert(Image.FORMAT_RGBA8)
	return img


## Ровный луг (бугры ±0,2 м), класс GRASS везде, земля — цвета луга, небо — пурпурное (дыра видна).
func _build(mode: String, size: Vector2i) -> SubViewport:
	var n := 128
	var step := 2.0
	var o := -float(n) * step * 0.5
	var hs := PackedFloat32Array()
	hs.resize(n * n)
	var img := Image.create(n, n, false, Image.FORMAT_RF)
	for j in n:
		for i in n:
			var h := 200.0 + 0.2 * sin(i * 0.7) * cos(j * 0.5)
			hs[j * n + i] = h
			img.set_pixel(i, j, Color(h, 0, 0))
	_layer = HeightLayer.from_heights("t", n, n, step, o, o, hs)
	var htex := ImageTexture.create_from_image(img)
	var sn := 64
	var ss := 4.0
	var cls := PackedByteArray()
	cls.resize(sn * sn)
	cls.fill(SurfaceLayer.GRASS)
	var simg := Image.create(sn, sn, false, Image.FORMAT_R8)
	simg.fill(Color(SurfaceLayer.GRASS / 255.0, 0, 0))
	var surf := SurfaceLayer.from_classes("s", sn, sn, ss, -sn * ss * 0.5, -sn * ss * 0.5, cls)
	var stex := ImageTexture.create_from_image(simg)
	var cfg: Dictionary = (Config.get_config("vegetation").grass as Dictionary).duplicate(true)
	cfg.mid.mode = mode
	var look: Dictionary = Config.get_config("world").get("terrain_look", {})
	var vp := SubViewport.new()
	vp.own_world_3d = true
	vp.size = size
	vp.msaa_3d = Viewport.MSAA_2X
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(1, 0, 1)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.5, 0.55, 0.6)
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40.0, 150.0, 0.0)
	vp.add_child(sun)
	vp.set_meta("sun", sun)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for j in n - 1:
		for i in n - 1:
			var q: Array[Vector3] = []
			for c: Vector2i in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]:
				q.append(Vector3(o + (i + c.x) * step, hs[(j + c.y) * n + i + c.x] - 0.01, o + (j + c.y) * step))
			for v in [q[0], q[1], q[2], q[1], q[3], q[2]]:
				st.add_vertex(v)
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.3, 0.33, 0.15)
	mi.material_override = mat
	vp.add_child(mi)
	var cam := Camera3D.new()
	cam.far = 800.0
	vp.add_child(cam)
	vp.set_meta("cam", cam)
	var g := GrassField.new()
	g.camera = cam
	vp.add_child(g)
	var spots: Array[Vector4] = []
	g.setup(_layer, htex, surf, stex, look, cfg, spots)
	vp.set_meta("grass", g)
	return vp
