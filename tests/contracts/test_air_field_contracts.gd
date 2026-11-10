# gdlint: disable=max-public-methods
extends TestCase
## Контракты формата поля воздуха (docs/contracts/air-model.md C1, C3, C4, C6, C8), живая часть старого
## test_air_contracts (RW-13): WindField, AirFieldSet, Atmosphere; без GPU и удалённых классов.

const Rig := preload("res://tests/atmosphere/air_rig.gd")
const FIX := "res://tests/atmosphere/fixtures/air_model/"
const REF_CASES := ["agnesi", "flat_wind", "heated_slope", "saddle"]
const GAME_FIELDS := [
	"field/kayancha_w100_h13_U3_d180", "thermals/kayancha_w100_h09", "thermals/kayancha_w100_h12"
]
const CHANNELS := ["u", "v", "w_mech", "w_conv", "theta"]
## Массивы ref/ с ореолом (N), без ореола (n), шаблоны (7·N), по уровням (NZ).
const REF_N := [
	"cell", "tu", "tv", "tw", "in_u", "in_v", "in_w", "in_th", "in_thd", "in_p", "mom_u", "mom_v",
	"mom_w", "proj_u", "proj_v", "proj_w", "proj_p", "bh_d", "heat_thd", "bh", "heat_th", "sol_u",
	"sol_v", "sol_w", "sol_th", "sol_thd", "sol_p"
]
const REF_INNER := ["div_star", "proj_rhs", "vcycle_phi_raw", "div_after"]
const REF_STENCIL := ["Cm_u", "Cm_v", "Cm_w", "Ch_d", "Ch"]
const REF_LEVEL := ["gam"]


# ------------------------------------------------------------------ помощники


static func _json(path: String) -> Dictionary:
	var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return v if v is Dictionary else {}


static func _arr(js: Dictionary, all: PackedFloat32Array, name: String) -> PackedFloat32Array:
	var ol: Array = js.arrays[name]
	return all.slice(int(ol[0]), int(ol[0]) + int(ol[1]))


## Массивы файла подряд без дыр с нуля, Σ длин · 4 = размер .bin.
func _check_packing(js: Dictionary, bin_size: int, label: String) -> void:
	var spans: Array = (js.arrays as Dictionary).values()
	spans.sort_custom(func(a: Array, b: Array) -> bool: return int(a[0]) < int(b[0]))
	var at := 0
	for s: Array in spans:
		check(int(s[0]) == at, "%s: массивы подряд без дыр (смещение %d ≠ %d)" % [label, s[0], at])
		at = int(s[0]) + int(s[1])
	check(at * 4 == bin_size, "%s: Σ длин · 4 = размер .bin (%d ≠ %d)" % [label, at * 4, bin_size])


## Поле из массивов (C3): размеры, функции-заполнители f(i, j, k) по каналам, hc(i, j).
static func _field(
	g: Dictionary, fu: Callable, fv: Callable, fw: Callable, fc: Callable, ft: Callable, fh: Callable
) -> WindField:
	var nx: int = g.nx
	var ny: int = g.ny
	var nz: int = g.nz
	var a: Array[PackedFloat32Array] = []
	for q in 5:
		var p := PackedFloat32Array()
		p.resize(nx * ny * nz)
		a.append(p)
	var fns := [fu, fv, fw, fc, ft]
	for k in nz:
		for j in ny:
			for i in nx:
				var c := (k * ny + j) * nx + i
				for q in 5:
					a[q][c] = float((fns[q] as Callable).call(i, j, k))
	var hc := PackedFloat32Array()
	hc.resize(nx * ny)
	for j in ny:
		for i in nx:
			hc[j * nx + i] = float(fh.call(i, j))
	return WindField.from_arrays(g, a[0], a[1], a[2], a[3], a[4], hc)


static func _grid() -> Dictionary:
	return {dx = 100.0, dz = 50.0, x0 = -2000.0, y0 = -1500.0, z_bot = 0.0, nx = 40, ny = 30, nz = 20}


static func _const_field(u: float, v: float, w: float) -> WindField:
	return _field(
		_grid(), func(_i, _j, _k): return u, func(_i, _j, _k): return v,
		func(_i, _j, _k): return w, func(_i, _j, _k): return 0.0,
		func(_i, _j, _k): return 0.0, func(_i, _j): return 0.0
	)


