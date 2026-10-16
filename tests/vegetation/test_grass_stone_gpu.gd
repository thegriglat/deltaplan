extends Node
## GPU-проверка «трава не на породе рельефа» (GR-25, G2 v2; tools/gpu_tests.sh --filter=grass_stone).
## Сцена GrassStoneScene: купол с выходами породы, обрыв со скалами и осыпью ниже, весь луг.
## (1) Правило породы ground_cover.gdshaderinc на GPU (доля луга gc_meadow и доля пучков
##     gc_grass_keep, вид сверху) совпадает с CPU-копией GrassField.meadow_at/grass_keep_at на сетке.
## (2) Настоящий GrassField (ближние травинки; слои shell; карточки angle): густота травы в кадре там,
##     где по правилу порода (доля пучков 0), — не больше 3 % густоты на лугу (доля пучков 1).

const PROBE := """
shader_type spatial;
render_mode unshaded, cull_disabled, fog_disabled;
#include "res://scripts/terrain/terrain_common.gdshaderinc"
#include "res://scripts/terrain/ground_cover.gdshaderinc"
varying vec3 v_w;
void vertex() {
	v_w = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}
void fragment() {
	vec2 xz = v_w.xz;
	vec2 f = (xz - layer_origin) / layer_spacing;
	vec2 i = floor(f);
	vec2 t = f - i;
	ivec2 ij = ivec2(i);
	float h00 = h_node(ij);
	float h10 = h_node(ij + ivec2(1, 0));
	float h01 = h_node(ij + ivec2(0, 1));
	float h11 = h_node(ij + ivec2(1, 1));
	vec2 g = vec2(mix(h10 - h00, h11 - h01, t.y), mix(h01 - h00, h11 - h10, t.x)) / layer_spacing;
	vec3 n = normalize(vec3(-g.x, 1.0, -g.y));
	int c = surface_node(ivec2(round((xz - surface_origin) / surface_spacing)));
	ALBEDO = vec3(gc_meadow(xz, n, c), gc_grass_keep(xz, n, c), 0.0);
}
"""

const BG := Color(1.0, 0.0, 1.0)

var failures: PackedStringArray = []
var _scene: GrassStoneScene


func needs_gpu() -> bool:
	return true


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _field(vp: SubViewport, cam: Camera3D, cfg: Dictionary) -> GrassField:
	var g := GrassField.new()
	g.camera = cam
	vp.add_child(g)
	var spots: Array[Vector4] = []
	g.setup(_scene.layer, _scene.height_tex, _scene.surface, _scene.surface_tex, _scene.look, cfg, spots)
	return g


func _viewport(size: Vector2i) -> SubViewport:
	var vp := SubViewport.new()
	vp.own_world_3d = true
	vp.size = size
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = BG
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.4, 0.4, 0.4)
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)
	return vp


func test_grass_stone_rule_cpu_matches_gpu() -> void:
	_scene = GrassStoneScene.build()
	var w := 240
	var size_m := 300.0
	var vp := _viewport(Vector2i(w, w))
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = size_m
	cam.far = 2000.0
	cam.position = Vector3(10.0, 900.0, 0.0)
	cam.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	vp.add_child(cam)
	var sh := Shader.new()
	sh.code = PROBE
	var m := ShaderMaterial.new()
	m.shader = sh
	_scene.apply(m)
	var cfg: Dictionary = (Config.get_config("vegetation").grass as Dictionary).duplicate(true)
	m.set_shader_parameter("stone_keep", GrassField._v2(cfg.get("stone_keep", [0.15, 0.65])))
	var mi := MeshInstance3D.new()
	var q := PlaneMesh.new()
	q.size = Vector2(size_m + 20.0, size_m + 20.0)
	mi.mesh = q
	mi.material_override = m
	mi.position = Vector3(10.0, 0.0, 0.0)
	vp.add_child(mi)
	# CPU-копия правила — у настоящего GrassField (вид, слой, конфиг — как в игре)
	var g := _field(vp, cam, cfg)
	g.visible = false
	for f in 4:
		await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	img.convert(Image.FORMAT_RGBA8)
	var bad_m := 0
	var bad_k := 0
	var max_d := 0.0
	var stone := 0
	var meadow := 0
	var n := 0
	for py in range(0, w, 2):
		for px in range(0, w, 2):
			var p := cam.project_position(Vector2(px + 0.5, py + 0.5), 1.0)
			var c := img.get_pixel(px, py).srgb_to_linear()
			var cm := g.meadow_at(p.x, p.z, SurfaceLayer.GRASS)
			var ck := g.grass_keep_at(p.x, p.z, SurfaceLayer.GRASS)
			var d := absf(c.r - cm)
			max_d = maxf(max_d, d)
			if d > 0.03:
				bad_m += 1
			if absf(c.g - ck) > 0.03:
				bad_k += 1
			if ck <= 0.0:
				stone += 1
			elif ck >= 1.0:
				meadow += 1
			n += 1
	print(
		(
			"    grass_stone: CPU/GPU на %d точках: доля луга расходится >0,03 в %.2f %% (макс %.3f), доля пучков — %.2f %%; порода %.0f %%, луг %.0f %%"
			% [n, 100.0 * bad_m / n, max_d, 100.0 * bad_k / n, 100.0 * stone / n, 100.0 * meadow / n]
		)
	)
	check(stone > n / 20, "в сцене есть порода: %d из %d" % [stone, n])
	check(meadow > n / 5, "в сцене есть луг: %d из %d" % [meadow, n])
	check(bad_m <= n / 100, "доля луга CPU = GPU: расходится в %d из %d" % [bad_m, n])
	check(bad_k <= n / 100, "доля пучков CPU = GPU: расходится в %d из %d" % [bad_k, n])
	vp.queue_free()


