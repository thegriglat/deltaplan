extends Node
## GPU-сверка SL-18 (tools/gpu_tests.sh --filter=tree_cross):
## 1) SL-К5: tc_hash/tc_hash2 и производные (вариант, угол, порода, сдвиг, present) из tree_cell.gdshaderinc
##    побитово против CPU-зеркала TreeCell на 2 × 10 201 клетке (в т. ч. отрицательные и большие индексы);
## 2) SL-К4 v2: маски стыка по формулам шейдеров (tc_model_t — модель, tc_cross_window — крест, дальше —
##    импостер): для каждого дерева, расстояния и шума видна ровно одна форма; вне дизеринга — ожидаемая;
## 3) кресты в деле: Онгудай, TreeCrosses с trees.crosses_enabled — шейдер собирается, кресты рисуются
##    (доля изменившихся пикселей кадра), выше cross_max_agl_m скрыты.

const SIDE := 101          # клеток в стороне блока
const PX_PER_CELL := 8     # пикселей на клетку (по 16 бит в R, G)
const W := 288
const H := 287             # ceil(101² · 8 / 288)

const HASH_PROBE := """
shader_type canvas_item;
render_mode blend_disabled, unshaded;
#include "res://scripts/terrain/tree_cell.gdshaderinc"
uniform ivec2 base;
uniform ivec2 step_c;
vec4 pack16(uint v) {
	return vec4(float(v & 255u), float((v >> 8u) & 255u), 0.0, 255.0) / 255.0;
}
void fragment() {
	ivec2 px = ivec2(floor(UV * vec2(%d.0, %d.0)));
	int idx = px.y * %d + px.x;
	int ci = idx / %d;
	int f = idx %% %d;
	ivec2 c = base + ivec2(ci %% %d - %d, ci / %d - %d) * step_c;
	uvec2 h = tc_hash(c);
	uvec2 h2 = tc_hash2(h);
	vec4 o = vec4(0.0, 0.0, 0.0, 1.0);
	if (f == 0) o = pack16(h.x & 0xFFFFu);
	else if (f == 1) o = pack16(h.x >> 16u);
	else if (f == 2) o = pack16(h.y & 0xFFFFu);
	else if (f == 3) o = pack16(h.y >> 16u);
	else if (f == 4) o = pack16(h2.x & 0xFFFFu);
	else if (f == 5) o = pack16(h2.y & 0xFFFFu);
	else if (f == 6) {
		// вариант (8 вариантов), present при d8 = (ci·37) & 255, порода u·256
		int d8 = (ci * 37) & 255;
		o = vec4(float(tc_variant(h, 8)), tc_present(h, d8) ? 255.0 : 0.0, round(tc_species_u(h) * 256.0), 255.0) / 255.0;
	} else {
		// угол (12 бит) и сдвиг x (12 бит) через float-формулы шейдера
		uint a = uint(round(tc_angle(h) / 6.28318530718 * 4096.0));
		uint ox = uint(round((tc_offset(h).x / 0.8 + 0.5) * 4096.0));
		o = vec4(float(a & 255u), float((a >> 8u) | ((ox >> 8u) << 4u)), float(ox & 255u), 255.0) / 255.0;
	}
	COLOR = o;
}
"""

