# gdlint: disable=max-public-methods
extends TestCase
## Контрактные тесты модели воздуха (docs/contracts/air-model.md): форма данных и соглашения на
## стыках задач AM-xx. Без GPU. Ломаются, если владелец поменял формат/интерфейс без правки
## контракта; правка контракта (версия +1) — вместе с правкой этого файла (CONTRACTS ниже).

## Версии разделов контракта — те же, что в заголовках docs/contracts/air-model.md.
const CONTRACTS := {C1 = 2, C2 = 7, C3 = 1, C4 = 4, C5 = 1, C6 = 1, C7 = 3, C8 = 2, C9 = 3, C10 = 3}
const DOC := "res://docs/contracts/air-model.md"
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
	var w: Dictionary = Config.get_config("weather/medium").duplicate(true)
	w.wind_speed_kmh = Units.to_kmh(3.0)
	w.wind_from_deg = 180.0
	w.thermal_mode = "static"
	w.static_thermals = []
	w.background_sink_ms = 0.0
	var a := Atmosphere.new()
	a.visuals_enabled = false
	a.configure(Config.get_config("atmosphere"), w)
	a.set_ground(_flat, _sun)
	a.set_thermal_mode("static")
	a.turbulence_enabled = false
	a.wave.enabled = false
	a.step(0.01)
	return a


# ------------------------------------------------------------------ версии


func test_contract_versions() -> void:
	var text := FileAccess.get_file_as_string(DOC)
	check(text != "", "есть " + DOC)
	var re := RegEx.create_from_string("(?m)^## (C\\d+) v(\\d+)")
	var found := {}
	for m in re.search_all(text):
		found[m.get_string(1)] = int(m.get_string(2))
	for c: String in CONTRACTS:
		check(found.has(c), "раздел %s в контракте" % c)
		check(
			int(found.get(c, -1)) == int(CONTRACTS[c]),
			"%s: версия в документе v%s ≠ в тесте v%s" % [c, found.get(c, "?"), CONTRACTS[c]]
		)
	check(found.size() == CONTRACTS.size(), "лишние разделы в контракте: %s" % [found.keys()])


# ------------------------------------------------------------------ thd (C2 v3, C7 v2)

const JOB_DIR := "res://scripts/atmosphere/air_model/"


## Тело функции (от «func name» до следующей «func» / конца файла) по тексту скрипта — проверка
## без GPU: задачи создаются только на GPU, поэтому ключи словарей ловим статически.
static func _func_body(path: String, fname: String) -> String:
	var text := FileAccess.get_file_as_string(path)
	var a := text.find("func %s(" % fname)
	if a < 0:
		return ""
	var b := text.find("\nfunc ", a + 1)
	return text.substr(a, (b if b >= 0 else text.length()) - a)


func test_thd_in_state_keys() -> void:
	var job := JOB_DIR + "air_picard_job.gd"
	var st := _func_body(job, "state")
	check(st != "", "AirPicardJob.state найден")
	check('"thd"' in st, "C2 v3: state() отдаёт ключ thd")
	check('"thdm"' in st, "C2 v3: state(mech) читает thdm (без нагрева)")
	var pd := _func_body(job, "parent_data")
	check("heat" in pd and "mech" in pd, "C7 v2: parent_data() отдаёт heat и mech")
	check("state(" in pd, "C7 v2: parent_data().heat/mech строятся из state() (с thd)")
	var ws := _func_body(JOB_DIR + "air_window_job.gd", "window_state")
	check(ws != "", "AirWindowJob.window_state найден")
	check("heat = state(false)" in ws and "mech = state(true)" in ws, "C7 v2: window_state() с thd")
	var warm := FileAccess.get_file_as_string(job)
	check("warm" in warm and "thd" in warm, "C2 v3: warm принимает thd")


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


# ------------------------------------------------------------------ C2