## Точка над куполом, где в круге r порода и луг примерно поровну (по CPU-правилу).
func _mixed_spot(g: GrassField, r: float) -> Vector2:
	var best := Vector2.ZERO
	var best_e := 1e9
	for cz in range(-60, 61, 10):
		for cx in range(-60, 61, 10):
			var st := 0
			var cnt := 0
			for dz in range(-int(r), int(r) + 1, 3):
				for dx in range(-int(r), int(r) + 1, 3):
					if dx * dx + dz * dz > r * r:
						continue
					cnt += 1
					if g.grass_keep_at(cx + dx, cz + dz, SurfaceLayer.GRASS) <= 0.0:
						st += 1
			var e := absf(float(st) / maxi(cnt, 1) - 0.5)
			if e < best_e:
				best_e = e
				best = Vector2(cx, cz)
	return best


## Густота травы (доля пикселей не фона) над породой и над лугом: кадр сверху вниз, точка земли
## пикселя — луч камеры до рельефа; зона — по правилу в точке и в ±reach м (наклон и ширина пучка).
func _density(mode: String, eye_m: float, fov: float, ring: Vector2) -> Dictionary:
	var cfg: Dictionary = (Config.get_config("vegetation").grass as Dictionary).duplicate(true)
	cfg.mid.mode = mode
	if mode == "angle":
		# только карточки: доля карточек 1 при любом угле взгляда
		cfg.mid.card_angle_full_deg = 89.8
		cfg.mid.card_angle_none_deg = 90.0
	var w := 320
	var vp := _viewport(Vector2i(w, w))
	var cam := Camera3D.new()
	cam.fov = fov
	cam.far = 1000.0
	vp.add_child(cam)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-60.0, 30.0, 0.0)
	vp.add_child(sun)
	var g := _field(vp, cam, cfg)
	var spot := _mixed_spot(g, (ring.x + ring.y) * 0.5)
	var h0 := _scene.layer.sample(spot.x, spot.y)
	cam.global_transform = Transform3D(Basis.from_euler(Vector3(-PI * 0.5, 0.0, 0.0)), Vector3(spot.x, h0 + eye_m, spot.y))
	for f in 6:
		await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	img.convert(Image.FORMAT_RGBA8)
	var reach := 0.8
	var sg := 0
	var sn := 0
	var mg := 0
	var mn := 0
	for py in range(0, w, 2):
		for px in range(0, w, 2):
			var o := cam.project_ray_origin(Vector2(px + 0.5, py + 0.5))
			var dir := cam.project_ray_normal(Vector2(px + 0.5, py + 0.5))
			var y := h0
			var p := o
			for it in 3:
				p = o + dir * ((y - o.y) / dir.y)
				y = _scene.layer.sample(p.x, p.z)
			var dh := Vector2(p.x - spot.x, p.z - spot.y).length()
			if dh < ring.x or dh > ring.y:
				continue
			var kmin := 1.0
			var kmax := 0.0
			for off: Vector2 in [Vector2.ZERO, Vector2(reach, 0), Vector2(-reach, 0), Vector2(0, reach), Vector2(0, -reach)]:
				var k := g.grass_keep_at(p.x + off.x, p.z + off.y, SurfaceLayer.GRASS)
				kmin = minf(kmin, k)
				kmax = maxf(kmax, k)
			var c := img.get_pixel(px, py)
			var is_grass := absf(c.r - BG.r) + absf(c.g - BG.g) + absf(c.b - BG.b) > 0.06
			if kmax <= 0.0:
				sn += 1
				sg += 1 if is_grass else 0
			elif kmin >= 1.0:
				mn += 1
				mg += 1 if is_grass else 0
	vp.queue_free()
	return {
		"stone": float(sg) / maxi(sn, 1), "meadow": float(mg) / maxi(mn, 1), "sn": sn, "mn": mn
	}


func _check_mode(mode: String, eye_m: float, fov: float, ring: Vector2) -> void:
	_scene = GrassStoneScene.build()
	var r := await _density(mode, eye_m, fov, ring)
	print(
		(
			"    grass_stone %s: густота над породой %.4f (%d пикс.), над лугом %.4f (%d пикс.)"
			% [mode, r.stone, r.sn, r.meadow, r.mn]
		)
	)
	check(r.sn > 200 and r.mn > 200, "%s: в кадре и порода, и луг: %d / %d" % [mode, r.sn, r.mn])
	check(r.meadow > 0.05, "%s: трава на лугу видна: %.4f" % [mode, r.meadow])
	check(r.stone <= 0.03 * r.meadow, "%s: трава над породой: %.4f при %.4f на лугу" % [mode, r.stone, r.meadow])


func test_grass_stone_near_blades() -> void:
	await _check_mode("blades", 6.0, 90.0, Vector2(0.0, 8.0))


func test_grass_stone_shell() -> void:
	await _check_mode("shell", 14.0, 100.0, Vector2(15.0, 30.0))


func test_grass_stone_cards() -> void:
	await _check_mode("angle", 14.0, 100.0, Vector2(15.0, 30.0))
