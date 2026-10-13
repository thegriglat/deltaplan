extends TestCase
## Контрактные тесты mountain-look (docs/contracts/mountain-look.md). MLK-К3 — зонд силуэта гор
## (владелец MLK-1): форма JSON на фикстуре ongudai без сети (--raw=game). К1/К2 допишут другие задачи.


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
	check(int(out.probe_version) == 1, "k3: probe_version 1")
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