func test_c2_air_case_grid() -> void:
	check(is_equal_approx(AirPlace.DOMAIN_L, 38400.0), "область места 38,4 км")
	var c := AirCase.new()
	c.set_grid(400.0, 96, 80, 105.0, 420.0, 50, -19200.0, -16000.0)
	check(c.dims() == Vector3i(98, 82, 52), "dims = (nx+2, ny+2, nz+2)")
	approx(c.zc(1), 420.0 + 52.5, 1.0e-9, "zc(1) — центр первой внутренней клетки")
	approx(c.zc(0), 420.0 - 52.5, 1.0e-9, "zc(0) — ореол под низом")
	# AirCase.meta(): ключи WindField + вход термиков (C3/C4: heat ny·nx, z_i — ключа нет при NAN,
	# gam nz без ореола, u10, wdir); поле с этой meta — вход термиков есть.
	var m := _case_meta(c, 2000.0)
	for k in ["dx", "dz", "x0", "y0", "z_bot", "nx", "ny", "nz", "z0", "u10", "wdir", "heat", "gam"]:
		check(m.has(k), "AirCase.meta(): ключ " + k)
	var mh: Variant = m.get("heat")
	check(mh is PackedFloat32Array and (mh as PackedFloat32Array).size() == 96 * 80, "heat ny·nx")
	check(m.get("gam") is PackedFloat32Array and (m.gam as PackedFloat32Array).size() == 50, "gam nz")
	check(m.has("z_i") and is_equal_approx(float(m.z_i), 2000.0), "z_i")
	check(not _case_meta(c, NAN).has("z_i"), "z_i = NAN — ключа нет")
	var n := 96 * 80 * 50
	var z := PackedFloat32Array()
	z.resize(n)
	var hc := PackedFloat32Array()
	hc.resize(96 * 80)
	var f := WindField.from_arrays(m, z, z, z, z, z, hc)
	check(f != null and AirThermals.has_inputs(f), "поле с meta решателя — вход термиков есть")
	check(f.heat_flux().size() == 96 * 80 and f.gam().size() == 50, "геттеры C4 v2: heat, gam")
	check(f.z_i() == 2000.0 and f.u10() == 3.0, "геттеры C4 v2: z_i, u10")
	var nh := c.without_heat()
	check(nh.heat.is_empty(), "without_heat(): H = 0")
	check(nh.dims() == c.dims(), "without_heat(): та же сетка")


## C2 v6 (air-start): ветер меню — на 10 м над стартом; приток области/окна умножен на inflow_k, а
## α, класс устойчивости и max_profile — по ветру меню; k = 1 — прежний случай. Вызов через callv —
## файл разбирается и без нового аргумента (тогда проверка падает, а не весь набор).
## C2 v7: клетка ровно dx на земле — билинейно на решётку 25 м мира (x = x0 + 25·m, y — север) и блочное
## среднее f = dx/25 узлов; линейное поле на слое с «чужим» шагом даёт точное среднее по узлам.
static func _linear_layer(s: float, n: int, dox: float, doz: float) -> HeightLayer:
	var ox := -0.5 * (n - 1) * s + dox
	var oz := -0.5 * (n - 1) * s + doz
	var hs := PackedFloat32Array()
	hs.resize(n * n)
	for j in n:
		for i in n:
			var x := ox + i * s
			var y := -(oz + j * s)  # строка слоя растёт на юг (z игры = −y)
			hs[j * n + i] = 1000.0 + 0.01 * x + 0.02 * y
	return HeightLayer.from_heights("detail", n, n, s, ox, oz, hs)


func _check_linear_cells(
	l: HeightLayer, x0: float, y0: float, dx: float, n: int, tag: String
) -> void:
	var hc := AirPlace.block_mean(l, x0, y0, dx, n, n)
	check(hc.size() == n * n, "%s: клеток n·n" % tag)
	if hc.size() != n * n:
		return
	var off := 0.5 * (dx - 25.0)  # средний узел клетки относительно её юго-западного узла
	var worst := 0.0
	for j in n:
		for i in n:
			var e := 1000.0 + 0.01 * (x0 + dx * i + off) + 0.02 * (y0 + dx * j + off)
			worst = maxf(worst, absf(hc[j * n + i] - e))
	check(worst <= 1.0e-3, "%s: клетка = среднее узлов решётки 25 м, max|Δ| = %s м" % [tag, worst])