## Мир по индексам центра клетки (без ореола).
static func _world(g: Dictionary, i: float, j: float, k: float) -> Vector3:
	return Vector3(
		g.x0 + (i + 0.5) * g.dx, g.z_bot + (k + 0.5) * g.dz, -(g.y0 + (j + 0.5) * g.dx)
	)


static func _flat(_x: float, _z: float) -> float:
	return 0.0


static func _sun(_x: float, _z: float) -> float:
	return 0.8


static func _atmo() -> Atmosphere:
	# Атмосфера — только приёмник поля AirFieldSet (set_air_field / air_field); воздух — в крейте
	# (W2 v4).
	var a := Atmosphere.new()
	a.visuals_enabled = false
	a.configure(Config.get_config("atmosphere"))
	return a


# ------------------------------------------------------------------ C1


func test_c1_ref_fixture_format() -> void:
	for c: String in REF_CASES:
		var base: String = FIX + "ref/" + c
		var js := _json(base + ".json")
		check(not js.is_empty(), c + ".json читается")
		if js.is_empty():
			continue
		for key in [
			"case", "dims", "halo", "dx", "dz", "z_bot", "x0", "y0", "nx", "ny", "nz",
			"params", "case_params", "criterion", "solution", "arrays"
		]:
			check(js.has(key), "%s: ключ %s" % [c, key])
		var nx := int(js.nx)
		var ny := int(js.ny)
		var nz := int(js.nz)
		check(int(js.halo) == 1, c + ": ореол 1")
		check(
			js.dims == [float(nx + 2), float(ny + 2), float(nz + 2)] or js.dims == [nx + 2, ny + 2, nz + 2],
			"%s: dims = [nx+2, ny+2, nz+2] (%s)" % [c, js.dims]
		)
		var params: Dictionary = js.params
		check(params.has("dtau_u") and float(params.dtau_u) > 0.0, c + ": params.dtau_u в JSON (Р1)")
		check(params.has("pr_t") and float(params.pr_t) > 0.0, c + ": params.pr_t в JSON (C1 v2)")
		if c == "heated_slope":
			check(float(params.pr_t) != 1.0, c + ": pr_t ≠ 1 (шаблон тепла чувствителен к Pr_t)")
		for key in ["tol_mom_rms", "tol_th_rms", "tol_div_rms", "check_every"]:
			check((js.criterion as Dictionary).has(key), "%s: criterion.%s" % [c, key])
		check(String(js.solution.status) == "ok", c + ": решение сошлось")
		var big := (nx + 2) * (ny + 2) * (nz + 2)
		var want := {hc = nx * ny}
		for nm in REF_N:
			want[nm] = big
		for nm in REF_INNER:
			want[nm] = nx * ny * nz
		for nm in REF_STENCIL:
			want[nm] = 7 * big
		for nm in REF_LEVEL:
			want[nm] = nz + 2
		var arrays: Dictionary = js.arrays
		for nm: String in want:
			check(arrays.has(nm), "%s: массив %s" % [c, nm])
			if arrays.has(nm):
				check(
					int(arrays[nm][1]) == int(want[nm]),
					"%s: длина %s %d ≠ %d" % [c, nm, arrays[nm][1], want[nm]]
				)
		_check_packing(js, FileAccess.get_file_as_bytes(base + ".bin").size(), c)


## Маска: клетка — земля ⇔ центр ниже hc (то же правило, что WindField); слой k = 0 — земля.
func test_c1_ref_mask_rule() -> void:
	for c: String in REF_CASES:
		var base: String = FIX + "ref/" + c
		var js := _json(base + ".json")
		var all := FileAccess.get_file_as_bytes(base + ".bin").to_float32_array()
		var cell := _arr(js, all, "cell")
		var hc := _arr(js, all, "hc")
		var nx := int(js.nx)
		var ny := int(js.ny)
		var nx2 := nx + 2
		var ny2 := ny + 2
		var nz2 := int(js.nz) + 2
		var bad := 0
		var bad_type := 0
		for q in cell.size():
			var t := cell[q]
			if t != 0.0 and t != 1.0 and t != 2.0:
				bad_type += 1
		for k in nz2:
			var z := float(js.z_bot) + (k - 0.5) * float(js.dz)
			for j in ny2:
				for i in nx2:
					var t := cell[(k * ny2 + j) * nx2 + i]
					if k == 0:
						if t != 0.0:
							bad += 1
						continue
					if i == 0 or j == 0 or i == nx2 - 1 or j == ny2 - 1 or k == nz2 - 1:
						continue
					var ground := z < hc[(j - 1) * nx + (i - 1)]
					if ground != (t == 0.0):
						bad += 1
		check(bad_type == 0, "%s: cell ∈ {0, 1, 2} (%d иных)" % [c, bad_type])
		check(bad == 0, "%s: маска = «центр < hc», k = 0 — земля (%d несовпадений)" % [c, bad])


