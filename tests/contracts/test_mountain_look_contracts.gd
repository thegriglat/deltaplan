extends TestCase
## Контрактные тесты mountain-look (docs/contracts/mountain-look.md). MLK-К3 — зонд силуэта гор
## (владелец MLK-1): форма JSON на фикстуре ongudai без сети (--raw=game). MLK-К2 v2 — дальняя форма
## рельефа (владелец MLK-3): инварианты ReliefLook.dh (CPU-зеркало vertex() terrain.gdshader) на синтетике.


func test_k3_probe_json_shape() -> Variant:
	var root: Node = (Engine.get_main_loop() as SceneTree).root
	var t := Terrain.new()
	t.location_id = ""
	root.add_child.call_deferred(t)
	await (Engine.get_main_loop() as SceneTree).process_frame
	check(t.load_location("ongudai"), "k3: место ongudai из фикстур")
	var probe: Node = (load("res://tools/bench/mountain_look_probe.gd") as GDScript).new()
	root.add_child.call_deferred(probe)
	await (Engine.get_main_loop() as SceneTree).process_frame
	var opt := {"lat": NAN, "lon": NAN, "location": "ongudai", "tag": "t", "out": "", "agl": 300.0,
			"az_step": 2.0, "cache": "", "range_km": 12.0, "raw": "game", "targets": ""}
	var out: Dictionary = await probe.measure(t, opt)
	check(not out.is_empty(), "k3: measure вернул словарь")
	if out.is_empty():
		return null
	for k in ["probe_version", "tag", "lat", "lon", "format_version", "layers", "peaks", "crests", "horizon", "memory"]:
		check(out.has(k), "k3: ключ %s" % k)
	check(int(out.probe_version) >= 1, "k3: probe_version")
	check(out.layers.size() == 2 and out.layers[0].has("spacing_m") and out.layers[0].has("size_km"), "k3: layers")
	check(out.peaks.size() > 0, "k3: есть вершины")
	for p: Dictionary in out.peaks:
		for k in ["lat", "lon", "dist_km", "layer", "h_raw", "h_game", "h_render"]:
			check(p.has(k) and p[k] != null, "k3: peak.%s" % k)
		check(float(p.h_render) <= float(p.h_raw) + 8.5, "k3: render не выше raw больше предела dh")
	check(out.crests.size() > 0, "k3: гребни по зонам")
	for c: Dictionary in out.crests:
		for k in ["layer", "band_km", "zone", "n", "curv_ratio", "drop_m_p50", "drop_m_p90"]:
			check(c.has(k), "k3: crest.%s" % k)
		check(["above_forest", "forest", "all"].has(c.zone), "k3: zone")
	for k in ["az_step_deg", "rough_raw_deg", "rough_render_deg", "rough_ratio", "deficit_deg_p50", "deficit_deg_max", "far_layer_share"]:
		check(out.horizon.has(k), "k3: horizon.%s" % k)
	check(float(out.horizon.far_layer_share) >= 0.0 and float(out.horizon.far_layer_share) <= 1.0, "k3: far_layer_share в 0..1")
	check(JSON.stringify(out) != "", "k3: сериализуется в JSON")
	probe.queue_free()
	t.queue_free()
	return null


# ---------------------------------------------------------------- MLK-К2 v2

const K2_N := 641
const K2_SP := 25.0
const K2_LOD := [1500.0, 3500.0, 7000.0, 14000.0]


func _k2_look() -> Dictionary:
	return (Config.get_config("world").terrain_look as Dictionary).duplicate(true)


## Синтетический хребет с пиками (конусы на шаге не кратном LOD) и долинами, 16 × 16 км, шаг 25 м.
func _k2_layer() -> HeightLayer:
	var hs := PackedFloat32Array()
	hs.resize(K2_N * K2_N)
	var half := (K2_N - 1) * K2_SP * 0.5
	for j in K2_N:
		for i in K2_N:
			var x := i * K2_SP - half
			var z := j * K2_SP - half
			var h := 2000.0 + 400.0 * sin(x / 1300.0) * cos(z / 1700.0)
			for c in [Vector3(1237.0, 3311.0, 900.0), Vector3(-2763.0, -1187.0, 700.0), Vector3(4013.0, -4987.0, 1100.0)]:
				var d := Vector2(x - c.x, z - c.y).length()
				h += maxf(0.0, c.z - d * 1.2)
			hs[j * K2_N + i] = h
	return HeightLayer.from_heights("t", K2_N, K2_N, K2_SP, -half, -half, hs)


func _k2_surface(cls: int) -> SurfaceLayer:
	var c := PackedByteArray()
	c.resize(K2_N * K2_N)
	c.fill(cls)
	var half := (K2_N - 1) * K2_SP * 0.5
	return SurfaceLayer.from_classes("t", K2_N, K2_N, K2_SP, -half, -half, c)


func test_k2_relief_keys_are_uniforms() -> void:
	var src := FileAccess.get_file_as_string("res://scripts/terrain/terrain.gdshader")
	for key: String in _k2_look():
		if not key.begins_with("relief_") or key.ends_with("_doc"):
			continue
		var re := RegEx.create_from_string("uniform\\s+\\w+\\s+%s\\b" % key)
		check(re.search(src) != null, "k2: ключ terrain_look.%s — uniform шейдера" % key)