func test_c2_cell_geometry() -> void:
	# Слой рантайма на ~51° (s ≈ 24,05 м, f·s прежде 408,9 м), начало сдвинуто на долю пикселя.
	var l := _linear_layer(24.05, 1665, 7.3, -5.1)
	_check_linear_cells(l, -19200.0, -19200.0, 400.0, 96, "область 400 м, s 24,05")
	# Южное полушарие −33,7° (s ≈ 31,8 м, прежде f·s 413 м).
	_check_linear_cells(_linear_layer(31.8, 1281, -11.0, 9.4), -19200.0, -19200.0, 400.0, 96, "s 31,8")
	# Окно AM-04: dx 200, угол кратен 25 м.
	_check_linear_cells(l, -3125.0, 4100.0, 200.0, 64, "окно 200 м")
	# domain_case: dx решателя = 400, область ровно 38,4 км вокруг центра мира, hc — те же клетки.
	var loc := {id = "geom", center_lat = 50.79, center_lon = 86.13, utc_offset_h = 7}
	var c := AirPlace.domain_case(l, null, loc, 400.0, 12.0, 3.0, 150.0, NAN, "clear", false)
	check(c != null, "domain_case на слое рантайма ~51° не пустой")
	if c != null:
		check(c.nx == 96 and c.ny == 96, "96 × 96 клеток")
		approx(c.dx, 400.0, 0.0, "dx решателя = 400 = клетка на земле")
		approx(c.x0, -19200.0, 0.0, "x0 = −DOMAIN_L/2")
		approx(c.y0, -19200.0, 0.0, "y0 = −DOMAIN_L/2")
		var hb := AirPlace.block_mean(l, -19200.0, -19200.0, 400.0, 96, 96)
		check(c.hc == hb, "domain_case.hc = block_mean той же области")
	# Встроенный формат data/terrain (25 м, начало −20 000, 1601²): прямое среднее 16 × 16 узлов слоя.
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var nb := 1601
	var hs := PackedFloat32Array()
	hs.resize(nb * nb)
	for k in hs.size():
		hs[k] = rng.randf_range(200.0, 2500.0)
	var lb := HeightLayer.from_heights("detail", nb, nb, 25.0, -20000.0, -20000.0, hs)
	var hc := AirPlace.block_mean(lb, -19200.0, -19200.0, 400.0, 96, 96)
	check(hc.size() == 96 * 96, "встроенный слой: 96 × 96")
	if hc.size() == 96 * 96:
		var worst := 0.0
		for j in [0, 17, 48, 95]:
			for i in [0, 31, 64, 95]:
				var acc := 0.0
				for jn in range(32 + 16 * j, 48 + 16 * j):
					var row := (nb - 1 - jn) * nb  # строка слоя растёт на юг
					for inode in range(32 + 16 * i, 48 + 16 * i):
						acc += hs[row + inode]
				worst = maxf(worst, absf(hc[j * 96 + i] - acc / 256.0))
		check(worst <= 1.0e-6, "встроенный слой: как прямое среднее 16 × 16, max|Δ| = %s м" % worst)
	# Вне слоя — пусто.
	var small := _linear_layer(24.05, 1201, 0.0, 0.0)
	check(AirPlace.block_mean(small, -19200.0, -19200.0, 400.0, 96, 96).is_empty(), "вне слоя → пусто")


func test_c2_inflow_scale() -> void:
	var lw := TestAirPlace.load_detail("ongudai")
	check(lw.size() == 2, "слой detail Онгудая")
	if lw.size() != 2:
		return
	var loc := TestAirPlace.load_loc("ongudai")
	var dc := Callable(AirPlace, "domain_case")
	var a: AirCase = dc.callv([lw[0], lw[1], loc, 400.0, 12.0, 6.0, 150.0, NAN, "clear", false])
	var b: AirCase = dc.callv([lw[0], lw[1], loc, 400.0, 12.0, 6.0, 150.0, NAN, "clear", false, 1.4])
	check(a != null and b != null, "domain_case(…, inflow_k)")
	if a == null or b == null:
		return
	approx(a.u10, 6.0, 1e-9, "k по умолчанию 1: приток = меню")
	approx(b.u10, 8.4, 1e-9, "приток = k·меню")
	check("u10_menu" in b and "inflow_k" in b, "AirCase.u10_menu, inflow_k")
	if "u10_menu" in b:
		approx(float(b.get("u10_menu")), 6.0, 1e-9, "u10_menu")
		approx(float(b.get("inflow_k")), 1.4, 1e-9, "inflow_k")
	approx(float(b.p.alpha), float(a.p.alpha), 1e-12, "α — по ветру меню")
	approx(float(b.p.max_profile), float(a.p.max_profile), 1e-12, "max_profile (z_sat) — по ветру меню")
	var m := b.meta()
	check(m.has("u10_menu") and m.has("inflow_k"), "meta(): u10_menu, inflow_k")
	approx(float(m.get("u10", 0.0)), 8.4, 1e-9, "meta.u10 — приток")
	var nh := b.without_heat()
	approx(nh.u10, 8.4, 1e-9, "without_heat: приток")
	if "inflow_k" in nh:
		approx(float(nh.get("inflow_k")), 1.4, 1e-9, "without_heat: inflow_k")
	var ctx := AirPlace.context(lw[0], loc, WeatherModel.config())
	var wc := Callable(AirWindowCase, "window_case")
	var w: AirCase = wc.callv(
		[lw[0], lw[1], loc, 100.0, 7230.0, -1330.0, 12.0, 6.0, 150.0, NAN, "clear", false, ctx, 64, 1.4]
	)
	check(w != null, "window_case(…, n, inflow_k)")
	if w != null:
		approx(w.u10, 8.4, 1e-9, "окно: приток = k·меню")
		approx(float(w.p.max_profile), float(a.p.max_profile), 1e-12, "окно: max_profile по меню")


