extends TestCase
## OL-6: шлейфы промышленных труб (OsmChimneyPlumes): детерминированная доля труб, выход на высоте устья,
## один опрос ветра на трубу, снос по ветру, дальность видимости, группа osm_wind (L4).


func _cfg() -> Dictionary:
	return Config.get_config("world_objects")


func _flat(_x: float, _z: float) -> float:
	return 100.0


func _data(n: int, spacing: float = 400.0) -> OsmData:
	var d := OsmData.new()
	for i in n:
		d.verticals.append({"t": "chimney", "comm": false, "x": 50.0 + i * spacing, "z": 80.0 + (i % 7) * 13.0, "h": 120.0})
	d.verticals.append({"t": "mast", "comm": false, "x": 10.0, "z": 10.0, "h": 60.0})
	return d


func test_fraction_deterministic() -> void:
	var d := _data(400)
	var a := OsmChimneyPlumes.pick_mouths(d, _cfg(), _flat)
	var b := OsmChimneyPlumes.pick_mouths(d, _cfg(), _flat)
	check(a == b, "выбор детерминирован")
	var f := float(_cfg().osm_pilot.chimney_plume.fraction)
	check(absf(a.size() / 400.0 - f) < 0.1, "доля ≈ %.2f: %d из 400" % [f, a.size()])
	for p in a:
		approx(p.y, 220.0, 1e-3, "устье на высоте трубы над землёй")


func test_default_height() -> void:
	var d := OsmData.new()
	for i in 40:
		d.verticals.append({"t": "chimney", "comm": false, "x": i * 31.0, "z": 5.0, "h": 0.0})
	var a := OsmChimneyPlumes.pick_mouths(d, _cfg(), _flat)
	check(a.size() > 0, "есть шлейфы")
	approx(a[0].y, 100.0 + float(_cfg().osm_pilot.verticals.default_h_m.chimney), 1e-3, "высота без тега — по классу")


func test_wind_per_chimney_and_drift() -> void:
	var n := OsmChimneyPlumes.build(_data(60, 300.0), _cfg(), _flat) as OsmChimneyPlumes
	check(n != null and n.is_in_group(&"osm_wind"), "узел в группе osm_wind")
	var calls := [0]
	var heights: Array = []
	var air := func(p: Vector3) -> Vector3:
		calls[0] += 1
		heights.append(p.y)
		return Vector3(5, 0, -3)
	n.osm_wind(air, Vector3(2000, 300, 80))
	var vis := float(_cfg().osm_pilot.chimney_plume.visibility_m)
	check(n.active_count > 0, "эмиттеры стоят: %d" % n.active_count)
	check(calls[0] == n.active_count, "ровно один опрос на трубу: %d / %d" % [calls[0], n.active_count])
	for h: float in heights:
		approx(h, 220.0, 1e-3, "опрос на высоте устья")
	var seen := 0
	for c in n.get_children():
		var e := c as GPUParticles3D
		if not e.emitting:
			continue
		seen += 1
		check(Vector2(e.position.x - 2000.0, e.position.z - 80.0).length() <= vis + 1.0, "труба в пределах видимости")
		var m := e.process_material as ShaderMaterial
		check((m.get_shader_parameter(&"wind_low") as Vector3).is_equal_approx(Vector3(5, 0, -3)), "ветер модели в шейдере")
		check(e.visibility_aabb.has_point(Vector3(300, 0, -200)), "bbox охватывает снос по ветру")
	check(seen == n.active_count, "счётчик")
	n.free()


func test_no_chimneys_no_node() -> void:
	var d := OsmData.new()
	d.verticals.append({"t": "mast", "comm": false, "x": 1.0, "z": 1.0, "h": 40.0})
	check(OsmChimneyPlumes.build(d, _cfg(), _flat) == null, "без труб узла нет")
