extends TestCase
## ON-3: AirNnPrep (scripts/atmosphere/air_model/air_nn_prep.gd) = prep.py. Фикстура tests/air_onnx/fixtures/prep_*
## (tools/air_onnx/make_prep_fixture.py, O3): карты и числа ≤ 1e-4 абс., to_physical ≤ 1e-4·max(1, |x|).

const FIX := "res://tests/air_onnx/fixtures/"
const TOL := 1e-4


static func _f32(name: String) -> PackedFloat32Array:
	return FileAccess.get_file_as_bytes(FIX + name).to_float32_array()


static func _doc() -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string(FIX + "prep_cases.json"))


static func _f64(a: PackedFloat32Array, off: int, n: int) -> PackedFloat64Array:
	var o := PackedFloat64Array()
	o.resize(n)
	for i in n:
		o[i] = a[off + i]
	return o


func test_rotation_of() -> void:
	var rot: Dictionary = _doc()["rotation"]
	var w: Array = rot["wdir"]
	var worst := 0.0
	for i in w.size():
		var rk := AirNnPrep.rotation_of(w[i])
		check(rk[0] == int(rot["k"][i]), "k при wdir=%s: %d ≠ %d" % [w[i], rk[0], int(rot["k"][i])])
		worst = maxf(worst, absf(rk[1] - float(rot["r"][i])))
	check(worst < 1e-9, "r: макс. расхождение %s" % worst)


func test_meta_film() -> void:
	var d := _doc()
	var hc_all := _f32("prep_hc.bin")
	var nn: int = int(d["ny"]) * int(d["nx"])
	var worst := 0.0
	for ci in d["cases"].size():
		var c: Dictionary = d["cases"][ci]
		var meta := AirNnPrep.case_meta(c["row"], _f64(hc_all, ci * nn, nn))
		check(meta["k"] == int(c["meta"]["k"]), "meta.k случай %d" % ci)
		for key in ["r", "U10", "alpha", "mp", "S", "hc_mean"]:
			var e := absf(float(meta[key]) - float(c["meta"][key]))
			worst = maxf(worst, e)
			check(e < 1e-9, "meta.%s случай %d: %s" % [key, ci, e])
		var f := AirNnPrep.film(c["row"], meta)
		check(f.size() == 18, "film: 18 чисел")
		for i in 18:
			var e := absf(f[i] - float(c["film"][i]))
			worst = maxf(worst, e)
			check(e <= TOL, "film[%s] случай %d: %s ≠ %s" % [AirNnPrep.FILM_NAMES[i], ci, f[i], float(c["film"][i])])
	print("    film/meta: макс. расхождение %s" % worst)


func test_maps() -> void:
	var d := _doc()
	var ny: int = d["ny"]
	var nn: int = ny * int(d["nx"])
	var hc_all := _f32("prep_hc.bin")
	var heat_all := _f32("prep_heat.bin")
	var ref := _f32("prep_maps.bin")
	for ci in d["cases"].size():
		var c: Dictionary = d["cases"][ci]
		var hc := _f64(hc_all, ci * nn, nn)
		var heat := _f64(heat_all, ci * nn, nn)
		var meta := AirNnPrep.case_meta(c["row"], hc)
		var t0 := Time.get_ticks_usec()
		var m := AirNnPrep.maps(hc, heat, meta, 9, float(d["dx"]))
		var dt := (Time.get_ticks_usec() - t0) / 1e6
		check(m.size() == 9 * nn, "maps: размер")
		var worst := 0.0
		var wc := 0
		for i in 9 * nn:
			var e := absf(m[i] - ref[ci * 9 * nn + i])
			if is_nan(e):
				e = 1e9
			if e > worst:
				worst = e
				wc = i / nn
		check(worst <= TOL, "maps(9) случай %d (k=%d): макс. %s в карте %s" % [ci, meta["k"], worst, AirNnPrep.MAP_NAMES[wc]])
		var t1 := Time.get_ticks_usec()
		var m4 := AirNnPrep.maps(hc, heat, meta, 4, float(d["dx"]))
		var dt4 := (Time.get_ticks_usec() - t1) / 1e6
		var w4 := 0.0
		for i in 4 * nn:
			var e4 := absf(m4[i] - ref[ci * 9 * nn + i])
			w4 = maxf(w4, 1e9 if is_nan(e4) else e4)
		check(w4 <= TOL, "maps(4) случай %d: макс. %s" % [ci, w4])
		print("    maps случай %d (k=%d): макс. расхождение %s (4 карты: %s), время 9 карт %.2f с, 4 карты %.3f с" % [ci, meta["k"], worst, w4, dt, dt4])


func test_to_physical() -> void:
	var d := _doc()
	var n: int = d["phys_n"]
	var nn := n * n
	var ref := _f32("prep_phys.bin")
	var out := PackedFloat32Array()
	out.resize(91 * nn)
	for i in out.size():
		out[i] = sin(0.37 * i) * 0.8
	var hc_all := _f32("prep_hc.bin")
	var big: int = int(d["ny"]) * int(d["nx"])
	var per := 7 * 13 * nn
	for ci in d["cases"].size():
		var c: Dictionary = d["cases"][ci]
		var meta := AirNnPrep.case_meta(c["row"], _f64(hc_all, ci * big, big))
		var res := AirNnPrep.to_physical(out, meta, n, n)
		var worst := 0.0
		for key in ["m", "h"]:
			var a: PackedFloat32Array = res[key]
			var off: int = ci * per + (0 if key == "m" else 3 * 13 * nn)
			check(a.size() == (3 if key == "m" else 4) * 13 * nn, "to_physical.%s: размер" % key)
			for i in a.size():
				var x := ref[off + i]
				var e := absf(a[i] - x) / maxf(1.0, absf(x))
				worst = maxf(worst, 1e9 if is_nan(e) else e)
		check(worst <= TOL, "to_physical случай %d (k=%d): %s" % [ci, meta["k"], worst])