## C2 v4 (инвариант, 01.10.2026): `AirCase.p` игры = `Params()` эталона air.py по всем общим
## ключам, кроме профиля притока alpha/max_profile (у случая — из WindProfile; None эталона ↔ NAN
## игры не сверяются); `Params().alpha` = α_N = `wind.shear_exponent_neutral`; WindProfile и
## rules.py (C10 v3) на контрольных входах дают одно z_sat/max_profile; WindModel берёт α и предел
## из той же функции. Ломается, если параметр поменяли в одном месте.
func test_c2_params_match_reference() -> void:
	var src := FileAccess.get_file_as_string("res://tools/research/air3d/air.py")
	check(src != "", "есть air.py")
	var a := src.find("class Params:")
	var b := src.find("\n\n\n", a)
	check(a >= 0 and b > a, "air.py: class Params")
	var body := src.substr(a, b - a)
	var pat := "(?m)^    (\\w+): (?:float|int|bool)(?: \\| None)? = ([^#\\n]+)"
	var re := RegEx.create_from_string(pat)
	var p: Dictionary = AirCase.new().p
	var seen := 0
	var ref_alpha := NAN
	for m in re.search_all(body):
		var key := m.get_string(1)
		var lit := m.get_string(2).strip_edges()
		if not p.has(key) or lit == "None":
			continue
		var e := Expression.new()
		var ok := e.parse(lit.replace("True", "true").replace("False", "false")) == OK
		var ref: Variant = e.execute() if ok else null
		check(ok and not e.has_execute_failed(), "air.py Params.%s = %s разбирается" % [key, lit])
		if key == "alpha":
			ref_alpha = float(ref)
		if ref is bool:
			check(bool(p[key]) == ref, "AirCase.p.%s = %s, air.py %s" % [key, p[key], ref])
		else:
			var r := float(ref)
			var g := float(p[key])
			var same := absf(g - r) <= 1.0e-9 * maxf(absf(r), 1.0)
			check(same, "AirCase.p.%s = %s, air.py Params = %s" % [key, g, r])
		seen += 1
	check(seen >= 20, "сверено общих ключей: %d" % seen)
	check(is_nan(float(p.max_profile)), "AirCase.p.max_profile по умолчанию — правило z_sat (NAN)")
	# α_N: конфиг = Params().alpha = AirCase.p.alpha = WindProfile.alpha_n()
	var wind: Dictionary = _json("res://configs/atmosphere.json").get("wind", {})
	check(
		not wind.has("shear_exponent") and not wind.has("max_profile_factor"), "старые ключи удалены"
	)
	var an := float(wind.get("shear_exponent_neutral", NAN))
	approx(an, 0.24, 1.0e-12, "wind.shear_exponent_neutral = 0,24 (Б1)")
	approx(ref_alpha, an, 1.0e-12, "air.py Params().alpha = α_N")
	approx(WindProfile.alpha_n(), an, 1.0e-12, "WindProfile.alpha_n() = конфиг")
	approx(float(wind.get("z_sat_frac", NAN)), 0.3, 1.0e-12, "wind.z_sat_frac = 0,3 (rules.py)")
	# z_sat и max_profile = rules.py (C10 v3): (α, U10, z0, f) → (z_sat, max_profile), числа rules.py
	var ctl := [
		[0.24, 3.0, 0.1, 1.13e-4, 207.53895595376636, 2.0706367164370936],
		[0.112, 6.0, 0.1, 1.13e-4, 415.0779119075327, 1.5178558116209047],
		[0.56, 3.0, 0.1, 1.13e-4, 207.53895595376636, 5.464819115772987],
		[0.235, 8.8, 0.03, 1.23e-4, 443.37172632728226, 2.437757373849812],
	]
	for r: Array in ctl:
		var tag := "α %s U10 %s z0 %s f %s" % [r[0], r[1], r[2], r[3]]
		approx(WindProfile.z_sat(r[1], r[2], r[3]), r[4], 1.0e-9 * r[4], "z_sat = rules.py: " + tag)
		approx(
			WindProfile.max_profile(r[0], r[1], r[2], r[3]),
			r[5],
			1.0e-9 * r[5],
			"max_profile = rules.py: " + tag
		)
	# C2 v5: устойчивые E, F — h = min(0,3u*/f, 0,4√(u*L/f)), L по Golder 1972 (числа wind_prof.py:
	# E при z0 0,1 м — L 45,5 м, F — 14,1 м); (α, U10, z0, f, класс) → (z_sat, max_profile)
	var ctl_s := [
		[0.56, 3.0, 0.1, 1.13e-4, 4, 38.85066569723485, 2.1382729414369037],
		[0.88, 3.0, 0.1, 1.13e-4, 5, 21.626220702370595, 1.9714372357973053],
		[0.88, 5.0, 0.1, 1.13e-4, 5, 27.91933087389579, 2.4682912571816895],
	]
	for r: Array in ctl_s:
		var mp := WindProfile.max_profile(r[0], r[1], r[2], r[3], r[4])
		approx(WindProfile.z_sat(r[1], r[2], r[3], r[4]), r[5], 1.0e-9 * r[5], "z_sat E/F %s" % r)
		approx(mp, r[6], 1.0e-9 * r[6], "max_profile E/F %s" % r)
	approx(WindProfile.z_sat(3.0, 0.1, 1.13e-4, 3), ctl[0][4], 1.0e-6, "D — как rules.py")
	# класс Тёрнера → α (Irwin 1979 к D): полдень ясно — A (штиль), B (3 м/с), D (6 м/с);
	# облачно 3 м/с — D; ночь ясно 3 м/с — F, облачно — E
	var cls := [
		[0.0, 56.8, 0.0, 0], [3.0, 56.8, 0.0, 1], [6.0, 56.8, 0.0, 3], [3.0, 56.8, 0.85, 3],
		[3.0, 32.1, 0.0, 2], [3.0, 4.7, 0.0, 5], [3.0, 4.7, 0.85, 4], [3.0, 10.8, 0.0, 3],
	]
	for r: Array in cls:
		var k := WindProfile.stability_class(r[0], r[1], r[2])
		check(
			k == r[3],
			"класс U10 %s, солнце %s°, облачность %s: %s (ждали %s)"
			% [r[0], r[1], r[2], WindProfile.CLASSES[k], WindProfile.CLASSES[r[3]]]
		)
	approx(WindProfile.alpha(6.0, 56.8, 0.0), an, 1.0e-12, "класс D: α = α_N")
	approx(WindProfile.alpha(3.0, 56.8, 0.0), an * 0.07 / 0.15, 1.0e-12, "класс B: α = α_N·0,07/0,15")
	# одна функция у решателя и WindModel: тот же час и ветер → те же α и предел
	var ctx := {month = 7, day = 15, lat = 50.79, lon = 86.13, utc_offset_h = 7.0}
	var c := AirCase.new()
	c.u10 = 3.0
	WindProfile.apply_to_case(c, ctx, 12.0, 0.0)
	var sun := WindProfile.sun_elevation(ctx, 12.0)
	var wm := WindModel.new()
	var cfg := _json("res://configs/atmosphere.json")
	wm.setup(cfg.wind, cfg.turbulence, 1)
	wm.set_conditions(sun, 0.0)
	wm.set_wind(3.0, 150.0)
	var pp := wm.profile_params()
	approx(pp.x, float(c.p.alpha), 1.0e-6, "WindModel α = α случая решателя (12:00, 3 м/с)")
	approx(pp.y, float(c.p.max_profile), 1.0e-6, "WindModel предел = max_profile случая")
	approx(wm.profile(1.0e4), float(c.p.max_profile), 1.0e-6, "WindModel выше z_sat = max_profile")
	# вечер, ясно, 3 м/с — класс F: на 300 м ≈ 2·U10, а не 14·U10 (v4)
	wm.set_conditions(6.4, 0.0)
	approx(wm.profile(300.0), 1.9714372357973053, 1.0e-6, "F: WindModel на 300 м = max_profile F")