## Маски стыка: пиксель (x — шум 0…255, y — случай); в R — видимость модели, G — креста, B — импостера.
const MASK_PROBE := """
shader_type canvas_item;
render_mode blend_disabled, unshaded;
#include "res://scripts/terrain/tree_cell.gdshaderinc"
uniform sampler2D cases_tex : filter_nearest;  // x — d, y — k, z — r_near, w — вид модели (0 — LOD1 код 1, 1 — пара LOD0 0,1 + LOD1 0,2, 2 — код 0,3)
uniform float r_far = 1100.0;
uniform float dither = 40.0;
uniform int n_cases = 1;
void fragment() {
	ivec2 px = ivec2(floor(UV * vec2(256.0, float(n_cases))));
	vec4 cs = texelFetch(cases_tex, ivec2(px.y, 0), 0);
	float n = (float(px.x) + 0.5) / 256.0;
	vec2 win = tc_cross_window(cs.x, cs.y, cs.z, r_far, dither);
	// окна модели — той же функцией, что tree_model.gdshader (lod_d.x = 60 м, lod_fade_m = 10 м)
	int kind = int(cs.w + 0.5);
	vec2 wa = tc_model_window(kind == 0 ? 10 : (kind == 1 ? 1 : 3), cs.x, 60.0, 10.0, cs.y, cs.z, dither);
	vec2 wb = kind == 1 ? tc_model_window(2, cs.x, 60.0, 10.0, cs.y, cs.z, dither) : vec2(0.0);
	int nm = int(n >= wa.x && n < wa.y) + int(n >= wb.x && n < wb.y);
	bool model = nm == 1 && cs.z > 0.0;   // r_near = 0 — модели скрыты (выше их max_agl)
	bool cross = n >= win.x && n < win.y;
	bool imp = n < win.x;
	COLOR = vec4(model ? 1.0 : (nm > 1 ? 0.25 : 0.0), cross ? 1.0 : 0.0, imp ? 1.0 : 0.0, 1.0);
}
"""

var failures: PackedStringArray = []


func needs_gpu() -> bool:
	return true


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _probe(code: String, size: Vector2i, params: Dictionary) -> Image:
	var vp := SubViewport.new()
	vp.size = size
	vp.transparent_bg = false
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var rect := ColorRect.new()
	rect.size = Vector2(size)
	var sh := Shader.new()
	sh.code = code
	var m := ShaderMaterial.new()
	m.shader = sh
	for k in params:
		m.set_shader_parameter(k, params[k])
	rect.material = m
	vp.add_child(rect)
	for i in 6:
		await get_tree().process_frame
	var img := vp.get_texture().get_image()
	vp.queue_free()
	await get_tree().process_frame
	return img


static func _u16(img: Image, idx: int) -> int:
	var c := img.get_pixel(idx % W, idx / W)
	return c.r8 | (c.g8 << 8)


func test_hash_matches_cpu() -> void:
	var code := HASH_PROBE % [W, H, W, PX_PER_CELL, PX_PER_CELL, SIDE, SIDE / 2, SIDE, SIDE / 2]
	var blocks := [
		[Vector2i(0, 0), Vector2i(1, 1)],
		[Vector2i(-123457, 98765), Vector2i(7919, -6007)],
	]
	var cells := 0
	var bad := 0
	var bad_derived := 0
	for b in blocks:
		var img: Image = await _probe(code, Vector2i(W, H), {"base": b[0], "step_c": b[1]})
		check(img != null and img.get_width() == W, "снимок пробы хеша")
		if img == null:
			return
		for ci in SIDE * SIDE:
			var c: Vector2i = b[0] + Vector2i(ci % SIDE - SIDE / 2, ci / SIDE - SIDE / 2) * b[1]
			var o := ci * PX_PER_CELL
			var gx := _u16(img, o) | (_u16(img, o + 1) << 16)
			var gy := _u16(img, o + 2) | (_u16(img, o + 3) << 16)
			var h := TreeCell.hash(c)
			var h2 := TreeCell.hash(Vector2i(h.y, h.x))
			var ok := gx == TreeCell.hx(h) and gy == TreeCell.hy(h)
			ok = ok and _u16(img, o + 4) == (h2.x & 0xFFFF) and _u16(img, o + 5) == (h2.y & 0xFFFF)
			if not ok:
				bad += 1
				if bad <= 5:
					check(false, "хеш %s: gpu %d %d cpu %d %d" % [c, gx, gy, TreeCell.hx(h), TreeCell.hy(h)])
			var p6 := img.get_pixel((o + 6) % W, (o + 6) / W)
			var d8 := (ci * 37) & 255
			var want_u := TreeCell.hy(h) & 255
			var ok2 := p6.r8 == TreeCell.variant(h, 8) and (p6.g8 == 255) == TreeCell.present(c, d8)
			ok2 = ok2 and p6.b8 == want_u
			var p7 := img.get_pixel((o + 7) % W, (o + 7) / W)
			var a := p7.r8 | ((p7.g8 & 15) << 8)
			var ox := p7.b8 | ((p7.g8 >> 4) << 8)
			var want_a := (TreeCell.hx(h) >> 20) & 0xFFF
			var want_ox := (TreeCell.hx(h) >> 8) & 0xFFF
			ok2 = ok2 and a == want_a and ox == want_ox
			approx_angle(TreeCell.angle(h), want_a)
			if not ok2:
				bad_derived += 1
				if bad_derived <= 5:
					check(false, "производные %s: вариант %d/%d present %d u %d/%d угол %d/%d сдвиг %d/%d" % [
						c, p6.r8, TreeCell.variant(h, 8), p6.g8, p6.b8, want_u, a, want_a, ox, want_ox])
			cells += 1
	check(bad == 0, "хеш GPU = CPU: расхождений %d из %d" % [bad, cells])
	check(bad_derived == 0, "производные GPU = CPU: расхождений %d из %d" % [bad_derived, cells])
	print("SL-18 GPU: хеш К5 побитово, клеток %d, расхождений хеша %d, производных %d" % [cells, bad, bad_derived])


