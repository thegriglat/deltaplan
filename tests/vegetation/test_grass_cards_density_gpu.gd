extends Node
## GPU-проверка густоты на стыке ближних травинок и карточек (GR-25; tools/gpu_tests.sh
## --filter=grass_cards_density): ровный луг, глаз 1,5 м, взгляд вниз 8°, кадр 1920×1080 (как в игре),
## режим angle. Земля — плоский цвет без освещения; карточки — тот же цвет ×0,5 (card_shade 0,5,
## без разброса), травинки — свой цвет луга: пиксель травы — отличается от земли. Доля пикселей травы
## по дальности точки земли под пикселем (бины 1 м). Под скользящим взглядом доля растёт с дальностью
## и у одних травинок (больше стеблей на пиксель), поэтому скачок — относительно эталона «везде
## травинки» (режим blades: ближнее кольцо до radius_m и кольца травинок дальше): отношение средних
## в полосах 5 м после и до grass.mid.inner_radius_m, у angle и у blades, расходится не больше чем на 10 %;
## так же у края ближнего кольца (radius_m, где травинки кончаются). Обе формы (tuft, strip)
## печатаются, проверяется форма из конфига.

const W := 1920
const H := 1080
const EYE_M := 1.5
const GROUND := Color(0.8, 0.2, 0.8)

var failures: PackedStringArray = []


func needs_gpu() -> bool:
	return true


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


## Профиль доли травы по дальности (бины 1 м, 2…30 м) для формы карточек sh.
func coverage_profile(sh: String, mode := "angle") -> PackedFloat32Array:
	var n := 64
	var step := 4.0
	var o := -float(n) * step * 0.5
	var hs := PackedFloat32Array()
	hs.resize(n * n)
	var img := Image.create(n, n, false, Image.FORMAT_RF)
	for j in n:
		for i in n:
			hs[j * n + i] = 100.0
			img.set_pixel(i, j, Color(100.0, 0, 0))
	var layer := HeightLayer.from_heights("t", n, n, step, o, o, hs)
	var htex := ImageTexture.create_from_image(img)
	var sn := 32
	var cls := PackedByteArray()
	cls.resize(sn * sn)
	cls.fill(SurfaceLayer.GRASS)
	var simg := Image.create(sn, sn, false, Image.FORMAT_R8)
	simg.fill(Color(SurfaceLayer.GRASS / 255.0, 0, 0))
	var surf := SurfaceLayer.from_classes("s", sn, sn, 8.0, o, o, cls)
	var stex := ImageTexture.create_from_image(simg)
	var cfg: Dictionary = (Config.get_config("vegetation").grass as Dictionary).duplicate(true)
	cfg.mid.mode = mode
	cfg.mid.cards.shape = sh
	var look: Dictionary = Config.get_config("world").get("terrain_look", {})
	var vp := SubViewport.new()
	vp.own_world_3d = true
	vp.size = Vector2i(W, H)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.5, 0.6, 0.8)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.4, 0.4, 0.45)
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45.0, 150.0, 0.0)
	vp.add_child(sun)
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(240.0, 240.0)
	ground.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	gm.albedo_color = GROUND
	ground.material_override = gm
	ground.position = Vector3(0.0, 100.0, 0.0)
	vp.add_child(ground)
	var cam := Camera3D.new()
	cam.fov = 75.0
	cam.far = 500.0
	vp.add_child(cam)
	cam.global_transform = Transform3D(
		Basis.from_euler(Vector3(deg_to_rad(-8.0), 0.0, 0.0)), Vector3(0.3, 100.0 + EYE_M, 0.2)
	)
	var g := GrassField.new()
	g.camera = cam
	vp.add_child(g)
	var spots: Array[Vector4] = []
	g.setup(layer, htex, surf, stex, look, cfg, spots)
	if g.mid_cards != null:
		g.mid_cards.material.set_shader_parameter("card_shade", Vector2(0.5, 0.5))
		g.mid_cards.material.set_shader_parameter("card_tone", 0.0)
		g.mid_cards.material.set_shader_parameter("card_norm", 1.0)
	for f in 6:
		await RenderingServer.frame_post_draw
	var im := vp.get_texture().get_image()
	im.convert(Image.FORMAT_RGBA8)
	var bins := 30
	var cnt := PackedFloat32Array()
	cnt.resize(bins)
	var hit := PackedFloat32Array()
	hit.resize(bins)
	var gc := GROUND
	for py in range(0, H, 2):
		for px in range(0, W, 2):
			var ro := cam.project_ray_origin(Vector2(px + 0.5, py + 0.5))
			var rd := cam.project_ray_normal(Vector2(px + 0.5, py + 0.5))
			if rd.y >= -1e-4:
				continue
			var p := ro + rd * ((100.0 - ro.y) / rd.y)
			var d := Vector2(p.x - ro.x, p.z - ro.z).length()
			var b := int(d)
			if b < 2 or b >= bins:
				continue
			var c := im.get_pixel(px, py)
			cnt[b] += 1.0
			if absf(c.r - gc.r) + absf(c.g - gc.g) + absf(c.b - gc.b) > 0.08:
				hit[b] += 1.0
	vp.queue_free()
	var out := PackedFloat32Array()
	out.resize(bins)
	for b in bins:
		out[b] = hit[b] / cnt[b] if cnt[b] > 0.0 else -1.0
	return out