## Решение эталона после finalize: ∇·u на гранях — до округления; всё конечно.
func test_c1_ref_solution_div_free() -> void:
	for c: String in REF_CASES:
		var base: String = FIX + "ref/" + c
		var js := _json(base + ".json")
		var all := FileAccess.get_file_as_bytes(base + ".bin").to_float32_array()
		var finite := true
		for x in all:
			if not is_finite(x):
				finite = false
				break
		check(finite, c + ": все числа конечны")
		var u := _arr(js, all, "sol_u")
		var v := _arr(js, all, "sol_v")
		var w := _arr(js, all, "sol_w")
		var cell := _arr(js, all, "cell")
		var nx2 := int(js.nx) + 2
		var ny2 := int(js.ny) + 2
		var nz2 := int(js.nz) + 2
		var dx := float(js.dx)
		var dz := float(js.dz)
		var sy := nx2
		var sz := nx2 * ny2
		var mx := 0.0
		for k in range(1, nz2 - 1):
			for j in range(1, ny2 - 1):
				for i in range(1, nx2 - 1):
					var h := (k * ny2 + j) * nx2 + i
					if cell[h] != 1.0:
						continue
					var d := (u[h + 1] - u[h]) / dx + (v[h + sy] - v[h]) / dx + (w[h + sz] - w[h]) / dz
					mx = maxf(mx, absf(d))
		var u_ref := maxf(float(js.case_params.U10), 1.0)
		var rel := mx * dx / u_ref
		check(rel < 1.0e-5, "%s: max|∇·u|·dx/U = %s < 1e-5" % [c, String.num_scientific(rel)])


# ------------------------------------------------------------------ C3


## Порядок осей и единицы: u зависит только от i → ветер на восток (мир +x), растёт на восток;
## v только от j → мир −z, растёт на север (−Z); w_mech → мир y; θ′ и w_conv — по k.
func test_c3_from_arrays_axes_units() -> void:
	var g := _grid()
	var f := _field(
		g, func(i, _j, _k): return 1.0 + 0.1 * i, func(_i, j, _k): return 2.0 + 0.2 * j,
		func(_i, _j, _k): return 0.3, func(_i, _j, k): return 0.05 * k,
		func(_i, _j, k): return 0.01 * k, func(_i, _j): return 0.0
	)
	check(f != null, "from_arrays принимает формат C3")
	if f == null:
		return
	var p := _world(g, 20, 15, 10)
	var s := f.sample(p)
	approx(s.x, 3.0, 1.0e-5, "мир x = u (восток)")
	approx(s.y, 0.3, 1.0e-5, "мир y = w_mech")
	approx(s.z, -5.0, 1.0e-5, "мир z = −v (v на север)")
	approx(f.sample(p + Vector3(100.0, 0.0, 0.0)).x, 3.1, 1.0e-5, "u растёт на восток (i)")
	approx(f.sample(p + Vector3(0.0, 0.0, 100.0)).x, 3.0, 1.0e-5, "u не зависит от j")
	approx(f.sample(p + Vector3(0.0, 0.0, -100.0)).z, -5.2, 1.0e-5, "v растёт на север (−Z мира)")
	approx(f.sample_theta(p), 0.1, 1.0e-6, "θ′ в К, по k")
	approx(f.sample_theta(p + Vector3(0.0, 50.0, 0.0)), 0.11, 1.0e-6, "θ′ растёт с k (вверх)")
	approx(f.sample_w_conv(p), 0.5, 1.0e-6, "w_conv по k")
	# hc: индекс j·nx + i, j — север
	var fh := _field(
		g, func(_i, _j, _k): return 0.0, func(_i, _j, _k): return 0.0,
		func(_i, _j, _k): return 0.0, func(_i, _j, _k): return 0.0,
		func(_i, _j, _k): return 0.0, func(i, j): return 10.0 * j + 0.5 * i
	)
	var q := _world(g, 4, 6, 0)
	approx(fh.ground_height(q.x, q.z), 62.0, 1.0e-4, "hc[j·nx + i]")
	approx(fh.ground_height(q.x, q.z - 100.0), 72.0, 1.0e-4, "hc растёт на север (j)")
	# центр и край
	var fc := _const_field(1.0, 0.0, 0.0)
	var mid := Vector3(0.0, 300.0, 0.0)
	check(fc.contains(mid) and fc.edge_weight(mid) == 1.0, "внутри — вес 1")
	var out := Vector3(g.x0 - 10.0, 300.0, 0.0)
	check(not fc.contains(out) and fc.edge_weight(out) == 0.0, "снаружи — вес 0")
	var c := fc.center_xz()
	approx(c.x, g.x0 + 0.5 * g.nx * g.dx, 1.0e-6, "center_xz: x")
	approx(c.y, -(g.y0 + 0.5 * g.ny * g.dx), 1.0e-6, "center_xz: z мира = −y сетки")