static func _case_meta(c: AirCase, z_i: float) -> Dictionary:
	c.hc = PackedFloat64Array()
	c.hc.resize(96 * 80)
	c.hc.fill(500.0)
	c.gam = PackedFloat64Array()
	c.gam.resize(52)
	c.gam.fill(0.003)
	c.heat = PackedFloat64Array()
	c.heat.resize(96 * 80)
	c.heat.fill(250.0)
	c.z_i = z_i
	c.u10 = 3.0
	c.wdir = 150.0
	c.prepare()
	return c.meta()


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
			check(AirThermals.has_inputs(f), name + ": вход термиков есть")
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


func test_c4_atmosphere_api_and_analytic() -> void:
	var a := _atmo()
	for fn in [
		"set_air_field", "set_air_mode", "is_air_field_on", "air_velocity_at", "mean_wind_at",
		"thermals_near"
	]:
		check(a.has_method(fn), "Atmosphere." + fn)
	check(a.air_field is AirFieldSet, "air_field — AirFieldSet после configure")
	check(not a.is_air_field_on(), "без поля — аналитика")
	var p := Vector3(0.0, 300.0, 0.0)
	var m := a.mean_wind_at(p)
	check(m.y == 0.0, "mean_wind_at без поля: вертикаль 0")
	var d := Vector3(m.x, 0.0, m.z).normalized()
	check(d.is_equal_approx(a.wind.dir), "mean_wind_at без поля — по WindModel.dir")
	check(d.z < -0.99, "ветер «с юга» (180°) дует на север: мир −z")
	# поле есть, но режим off — побитно аналитика
	var b := _atmo()
	b.set_air_field(_const_field(7.0, 7.0, 1.0), 0.0)
	check(b.is_air_field_on(), "поле включено (auto)")
	b.set_air_mode("off")
	check(not b.is_air_field_on(), "set_air_mode(off) — аналитика")
	for q in [p, Vector3(500.0, 80.0, -300.0), Vector3(-900.0, 900.0, 400.0)]:
		check(b.air_velocity_at(q) == a.air_velocity_at(q), "off = аналитика побитно в %s" % q)
		check(b.mean_wind_at(q) == a.mean_wind_at(q), "off: mean_wind_at = аналитика в %s" % q)
	a.free()
	b.free()