static func band_mean(prof: PackedFloat32Array, a: float, b: float) -> float:
	var s := 0.0
	var n := 0
	for i in prof.size():
		if prof[i] >= 0.0 and i + 0.5 >= a and i + 0.5 < b:
			s += prof[i]
			n += 1
	return s / maxi(n, 1)


func test_grass_cards_density_junction() -> void:
	var gcfg: Dictionary = Config.get_config("vegetation").grass
	var mid: Dictionary = gcfg.mid
	var inner := float(mid.get("inner_radius_m", 8.4))
	var radius := float(gcfg.get("radius_m", 14.0))
	var shape := GrassMidCards.shape_of(mid.get("cards", {}))
	var ref := await coverage_profile("tuft", "blades")
	var r_in := band_mean(ref, inner, inner + 5.0) / maxf(band_mean(ref, inner - 5.0, inner), 1e-3)
	var r_out := band_mean(ref, radius, radius + 5.0) / maxf(band_mean(ref, radius - 5.0, radius), 1e-3)
	print("    grass_cards_density blades: %s" % _fmt(ref))
	print("    grass_cards_density blades: после/до у %.1f м %.3f, у %.1f м %.3f" % [inner, r_in, radius, r_out])
	for sh in GrassMidCards.SHAPES:
		var prof := await coverage_profile(sh)
		var a := band_mean(prof, inner - 5.0, inner)
		var k_in := band_mean(prof, inner, inner + 5.0) / maxf(a, 1e-3) / r_in - 1.0
		var k_out := band_mean(prof, radius, radius + 5.0) / maxf(band_mean(prof, radius - 5.0, radius), 1e-3) / r_out - 1.0
		var far := band_mean(prof, radius + 5.0, 30.0) / maxf(band_mean(ref, radius + 5.0, 30.0), 1e-3) - 1.0
		print("    grass_cards_density %s: %s" % [sh, _fmt(prof)])
		print(
			"    grass_cards_density %s: скачок у %.1f м %+.1f %%, у %.1f м %+.1f %%; дальше %.0f м — %+.1f %% к травинкам"
			% [sh, inner, k_in * 100.0, radius, k_out * 100.0, radius + 5.0, far * 100.0]
		)
		if sh == shape:
			check(a > 0.3, "%s: трава у ближнего края видна: %.3f" % [sh, a])
			check(absf(k_in) <= 0.1, "%s: скачок густоты у %.1f м %.1f %%" % [sh, inner, k_in * 100.0])
			check(absf(k_out) <= 0.1, "%s: скачок густоты у %.1f м %.1f %%" % [sh, radius, k_out * 100.0])


static func _fmt(prof: PackedFloat32Array) -> String:
	var parts: PackedStringArray = []
	for i in range(2, prof.size()):
		parts.append("%d:%.2f" % [i, prof[i]])
	return " ".join(parts)