## Маска и профиль у земли: клетки с центром ниже hc — земля; у земли (≤ z0) — 0.
func test_c3_mask_log_profile() -> void:
	var g := _grid()
	var f := _field(
		g, func(_i, _j, _k): return 4.0, func(_i, _j, _k): return 0.0,
		func(_i, _j, _k): return 0.0, func(_i, _j, _k): return 0.0,
		func(_i, _j, _k): return 0.0, func(_i, _j): return 60.0
	)
	var p := _world(g, 20, 15, 0)
	check(f.sample(Vector3(p.x, 60.05, p.z), 60.0).length() == 0.0, "ниже z0 над землёй — 0")
	var near := f.sample(Vector3(p.x, 70.0, p.z), 60.0).x
	check(near > 0.0 and near < 4.0, "лог-профиль у земли: 0 < u < u₁ (%.3f)" % near)
	approx(f.sample(Vector3(p.x, 75.0, p.z), 60.0).x, 4.0, 1.0e-5, "центр первой воздушной (k₁ = 1)")


func test_c3_sanitize_and_limits() -> void:
	var g := _grid()
	var f := _field(
		g, func(i, _j, _k): return NAN if i == 20 else 100.0, func(_i, _j, _k): return 0.0,
		func(_i, _j, _k): return 50.0, func(_i, _j, _k): return INF,
		func(_i, _j, _k): return 0.0, func(_i, _j): return 0.0
	)
	var p := _world(g, 20, 15, 10)
	approx(f.sample(p).x, 0.0, 1.0e-6, "NaN → 0")
	var s := f.sample(_world(g, 10, 15, 10))
	approx(s.x, 40.0, 1.0e-4, "|u_h| ≤ max_speed_ms (40)")
	approx(s.y, 10.0, 1.0e-4, "|w_mech| ≤ max_w_ms (10)")
	approx(f.sample_w_conv(_world(g, 10, 15, 10)), 0.0, 1.0e-6, "∞ → 0")
	check(f.limits == Vector2(40.0, 10.0), "ограничители по умолчанию 40 и 10 м/с")
	var bad := WindField.from_arrays(
		_grid(), PackedFloat32Array([1.0]), PackedFloat32Array(), PackedFloat32Array(),
		PackedFloat32Array(), PackedFloat32Array(), PackedFloat32Array()
	)
	check(bad == null, "размеры не сходятся — null")


## Грани MAC с ореолом (C1) → центры: эталон agnesi через from_mac.
func test_c3_from_mac_ref() -> void:
	var base: String = FIX + "ref/agnesi"
	var js := _json(base + ".json")
	var all := FileAccess.get_file_as_bytes(base + ".bin").to_float32_array()
	var u := _arr(js, all, "sol_u")
	var v := _arr(js, all, "sol_v")
	var w := _arr(js, all, "sol_w")
	var m := {
		dx = js.dx, dz = js.dz, x0 = js.x0, y0 = js.y0, z_bot = js.z_bot, nx = js.nx, ny = js.ny,
		nz = js.nz
	}
	var f := WindField.from_mac(
		m, u, v, w, w, _arr(js, all, "sol_th"), _arr(js, all, "cell"), _arr(js, all, "hc")
	)
	check(f != null, "from_mac принимает массивы эталона")
	if f == null:
		return
	var nx2 := int(js.nx) + 2
	var ny2 := int(js.ny) + 2
	var i := int(js.nx) / 2
	var j := int(js.ny) / 2
	var k := int(js.nz) - 2
	var h := ((k + 1) * ny2 + j + 1) * nx2 + i + 1
	var want := Vector3(
		0.5 * (u[h] + u[h + 1]), 0.5 * (w[h] + w[h + nx2 * ny2]), -0.5 * (v[h] + v[h + nx2])
	)
	var p := _world(m, i, j, k)
	var s := f.sample(p)
	check(
		(s - want).length() < 1.0e-5,
		"центр = среднее двух граней, мир (u, w, −v): %s ≠ %s" % [s, want]
	)
	approx(f.sample_w_conv(p), 0.0, 1.0e-6, "w = w_mech → w_conv = 0")
	check(absf(want.x) > 1.0, "проба в потоке (u = %.2f)" % want.x)


