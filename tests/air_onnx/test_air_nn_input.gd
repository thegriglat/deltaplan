class_name TestAirNnInput
extends TestCase
## N3 (O4): строка входа сети из игры (AirPlace.domain_case + погода) = строка Python (real.case +
## Day.summary(), как airlite_gen.solve_case до решения); эталон — fixtures/input_cases.json
## (tools/air_onnx/make_input_fixture.py). Страж области применимости. Без GPU.

const FIX := "res://tests/air_onnx/fixtures/input_cases.json"


func _rel(a: float, b: float, tol: float, msg: String) -> void:
	if absf(a - b) > tol * maxf(1.0, absf(b)):
		failures.append("%s: игра %.6g, Python %.6g (допуск %s отн.)" % [msg, a, b, str(tol)])


func test_row_matches_python() -> void:
	var fx: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(FIX))
	check(fx.has("cases"), "фикстура прочитана")
	var layers := {}
	for c: Dictionary in fx.cases:
		var loc_id := String(c.loc)
		if not layers.has(loc_id):
			layers[loc_id] = TestAirPlace.load_detail(loc_id)
		var lw: Array = layers[loc_id]
		if lw.size() != 2:
			failures.append("слой detail %s не загружен" % loc_id)
			continue
		var loc := TestAirPlace.load_loc(loc_id)
		var case := AirPlace.domain_case(
			lw[0], lw[1], loc, float(c.dx), float(c.hour), float(c.U10), float(c.wdir),
			float(c.t_max), String(c.sky)
		)
		var cond := AirNnInput.cond_for(lw[0], loc, float(c.hour), float(c.t_max), String(c.sky))
		var row := AirNnInput.row_from_case(case, cond)
		var id := String(c.id)
		for k: String in ["U10", "wdir", "t_max", "hour"]:
			_rel(float(row[k]), float(c[k]), 1e-3, "%s %s" % [id, k])
		check(String(row.sky) == String(c.sky), "%s sky" % id)
		var pr: Dictionary = row.profile
		for k: String in ["alpha", "max_profile", "sun_el", "sun_az"]:
			_rel(float(pr[k]), float(c.profile[k]), 1e-3, "%s profile.%s" % [id, k])
		check(String(pr.stab) == String(c.profile.stab), "%s stab %s / %s" % [id, pr.stab, c.profile.stab])
		var day: Dictionary = row.day
		for k: String in ["z_i_msl", "z_lcl_msl", "heat", "brk", "t", "cap_agl"]:
			var ref: Variant = c.day[k]
			if ref == null:
				check(not day.has(k), "%s day.%s: у Python нет, у игры %s" % [id, k, day.get(k)])
			elif not day.has(k):
				failures.append("%s day.%s: у игры нет, у Python %s" % [id, k, ref])
			else:
				_rel(float(day[k]), float(ref), 1e-3, "%s day.%s" % [id, k])
		var hc: PackedFloat64Array = row.hc
		var heat: PackedFloat64Array = row.heat
		check(hc.size() == int(c.nx) * int(c.ny) and heat.size() == hc.size(), "%s размер карт" % id)
		var e_h := 0.0
		var e_q := 0.0
		for q in mini(hc.size(), (c.hc as Array).size()):
			e_h = maxf(e_h, absf(hc[q] - float(c.hc[q])))
			e_q = maxf(e_q, absf(heat[q] - float(c.heat[q])))
		print("  %s: max|Δhc| %.3f м, max|Δheat| %.3f Вт/м²" % [id, e_h, e_q])
		check(e_h <= 0.5, "%s hc: %.3f м" % [id, e_h])
		check(e_q <= 1.0, "%s heat: %.3f Вт/м²" % [id, e_q])


## C2 v6: с множителем притока U10 строки = k·меню, а α/max_profile/класс — по меню (то же, что k = 1).
func test_row_inflow_scale() -> void:
	var lw := TestAirPlace.load_detail("ongudai")
	if lw.size() != 2:
		failures.append("слой detail не загружен")
		return
	var loc := TestAirPlace.load_loc("ongudai")
	var cond := AirNnInput.cond_for(lw[0], loc, 12.0, 26.0, "clear")
	var r1 := AirNnInput.row_from_case(
		AirPlace.domain_case(lw[0], lw[1], loc, 400.0, 12.0, 3.0, 150.0, 26.0), cond
	)
	var rk := AirNnInput.row_from_case(
		AirPlace.domain_case(lw[0], lw[1], loc, 400.0, 12.0, 3.0, 150.0, 26.0, "clear", true, 1.4),
		cond
	)
	approx(float(rk.U10), 4.2, 1e-9, "U10 = k·меню")
	approx(float(rk.profile.alpha), float(r1.profile.alpha), 1e-12, "α по меню")
	approx(float(rk.profile.max_profile), float(r1.profile.max_profile), 1e-12, "max_profile по меню")
	check(rk.profile.stab == r1.profile.stab, "класс по меню")


func test_guard() -> void:
	var dom := AirNnInput.default_domain()
	check(dom.U10[1] == 8.0 and dom.hour[0] == 9.0 and dom.t_max[0] == 18.0, "область набора пилота")
	var row := {U10 = 12.0, hour = 22.0, t_max = 10.0, wdir = 100.0, sky = "clear", hc = PackedFloat64Array([1.0])}
	var g := AirNnInput.guard(row, dom)
	check(g.clamped == ["U10 12.0→8.0", "hour 22.0→20.0", "t_max 10.0→18.0"], "список зажатого: %s" % [g.clamped])
	approx(float(g.row.U10), 8.0, 1e-12, "U10 зажат")
	approx(float(g.row.hour), 20.0, 1e-12, "hour зажат")
	approx(float(g.row.t_max), 18.0, 1e-12, "t_max зажат")
	approx(float(g.row.wdir), 100.0, 1e-12, "wdir не тронут")
	approx(float(row.U10), 12.0, 1e-12, "исходная строка не изменена")
	check(g.row.hc.size() == 1, "карты на месте")
	var ok := AirNnInput.guard({U10 = 3.0, hour = 12.0, t_max = 26.0}, dom)
	check((ok.clamped as Array).is_empty() and float(ok.row.U10) == 3.0, "внутри области — без зажатия")
	var low := AirNnInput.guard({U10 = -1.0, hour = 9.0, t_max = 34.0}, dom)
	check(low.clamped == ["U10 -1.0→0.0"], "нижний край: %s" % [low.clamped])
