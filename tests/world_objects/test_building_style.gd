extends TestCase
## Стиль домов (OL-1, L2/L3): контраст палитр крыша/стены, плоские крыши города, трубы и дым села, пул дыма.


func _bc() -> Dictionary:
	return WorldObjects.load_config().buildings


func test_palette_contrast() -> void:
	var sc: Dictionary = _bc().style
	var need := float(sc.min_roof_contrast)
	for s in 3:
		var c := BuildingStyle.min_palette_contrast(BuildingStyle.palette(sc, s))
		check(c >= need, "стиль %d: контраст крыша/стены %.3f >= %.3f" % [s, c, need])


func test_city_flat_village_gable_chimneys() -> void:
	var bc := _bc()
	var recs := [
		[0.0, 0.0, 40.0, 20.0, 0.0, 15.0, 0, 2, 1],  # apartments с roof=0 — всё равно плоская
	]
	for i in 200:
		recs.append([100.0 + 30.0 * i, 500.0, 10.0, 8.0, 0.0, 6.0, 0, 1, 1])  # house
	var tiles := BuildingPlacer.place(recs, bc, func(_x: float, _z: float) -> float: return 0.0)
	var roofs := 0
	var chim := 0
	var smoke := 0
	var walls := 0
	for k in tiles:
		roofs += (tiles[k].roofs as Array).size()
		chim += (tiles[k].chimneys as Array).size()
		smoke += (tiles[k].smoke as PackedVector3Array).size()
		walls += (tiles[k].walls as Array).size()
	check(walls == 201, "все дома в стенах")
	check(roofs == 200, "призмы только у села: %d" % roofs)
	var cf := float(bc.chimney.fraction)
	check(chim > 200 * cf * 0.7 and chim <= 200, "труб примерно доля %.2f: %d" % [cf, chim])
	check(smoke > 0 and smoke < chim, "дым у части труб: %d из %d" % [smoke, chim])


func test_smoke_pool_and_wind() -> void:
	var pts := PackedVector3Array()
	for i in 300:
		pts.append(Vector3(i * 20.0, 5.0, 0.0))
	var sm := OsmSmoke.new()
	sm.setup(pts, _bc().smoke)
	var calls := [0]
	var air := func(_p: Vector3) -> Vector3:
		calls[0] += 1
		return Vector3(2, 0, 0)
	sm.osm_wind(air, Vector3(0, 50, 0))
	check(sm.chimney_count() == 300, "трубы в кластерах")
	check(sm.emitter_count <= int(_bc().smoke.max_emitters), "пул не больше max_emitters: %d" % sm.emitter_count)
	check(sm.active_count > 0 and sm.active_count <= sm.emitter_count, "эмиттеры заняты: %d" % sm.active_count)
	check(calls[0] > 0 and calls[0] <= 64, "опросы ветра в бюджете: %d" % calls[0])
	for pe in sm.get_children():
		if (pe as GPUParticles3D).emitting:
			check((pe as GPUParticles3D).position.distance_to(Vector3(0, 5, 0)) <= float(_bc().smoke.visibility_m) + 1.0, "эмиттер в радиусе")
	sm.free()