## Файлы полей игры (C3/C6): формат, каналы, размеры — как в контракте; load_file их читает.
func test_c3_game_field_files() -> void:
	for name: String in GAME_FIELDS:
		var base: String = FIX + name
		var js := _json(base + ".json")
		check(not js.is_empty(), name + ".json читается")
		if js.is_empty():
			continue
		check(String(js.get("format", "")) == "deltaplan-air-field", name + ": format")
		check(int(js.get("version", -1)) == 1, name + ": версия формата файла 1")
		for key in ["dx", "dz", "x0", "y0", "z_bot", "nx", "ny", "nz", "z0", "arrays"]:
			check(js.has(key), "%s: ключ %s" % [name, key])
		var n := int(js.nx) * int(js.ny) * int(js.nz)
		var arrays: Dictionary = js.arrays
		for ch: String in CHANNELS:
			check(arrays.has(ch) and int(arrays[ch][1]) == n, "%s: канал %s длины nx·ny·nz" % [name, ch])
		check(arrays.has("hc") and int(arrays.hc[1]) == int(js.nx) * int(js.ny), name + ": hc nx·ny")
		_check_packing(js, FileAccess.get_file_as_bytes(base + ".bin").size(), name)
		var f := WindField.load_file(base + ".json")
		check(f != null, name + ": load_file")
		if f == null:
			continue
		check(f.nx == int(js.nx) and f.ny == int(js.ny) and f.nz == int(js.nz), name + ": размеры")
		check(String(f.meta.get("path", "")) == base, name + ": meta.path без расширения")
		if name.begins_with("thermals/"):
			check(js.has("z_i") and js.has("u10"), name + ": z_i, u10 для термиков")
			check((js.gam as Array).size() == int(js.nz), name + ": gam — nz уровней без ореола")
			check(int(arrays.heat[1]) == int(js.nx) * int(js.ny), name + ": heat nx·ny")
			check(f.heat_flux().size() == int(js.nx) * int(js.ny), name + ": heat_flux")


# ------------------------------------------------------------------ C4


func test_c4_field_set_vector4() -> void:
	var s := AirFieldSet.new()
	var p := Vector3(0.0, 300.0, 0.0)
	var r: Variant = s.sample(p, 0.0)
	check(typeof(r) == TYPE_VECTOR4, "AirFieldSet.sample → Vector4")
	check(r == Vector4.ZERO, "без поля — (0, 0, 0, доля 0)")
	check(not s.is_active(), "без поля не активно")
	var f := _const_field(1.0, 2.0, 0.3)
	s.set_field(f, 0.0)
	var v: Vector4 = s.sample(p, 0.0)
	approx(v.w, 1.0, 1.0e-6, "внутри — доля 1")
	check(Vector3(v.x, v.y, v.z).is_equal_approx(f.sample(p, 0.0)), "xyz = WindField.sample")
	check(Vector3(v.x, v.y, v.z).is_equal_approx(Vector3(1.0, 0.3, -2.0)), "мир (u, w_mech, −v)")
	var th: Variant = s.sample_theta(p, 0.0)
	check(typeof(th) == TYPE_VECTOR2, "sample_theta → Vector2(вклад, доля)")
	check(typeof(s.sample_w_conv(p, 0.0)) == TYPE_VECTOR2, "sample_w_conv → Vector2")
	var out: Vector4 = s.sample(Vector3(1.0e5, 300.0, 0.0), 0.0)
	check(out == Vector4.ZERO, "вне поля — доля 0")
	s.set_field(null, 0.0)
	check(not s.is_active(), "set_field(null) — без поля")