func approx_angle(cpu: float, bits: int) -> void:
	if absf(cpu - float(bits) / 4096.0 * TAU) > 1e-5:
		check(false, "угол CPU %.6f против бит %d" % [cpu, bits])


func test_stitch_masks_one_form() -> void:
	# случаи: деревья с разными k у ближней и дальней границ, расстояния по полосам и вне их
	var r_near := 180.0
	var r_far := 1100.0
	var dither := 40.0
	var cases: Array[Vector4] = []  # d, k, r_near, вид модели (0 — LOD1, 1 — пара LOD0/LOD1 у 60 м, 2 — код 0,3)
	var rng := RandomNumberGenerator.new()
	rng.seed = 18
	for i in 60:
		var k := rng.randf_range(0.75, 1.2)
		var rn := r_near if i % 6 != 5 else 0.0  # каждое шестое — модели скрыты (кресты до камеры)
		var around := r_near * k if i % 2 == 0 else r_far * k
		cases.append(Vector4(maxf(around + rng.randf_range(-1.5, 1.5) * dither, 1.0), k, rn, 0.0))
	for i in 20:
		cases.append(Vector4(rng.randf_range(5.0, 2000.0), rng.randf_range(0.75, 1.2), r_near, 0.0))
	# SL-20: пара LOD0→LOD1 у 60 м (коды 0,1/0,2) и экземпляр с кодом 0,3 у lod_d.y = 180 м и у r1·k (k > 1):
	# своего ухода у LOD1 нет — до r1·k модель, дальше крест, без дыры [r1; r1·k]
	for i in 20:
		cases.append(Vector4(60.0 + rng.randf_range(-8.0, 8.0), rng.randf_range(0.75, 1.2), r_near, 1.0))
	for i in 30:
		var k := rng.randf_range(1.0, 1.2)
		cases.append(Vector4(rng.randf_range(170.0, r_near * k + 30.0), k, r_near, 2.0))
	var img_c := Image.create(cases.size(), 1, false, Image.FORMAT_RGBAF)
	for i in cases.size():
		img_c.set_pixel(i, 0, Color(cases[i].x, cases[i].y, cases[i].z, cases[i].w))
	var tex := ImageTexture.create_from_image(img_c)
	var img: Image = await _probe(MASK_PROBE, Vector2i(256, cases.size()), {
		"cases_tex": tex, "r_far": r_far, "dither": dither, "n_cases": cases.size()})
	var not_one := 0
	var wrong := 0
	var in_band := 0
	for i in cases.size():
		var d := cases[i].x
		var k := cases[i].y
		var rn := cases[i].z
		for j in 256:
			var c := img.get_pixel(j, i)
			var nm := int(c.r8 > 127)
			var nc := int(c.g8 > 127)
			var ni := int(c.b8 > 127)
			if nm + nc + ni != 1:
				not_one += 1
			# вне полос дизеринга — ожидаемая форма целиком
			var near_b := rn > 0.0 and absf(d - rn * k) < dither * 0.5
			var far_b := absf(d - r_far * k) < dither * 0.5
			if near_b or far_b:
				in_band += 1
				continue
			var want := 1 if (rn <= 0.0 or d >= rn * k) and d < r_far * k else (0 if d < rn * k else 2)
			if [nm, nc, ni][want] != 1:
				wrong += 1
	check(not_one == 0, "ровно одна форма: нарушений %d из %d" % [not_one, cases.size() * 256])
	check(wrong == 0, "вне дизеринга — своя форма: ошибок %d" % wrong)
	print("SL-18 GPU: стык форм, случаев %d × 256 шумов (в полосе дизеринга %d), не одна форма %d, не та форма %d" % [
		cases.size(), in_band, not_one, wrong])