## Правило стыка: внутри поля mean_wind_at = горизонталь поля + w_mech; w_conv пилоту не идёт.
func test_c4_atmosphere_field_rule() -> void:
	var g := _grid()
	var f := _field(
		g, func(_i, _j, _k): return 1.0, func(_i, _j, _k): return 2.0,
		func(_i, _j, _k): return 0.3, func(_i, _j, _k): return 5.0,
		func(_i, _j, _k): return 0.0, func(_i, _j): return 0.0
	)
	var a := _atmo()
	a.set_air_field(f, 0.0)
	var p := Vector3(0.0, 300.0, 0.0)
	check(a.mean_wind_at(p).is_equal_approx(Vector3(1.0, 0.3, -2.0)), "mean_wind_at = поле")
	var ref := _atmo()
	ref.set_air_field(_const_field(1.0, 2.0, 0.3), 0.0)
	check(
		a.air_velocity_at(p).is_equal_approx(ref.air_velocity_at(p)),
		"w_conv поля не меняет air_velocity_at без термиков из поля"
	)
	a.free()
	ref.free()


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


## C4 v4: ключи подветренной эвристики поверх поля (у каждого _doc).
func test_c4_lee_keys() -> void:
	var l: Dictionary = Config.get_config("atmosphere").get("lee", {})
	for key in [
		"field_burst_per_du", "field_reverse_per_uh", "field_bubble_length_per_relief",
		"field_resolved_cells", "field_sigma_u_per_du", "field_sigma_w_per_du"
	]:
		check(l.has(key), "lee." + key)
		check(l.has(key + "_doc"), "lee.%s_doc" % key)
	check(not l.has("field_reverse_per_wind"), "field_reverse_per_wind заменён field_reverse_per_uh")
	var rc: Variant = l.get("field_resolved_cells", [])
	check(rc is Array and (rc as Array).size() == 2 and float(rc[0]) < float(rc[1]), "n0 < n1")


func test_c4_config_keys() -> void:
	var ac: Dictionary = Config.get_config("atmosphere").get("air_model", {})
	var keys := [
		"enabled", "edge_blend_cells", "blend_s", "recompute_game_min", "max_speed_ms", "max_w_ms"
	]
	for key in keys:
		check(ac.has(key), "air_model." + key)
		check(
			ac.has(key + "_doc") or key == "enabled" and ac.has("enabled_doc"), "air_model.%s_doc" % key
		)
	check(String(ac.get("enabled", "")) in ["auto", "on", "off"], "enabled ∈ auto/on/off")


# ------------------------------------------------------------------ C5