func test_c4_atmosphere_analytic_direction() -> void:
	# Ветер «с юга» (180°) без поля и термиков дует на север (мир −z), вертикаль ~0 (крейт даёт малые добавки; W2 v4, фасад
	# на DpAir).
	var a := Rig.make(
		{
			"over":
			{
				"wind_speed_kmh": Units.to_kmh(3.0),
				"wind_from_deg": 180.0,
				"background_sink_ms": 0.0,
			},
			"mode": 1,
			"moist": _sun,
			"advance": 0.01,
		}
	)
	var m := a.mean_wind_at(Vector3(0.0, 300.0, 0.0))
	# Измерено m.y = -0.0072 м/с (вертикаль от слагаемых крейта, конкретный член не локализован);
	# порог 0.02 — втрое выше измеренного, прежний 1e-3 был для GD-аналитики.
	check(absf(m.y) < 0.02, "mean_wind_at без поля: вертикаль мала (%.4f)" % m.y)
	var d := Vector3(m.x, 0.0, m.z).normalized()
	check(d.z < -0.99, "ветер «с юга» (180°) дует на север: мир −z")
	a.free()


# test_c4_atmosphere_api_and_analytic (режим поля удалён в RW-P3) и
# test_c4_atmosphere_field_rule
# (внутри поля mean_wind_at = горизонталь поля + w_mech; w_conv пилоту не идёт) — поле и аналитику
# в игре
# считает крейт (RW-12s: проверки на GD-атмосфере с set_air_field удалены):
# rust/dp-air/tests/terms_analytic.rs
# (off_mode_case_equals_medium_and_uses_simple_profile), terms_thermal_field.rs
# (field_region_covers_and_off),
# terms_turb.rs (ongudai_replay_matches_air_velocity_field, slot_in_sum_on_island_field).


## C4 v3 (AM-08): величины пограничного слоя для масштаба 3 — WindField.turb_at,
## AirFieldSet.sample_turb.
func test_c4_turb_at() -> void:
	var g := _grid()
	var f := _field(
		g, func(_i, _j, _k): return 3.0, func(_i, _j, _k): return 4.0,
		func(_i, _j, _k): return -0.5, func(_i, _j, _k): return 0.0,
		func(_i, _j, _k): return 0.0, func(_i, _j): return 0.0
	)
	check(WindField.T_SIZE == 8, "T_SIZE = 8")
	var p := _world(g, 10.0, 10.0, 3.0)
	var t := f.turb_at(p, 0.0)
	check(t.size() == WindField.T_SIZE, "turb_at → T_SIZE чисел")
	# первая клетка: центр 25 м над hc = 0 (≥ dz/2) → u* = κ·5/ln(25/0,1)
	approx(t[WindField.T_USTAR], 0.4 * 5.0 / log(250.0), 1.0e-4, "u* по лог-закону")
	approx(t[WindField.T_UOUT], 5.0, 1.0e-4, "U_out — наибольшая |U_h| в слое A_OUT")
	approx(t[WindField.T_DESC], 0.1, 1.0e-4, "наклон опускания −min w / U_out")
	approx(t[WindField.T_SHEAR], 0.0, 1.0e-5, "постоянный ветер — сдвиг 0")
	check(is_nan(t[WindField.T_N2]), "нет meta.gam — N² = NAN")
	check(t[WindField.T_WSTAR] == 0.0 and t[WindField.T_HMIX] == 0.0, "нет нагрева — w* = 0, h = 0")
	var low := f.turb_at(Vector3(p.x, 10.0, p.z), 0.0)
	var s_log := 5.0 / (10.0 * log(250.0))
	approx(low[WindField.T_SHEAR], s_log, 1.0e-4, "ниже 1-й клетки — сдвиг лог-профиля")
	# устойчивость и нагрев из meta
	var g2 := _grid()
	var gam := []
	for k in int(g2.nz):
		gam.append(0.01)
	var heat := []
	for c in int(g2.nx) * int(g2.ny):
		heat.append(300.0)
	g2["gam"] = gam
	g2["heat"] = heat
	g2["z_i"] = 1500.0
	var f2 := _field(
		g2, func(_i, _j, _k): return 3.0, func(_i, _j, _k): return 4.0,
		func(_i, _j, _k): return 0.0, func(_i, _j, _k): return 0.0,
		func(_i, _j, _k): return 0.0, func(_i, _j): return 0.0
	)
	var t2 := f2.turb_at(p, 0.0)
	approx(t2[WindField.T_N2], 9.81 / 300.0 * 0.01, 1.0e-7, "N² = g/θ0·(gam + ∂θ′/∂z)")
	approx(t2[WindField.T_WSTAR], WindField.deardorff_wstar(300.0, 1500.0, 0.0), 1.0e-4, "w* Дирдорфа")
	approx(t2[WindField.T_HMIX], 1500.0, 1.0e-3, "толщина слоя z_i − hc")
	# AirFieldSet: среднее по уровням + доля
	var s := AirFieldSet.new()
	s.set_field(f, 0.0)
	var st := s.sample_turb(p, 0.0)
	check(st.size() == WindField.T_SIZE + 1, "sample_turb → T_SIZE + 1")
	approx(st[WindField.T_SIZE], 1.0, 1.0e-6, "внутри — доля 1")
	approx(st[WindField.T_USTAR], t[WindField.T_USTAR], 1.0e-6, "один уровень — как turb_at")
	var out := s.sample_turb(Vector3(1.0e5, 300.0, 0.0), 0.0)
	check(out[WindField.T_SIZE] == 0.0, "вне поля — доля 0")
	for fn in ["sample_turb"]:
		check(s.has_method(fn), "AirFieldSet." + fn)