func test_k2_zero_near_camera_and_on_closed_surfaces() -> void:
	var L := _k2_layer()
	var look := _k2_look()
	var near: Array = look.relief_near_m
	var lod := PackedFloat32Array(K2_LOD)
	var open := _k2_surface(SurfaceLayer.BARE)
	var worst_near := 0.0
	var worst_closed := 0.0
	var any_far := 0.0
	for k in 400:
		var i := 3 + (k * 37) % (K2_N - 6)
		var j := 3 + (k * 91) % (K2_N - 6)
		var x := L.origin_x + i * K2_SP
		var z := L.origin_z + j * K2_SP
		var cam_near := Vector3(x + float(near[0]) * 0.9, L.node(i, j) + 300.0, z)
		worst_near = maxf(worst_near, absf(ReliefLook.dh(L, open, x, z, cam_near, look, lod)))
		var cam_far := Vector3(x + 15000.0, L.node(i, j), z)
		for cls in [SurfaceLayer.FOREST, SurfaceLayer.WATER, SurfaceLayer.BUILT]:
			worst_closed = maxf(worst_closed, absf(ReliefLook.dh(L, _k2_surface(cls), x, z, cam_far, look, lod)))
		any_far = maxf(any_far, absf(ReliefLook.dh(L, open, x, z, cam_far, look, lod)))
	check(worst_near == 0.0, "k2: dh = 0 при d_cam ≤ relief_near_m.x (было %.3f)" % worst_near)
	check(worst_closed == 0.0, "k2: dh = 0 на лесе/воде/застройке (было %.3f)" % worst_closed)
	check(any_far > 1.0, "k2: вдали на открытом dh есть (%.2f м)" % any_far)


func test_k2_bounded_and_smooth_in_distance() -> void:
	var L := _k2_layer()
	var look := _k2_look()
	var lod := PackedFloat32Array(K2_LOD)
	var open := _k2_surface(SurfaceLayer.BARE)
	var lim := ReliefLook.dh_limit_m(look)
	var worst := 0.0
	var worst_step := 0.0
	for p: Vector2i in [Vector2i(320, 320), Vector2i(373, 452), Vector2i(209, 271), Vector2i(480, 120)]:
		var x := L.origin_x + p.x * K2_SP
		var z := L.origin_z + p.y * K2_SP
		var prev := NAN
		var d := 0.0
		while d < 50000.0:
			var cam := Vector3(x - d, L.node(p.x, p.y) + 200.0, z)
			var v := ReliefLook.dh(L, open, x, z, cam, look, lod)
			worst = maxf(worst, absf(v))
			if not is_nan(prev):
				worst_step = maxf(worst_step, absf(v - prev))
			prev = v
			d += 10.0
	check(worst <= lim, "k2: |dh| ≤ предела конфига (%.1f ≤ %.1f м)" % [worst, lim])
	# переход по дальности гладкий: за 10 м — не больше 2 м (ступенька LOD дала бы десятки)
	check(worst_step <= 2.0, "k2: dh по дальности без ступенек (скачок за 10 м %.2f м)" % worst_step)


## Пик между вершинами LOD: меш с шагом 16 узлов (400 м) на 20 км теряет меньше половины прежнего;
## на дне долин (вогнутые узлы) подъёма нет.
func test_k2_peak_restored_valleys_not_inflated() -> void:
	var L := _k2_layer()
	var look := _k2_look()
	var lod := PackedFloat32Array(K2_LOD)
	var open := _k2_surface(SurfaceLayer.BARE)
	var cam := Vector3(L.origin_x - 20000.0, 3500.0, 0.0)
	var s := 16
	var apex := L.max_h
	var best_v1 := -INF
	var best_v2 := -INF
	var valley_sum := 0.0
	var valley_n := 0
	for j in range(0, K2_N, s):
		for i in range(0, K2_N, s):
			var x := L.origin_x + i * K2_SP
			var z := L.origin_z + j * K2_SP
			var h := L.node(i, j)
			var dh := ReliefLook.dh(L, open, x, z, cam, look, lod)
			best_v1 = maxf(best_v1, h)
			best_v2 = maxf(best_v2, h + dh)
			var lap := (L.node(i + 4, j) + L.node(i - 4, j) + L.node(i, j + 4) + L.node(i, j - 4) - 4.0 * h) / 400.0
			if lap > 0.05:
				valley_sum += dh
				valley_n += 1
	var loss1 := apex - best_v1
	var loss2 := apex - best_v2
	check(loss1 > 20.0, "k2: синтетика — пик между вершинами (потеря без подъёма %.1f м)" % loss1)
	check(loss2 <= 0.5 * loss1, "k2: потеря пика ≤ половины (%.1f → %.1f м)" % [loss1, loss2])
	check(valley_n > 10, "k2: есть вогнутые узлы (%d)" % valley_n)
	check(valley_sum / maxf(valley_n, 1) <= 2.0, "k2: долины не надуваются (средний dh %.2f м)" % (valley_sum / maxf(valley_n, 1)))