func test_crosses_render_on_terrain() -> void:
	var vp := SubViewport.new()
	vp.size = Vector2i(320, 180)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.own_world_3d = true
	add_child(vp)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.6, 0.7, 0.9)
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-35.0, 40.0, 0.0)
	vp.add_child(sun)
	var t := Terrain.new()
	t.location_id = ""
	vp.add_child(t)
	check(t.load_location("ongudai"), "место ongudai")
	# SL-20: кресты включены по умолчанию — Terrain создал их сам (с маской леса и просеками)
	var tc := t.crosses
	check(tc != null, "Terrain.crosses при trees.crosses_enabled = true")
	if tc == null:
		vp.queue_free()
		await get_tree().process_frame
		return
	# только кресты: модели и импостеры скрыты, рельеф остаётся
	if t.trees != null:
		t.trees.process_mode = Node.PROCESS_MODE_DISABLED
		t.trees.visible = false
	if t.impostors != null:
		t.impostors.process_mode = Node.PROCESS_MODE_DISABLED
		t.impostors.visible = false
	var cam := Camera3D.new()
	cam.far = 20000.0
	vp.add_child(cam)
	tc.camera = cam
	# камера над лесом маски: ищем точку с лесом вокруг старта
	var site: Vector3 = t.get_start_sites()[0].position
	var best := Vector2(site.x, site.z)
	for r in range(0, 3000, 100):
		var hit := false
		for a in 16:
			var q := Vector2(site.x, site.z) + Vector2.from_angle(a * TAU / 16.0) * r
			if t.forest_at(q.x, q.y) > 0.7:
				best = q
				hit = true
				break
		if hit:
			break
	var gh := t.height_at(best.x, best.y)
	cam.position = Vector3(best.x + 600.0, gh + 150.0, best.y)
	cam.look_at(Vector3(best.x, gh, best.y))
	cam.make_current()
	for i in 10:
		await get_tree().process_frame
	var with_c := vp.get_texture().get_image()
	tc.visible = false
	tc.process_mode = Node.PROCESS_MODE_DISABLED
	for i in 4:
		await get_tree().process_frame
	var without := vp.get_texture().get_image()
	var diff := 0
	for y in with_c.get_height():
		for x in with_c.get_width():
			var a := with_c.get_pixel(x, y)
			var b := without.get_pixel(x, y)
			if absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b) > 0.03:
				diff += 1
	var frac := float(diff) / float(with_c.get_width() * with_c.get_height())
	print("SL-18 GPU: кресты на Онгудае, экземпляров %d, пикселей с крестами %d (%.1f %%)" % [
		tc.instance_total, diff, frac * 100.0])
	check(diff > 50, "кресты видны в кадре (%d пикселей)" % diff)
	vp.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