## C4 v4 (AM-08в): размер клетки уровней в точке — для «разрешён ли пузырь отрыва решателем».
func test_c4_sample_dx() -> void:
	var s := AirFieldSet.new()
	check(s.has_method("sample_dx"), "AirFieldSet.sample_dx")
	approx(s.sample_dx(Vector3(0.0, 300.0, 0.0), 0.0), 0.0, 1.0e-9, "нет поля — 0")
	var fine := _field(
		{dx = 50.0, dz = 25.0, x0 = -500.0, y0 = -500.0, z_bot = 0.0, nx = 20, ny = 20, nz = 40},
		func(_i, _j, _k): return 1.0, func(_i, _j, _k): return 0.0,
		func(_i, _j, _k): return 0.0, func(_i, _j, _k): return 0.0,
		func(_i, _j, _k): return 0.0, func(_i, _j): return 0.0
	)
	var coarse := _const_field(2.0, 0.0, 0.0)
	s.set_field(coarse, 0.0)
	approx(s.sample_dx(Vector3(0.0, 300.0, 0.0), 0.0), 100.0, 1.0e-4, "один уровень — его dx")
	s.set_field([fine, coarse], 0.0)
	approx(s.sample_dx(Vector3(0.0, 300.0, 0.0), 0.0), 50.0, 1.0e-4, "внутри мелкого — его dx")
	approx(s.sample_dx(Vector3(1200.0, 300.0, 0.0), 0.0), 100.0, 1.0e-4, "вне мелкого — грубый")
	var e := s.sample_dx(Vector3(450.0, 300.0, 0.0), 0.0)
	check(e > 50.0 and e < 100.0, "в полосе края мелкого — между: %.1f" % e)
	approx(s.sample_dx(Vector3(1.0e5, 300.0, 0.0), 0.0), 0.0, 1.0e-9, "вне поля — 0")


## C4 v5: ключи подветренной эвристики поверх поля (у каждого _doc); LTM v1 — σ_v слоя, снятие стенки.
func test_c4_lee_keys() -> void:
	var l: Dictionary = Config.get_config("atmosphere").get("lee", {})
	for key in [
		"field_burst_per_du", "field_reverse_per_uh", "field_bubble_length_per_relief",
		"field_resolved_cells", "field_sigma_u_per_du", "field_sigma_v_per_du",
		"field_sigma_w_per_du", "field_wall_shear_off_agl_per_relief"
	]:
		check(l.has(key), "lee." + key)
		check(l.has(key + "_doc"), "lee.%s_doc" % key)
	check(not l.has("field_reverse_per_wind"), "field_reverse_per_wind заменён field_reverse_per_uh")
	var rc: Variant = l.get("field_resolved_cells", [])
	check(rc is Array and (rc as Array).size() == 2 and float(rc[0]) < float(rc[1]), "n0 < n1")
	var wo: Variant = l.get("field_wall_shear_off_agl_per_relief", [])
	check(wo is Array and (wo as Array).size() == 2 and float(wo[0]) < float(wo[1]), "a0 < a1")
	approx(float(l.get("field_sigma_v_per_du", 0.0)), 0.130, 1.0e-9, "σ_v/ΔU = 0,130")