func test_c5_signature_and_mask() -> void:
	var g := {dx = 400.0, dz = 50.0, x0 = -19200.0, y0 = -19200.0, z_bot = 0.0, nx = 4, ny = 4, nz = 2}
	var zero := func(_i, _j, _k): return 0.0
	var f := _field(g, zero, zero, zero, zero, zero, func(_i, _j): return 0.0)
	check(AirThermals.signature(f) == "400.000,-19200.000,-19200.000,4,4", "подпись dx,x0,y0,nx,ny")
	var t := AirThermals.new()
	t.level = f
	t.col = PackedInt32Array([1, 10])  # (i 1, j 0) и (i 2, j 2)
	var mask := t.mask_bytes()
	check(mask.size() == (4 * 4 + 7) >> 3, "маска (nx·ny + 7) >> 3 байт")
	check(mask == PackedByteArray([2, 4]), "бит j·nx + i, младший бит байта — первый")
	check(Marshalls.raw_to_base64(mask) == "AgQ=", "base64 как в docs/guide/net-protocol.md")


func test_c5_net_schema() -> void:
	var zs: Dictionary = NetMessages.MESSAGES.get("ZoneState", {})
	check(String(zs.get("thermalSources", "")) == "msg:ThermalSources", "ZoneState.thermalSources")
	check(
		NetMessages.MESSAGES.get("ThermalSources", {}) == {"grid": "string", "mask": "string"},
		"ThermalSources = {grid, mask (base64)}"
	)
	check(NetMessages.NULLABLE.has("ZoneState.thermalSources"), "thermalSources может отсутствовать")
	var proto := FileAccess.get_file_as_string("res://server/proto/deltaplan/v1/net.proto")
	check(
		proto.contains("ThermalSources thermal_sources = 3;"), "proto: ZoneState.thermal_sources = 3"
	)
	check(
		proto.contains("string grid = 1;") and proto.contains("bytes mask = 2;"),
		"proto: grid = 1, mask = 2"
	)


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


# ------------------------------------------------------------------ C7


func test_c7_levels_fine_to_coarse() -> void:
	var fine := _field(
		{dx = 50.0, dz = 25.0, x0 = -500.0, y0 = -500.0, z_bot = 0.0, nx = 20, ny = 20, nz = 40},
		func(_i, _j, _k): return 1.0, func(_i, _j, _k): return 0.0,
		func(_i, _j, _k): return 0.0, func(_i, _j, _k): return 0.0,
		func(_i, _j, _k): return 0.0, func(_i, _j): return 0.0
	)
	var coarse := _const_field(2.0, 0.0, 0.0)
	var s := AirFieldSet.new()
	s.set_field([fine, coarse], 0.0)
	check(s.levels.size() == 2 and s.levels[0] == fine, "levels — от мелкого к грубому")
	var v: Vector4 = s.sample(Vector3(0.0, 300.0, 0.0), 0.0)
	approx(v.x, 1.0, 1.0e-5, "внутри мелкого — мелкий")
	approx(v.w, 1.0, 1.0e-6, "доля 1")
	v = s.sample(Vector3(1200.0, 300.0, 0.0), 0.0)
	approx(v.x, 2.0, 1.0e-5, "вне мелкого — грубый")
	check(
		fine.edge_cells == s.edge_cells,
		"ширина края — клеток своего уровня (air_model.edge_blend_cells)"
	)


func test_c7_window_grid_and_api() -> void:
	var lw := TestAirPlace.load_detail("ongudai")
	check(lw.size() == 2, "слой detail Онгудая")
	if lw.size() != 2:
		return
	var loc := TestAirPlace.load_loc("ongudai")
	var ctx := AirPlace.context(lw[0], loc, WeatherModel.config())
	var c := AirWindowCase.window_case(
		lw[0], lw[1], loc, 100.0, 7230.0, -1330.0, 12.0, 3.0, 150.0, NAN, "clear", true, ctx
	)
	check(c != null, "окно построено")
	if c == null:
		return
	check(c.nx == 64 and c.ny == 64 and c.dz == 50.0, "окно 64 × 64, dz = dx/2")
	check(fmod(c.x0, 25.0) == 0.0 and fmod(c.y0, 25.0) == 0.0, "угол кратен 25 м")
	var lo := INF
	var hi := -INF
	for v in c.hc:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	check(c.z_bot == floorf(lo / c.dz) * c.dz - c.dz, "z_bot = ⌊h_min/dz⌋·dz − dz")
	check(c.nz % 2 == 0 and c.z_bot + c.nz * c.dz >= hi + 2000.0, "верх ≥ h_max + 2000, nz чётное")
	check(c.meta().get("level", "") == "window", "meta.level = window")
	var cm := AirClipmap.new()
	for m in [
		"setup", "set_conditions", "set_domain", "start", "update", "poll", "poll_slice",
		"levels", "is_ready", "is_busy", "window_center", "release"
	]:
		check(cm.has_method(m), "AirClipmap." + m)
	check(cm.has_signal("levels_changed") and cm.has_signal("failed"), "сигналы клипмапа")
	for mi: Dictionary in cm.get_method_list():
		if String(mi.name) in ["setup", "set_conditions"]:
			var names: Array = (mi.args as Array).map(func(x: Dictionary) -> String: return x.name)
			check(names.has("inflow_k"), "C7 v3: AirClipmap.%s(…, inflow_k)" % mi.name)
	var job := AirWindowJob.new()
	for m in ["window_state", "parent_data", "nest_corr", "state", "grid", "field_async"]:
		check(job.has_method(m), "AirWindowJob." + m)
	check("parent" in job and "prev" in job and "shared_gpu" in job, "поля AirWindowJob")
	var ac: Dictionary = Config.get_config("atmosphere").get("air_model", {})
	for key in ["window_levels_m", "window_shift_frac"]:
		check(ac.has(key) and ac.has(key + "_doc"), "air_model." + key)
	check(Array(ac.get("window_levels_m", [])) == [100.0, 50.0], "окна 100 и 50 м")


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


