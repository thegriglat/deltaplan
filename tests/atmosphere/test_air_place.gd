class_name TestAirPlace
extends TestCase
## Вход решения масштаба 1 для места (AirPlace, AM-03) против эталона AM-01
## (tools/research/air3d/picard_gpu_refs.py → fixtures/air_model/picard/): рельеф области
## (блочное среднее), z_i и dθ̄/dz погоды игры, поток тепла по склонам с водой. Без GPU.

const FIX := "res://tests/atmosphere/fixtures/air_model/picard/"


static func load_detail(loc_id: String) -> Array:
	var dir := "res://data/terrain/%s" % loc_id
	var meta: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string(dir.path_join("meta.json"))
	)
	for info: Dictionary in meta.layers:
		if String(info.id) == "detail":
			var l := HeightLayer.load_from_file(dir.path_join(String(info.file)), info)
			var img: Image = null
			if info.has("water_file"):
				var tex := load(dir.path_join(String(info.water_file))) as Texture2D
				img = tex.get_image() if tex != null else null
			return [l, img]
	return []


static func load_loc(loc_id: String) -> Dictionary:
	var loc: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://configs/locations/%s.json" % loc_id)
	)
	loc.id = loc_id
	return loc


func test_domain_input_vs_reference() -> void:
	var lw := load_detail("ongudai")
	check(lw.size() == 2 and lw[0] != null, "слой detail Онгудая")
	if lw.size() != 2:
		return
	var loc := load_loc("ongudai")
	for dx in [400.0, 200.0]:
		var m := TestAirPicard.load_fix(FIX + "ongudai_d%d_h12" % int(dx))
		var t0 := Time.get_ticks_msec()
		var c := AirPlace.domain_case(lw[0], lw[1], loc, dx, 12.0, 3.0, 150.0)
		var t_ms := Time.get_ticks_msec() - t0
		check(c != null, "случай построен")
		if c == null:
			return
		check(
			c.nx == int(m.nx) and c.nz == int(m.nz) and c.z_bot == float(m.z_bot),
			"сетка как в эталоне"
		)
		var dat: Dictionary = m.data
		var e_h := _max_diff(c.hc, dat.hc)
		var e_q := _max_diff(c.heat, dat.H)
		var e_g := _max_diff(c.gam, dat.gam)
		var fmt := TestAirPicard.sci
		print(
			(
				"  %d м: подготовка %d мс; max|Δhc| %s м, max|ΔH| %s Вт/м², max|Δγ| %s К/м, z_i %.2f / %.2f м"
				% [int(dx), t_ms, fmt.call(e_h), fmt.call(e_q), fmt.call(e_g), c.z_i, float(m.z_i)]
			)
		)
		check(e_h < 1e-3, "рельеф: %s м" % fmt.call(e_h))
		if e_q >= 1e-2:
			var w := AirPlace.water_fraction(lw[1], lw[0], c.x0, c.y0, dx, c.nx, c.ny)
			var bi := 0
			for q in c.heat.size():
				if absf(c.heat[q] - dat.H[q]) > absf(c.heat[bi] - dat.H[bi]):
					bi = q
			print(
				(
					"    худшая клетка %d: H %.2f против %.2f, вода %.3f"
					% [bi, c.heat[bi], dat.H[bi], w[bi]]
				)
			)
		check(e_q < 1e-2, "поток тепла: %s Вт/м²" % fmt.call(e_q))
		check(e_g < 1e-7, "dθ̄/dz: %s К/м" % fmt.call(e_g))
		check(absf(c.z_i - float(m.z_i)) < 0.5, "z_i: %.2f против %.2f" % [c.z_i, float(m.z_i)])


static func _max_diff(a: PackedFloat64Array, b: PackedFloat32Array) -> float:
	if a.size() != b.size():
		return INF
	var e := 0.0
	for i in a.size():
		e = maxf(e, absf(a[i] - b[i]))
	return e