func test_c4_config_keys() -> void:
	var ac: Dictionary = Config.get_config("atmosphere").get("air_model", {})
	var keys := [
		"edge_blend_cells", "blend_s", "recompute_game_min", "max_speed_ms", "max_w_ms"
	]
	for key in keys:
		check(ac.has(key), "air_model." + key)
		check(ac.has(key + "_doc"), "air_model.%s_doc" % key)
	check(not ac.has("enabled"), "режима поля в конфиге нет")


# ------------------------------------------------------------------ C6


## Р3: файл поля другой версии формата — отказ load_file (понятная ошибка), не чтение.
func test_c6_field_version() -> void:
	var src := FIX + "field/kayancha_w100_h13_U3_d180"
	var js := _json(src + ".json")
	check(int(js.get("version", 0)) == WindField.FORMAT_VERSION, "фикстура — текущей версии")
	js.version = WindField.FORMAT_VERSION + 1
	var dst := "user://c6_version_test"
	var fj := FileAccess.open(dst + ".json", FileAccess.WRITE)
	fj.store_string(JSON.stringify(js))
	fj.close()
	var fb := FileAccess.open(dst + ".bin", FileAccess.WRITE)
	fb.store_buffer(FileAccess.get_file_as_bytes(src + ".bin"))
	fb.close()
	check(WindField.load_file(dst) == null, "версия %d — отказ" % js.version)
	check(WindField.load_file(src) != null, "версия 1 — читается")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dst + ".json"))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dst + ".bin"))


func test_c6_start_hours() -> void:
	check(
		SunClock.start_hours() == PackedFloat32Array([9.0, 12.0, 15.0, 20.0]),
		"часы старта [9, 12, 15, 20]"
	)
	approx(SunClock.nearest_start_hour(10.0), 9.0, 1.0e-6, "ближайший к 10:00")
	approx(SunClock.nearest_start_hour(13.6), 15.0, 1.0e-6, "ближайший к 13:36")


# ------------------------------------------------------------------ C8


func test_c8_blend() -> void:
	var f := _const_field(4.0, 0.0, 0.0)
	var s := AirFieldSet.new()
	s.set_field(f, 10.0)
	var p := Vector3(0.0, 300.0, 0.0)
	approx(s.blend_fraction(), 0.0, 1.0e-6, "подмена начинается с 0")
	s.advance(5.0)
	var v: Vector4 = s.sample(p, 0.0)
	approx(s.blend_fraction(), 0.5, 1.0e-6, "smoothstep(½) = ½")
	approx(v.w, 0.5, 1.0e-6, "из аналитики: доля поля ½")
	approx(v.x, 2.0, 1.0e-5, "вклад ½ поля")
	s.advance(5.0)
	approx(s.blend_fraction(), 1.0, 1.0e-6, "подмена закончена")
	s.set_field(null, 10.0)
	check(s.is_active(), "плавное выключение — ещё активно")
	s.advance(10.0)
	check(not s.is_active(), "после blend_s — без поля")
	# blend_s = −1 у атмосферы — air_model.blend_s
	var a := _atmo()
	a.set_air_field(f)
	approx(a.air_field.blend_fraction(), 0.0, 1.0e-6, "set_air_field(f): подмена началась")
	a.air_field.advance(float(Config.get_config("atmosphere").air_model.blend_s) * 0.5)
	approx(a.air_field.blend_fraction(), 0.5, 1.0e-6, "по умолчанию — air_model.blend_s")
	a.free()


## C8 v2 (Р7): подмена во время подмены — «старым» становится снимок текущей смеси, без скачка.
func test_c8_blend_during_blend() -> void:
	var p := Vector3(0.0, 300.0, 0.0)
	var s := AirFieldSet.new()
	s.set_field(_const_field(2.0, 0.0, 0.0), 0.0)
	s.set_field(_const_field(6.0, 0.0, 0.0), 10.0)
	s.advance(3.0)
	var before: Vector4 = s.sample(p, 0.0)
	s.set_field(_const_field(10.0, 0.0, 0.0), 10.0)
	var after: Vector4 = s.sample(p, 0.0)
	approx(after.x, before.x, 1.0e-4, "новое поле посреди подмены — без скачка")
	s.advance(4.0)
	s.set_field(null, 10.0)  # и выключение посреди подмены
	var v1: Vector4 = s.sample(p, 0.0)
	s.advance(0.1)
	var v2: Vector4 = s.sample(p, 0.0)
	check(absf(v2.x - v1.x) < 0.05, "плавно к аналитике: %.3f → %.3f" % [v1.x, v2.x])
	s.advance(10.0)
	check(not s.is_active(), "после blend_s — без поля")