# ------------------------------------------------------------------ C9


class StubAtmo:
	extends RefCounted
	var fields: Array = []

	func set_air_field(f: Variant, blend_s: float = -1.0) -> void:
		fields.append([f, blend_s])


## C9 v1: форма AirRuntime; без RD (headless) — аналитика сигналом, не падение; правило сроков.
func test_c9_runtime_shape() -> void:
	var rt := AirRuntime.new()
	for sg in ["field_applied", "fallback", "progress_changed"]:
		check(rt.has_signal(sg), "сигнал " + sg)
	for m in [
		"setup", "load_field", "request_recompute", "stop", "busy", "unavailable_reason",
		"current_conditions", "needs_recompute", "place_of", "conditions_of", "set_focus"
	]:
		check(rt.has_method(m), "метод " + m)
	check("recompute_enabled" in rt and "last_error" in rt, "recompute_enabled, last_error")
	check("focus_fn" in rt and "shift_count" in rt, "C9 v2: focus_fn, shift_count")
	check("inflow_k" in rt, "C9 v3: inflow_k")
	var rt_src := FileAccess.get_file_as_string(JOB_DIR + "air_runtime.gd")
	for k in ["u_start10_first", "u_start10", "passes"]:
		check(k in rt_src, "C9 v3: last_info." + k)
	var tree := Engine.get_main_loop() as SceneTree
	await tree.process_frame
	tree.root.add_child(rt)
	var atmo := StubAtmo.new()
	var c := {hour = 12.0, u10 = 3.0, wdir = 150.0, t_max = NAN, sky = "clear"}
	var cond := func() -> Dictionary: return c
	rt.setup(atmo, {detail = null, water = null, loc = {}}, cond)
	var reasons: Array[String] = []
	rt.fallback.connect(reasons.append)
	var ok: bool = await rt.load_field()
	check(not ok, "без RD/места поля нет")
	check(reasons.size() == 1 and rt.last_error != "", "fallback с причиной: %s" % [reasons])
	check(not rt.busy() and atmo.fields.is_empty(), "не считает, атмосферу не трогает")
	rt.recompute_enabled = true
	rt.request_recompute("тест")
	await tree.process_frame
	check(not rt.busy(), "пересчёт без RD не начинается")
	rt.queue_free()
	# сроки и условия
	var nr := AirRuntime.needs_recompute
	check(nr.call({}, c, 15.0) != "", "нет поля — считать")
	check(nr.call(c, c, 15.0) == "", "те же условия — не считать")
	var d := c.duplicate()
	d.hour = 12.24
	check(nr.call(c, d, 15.0) == "", "12:14 — тот же срок")
	d.hour = 12.25
	check(String(nr.call(c, d, 15.0)).begins_with("срок"), "12:15 — новый срок")
	check(absf(AirRuntime.slot_hour(12.4, 15.0) - 12.25) < 1e-9, "начало срока 12:24 → 12:15")
	d = c.duplicate()
	d.wdir = 160.0
	check(nr.call(c, d, 15.0) == "смена ветра", "смена направления")
	d = c.duplicate()
	d.u10 = 4.0
	check(nr.call(c, d, 15.0) == "смена ветра", "смена скорости")
	d = c.duplicate()
	d.sky = "overcast"
	check(nr.call(c, d, 15.0) == "смена погоды", "смена неба")
