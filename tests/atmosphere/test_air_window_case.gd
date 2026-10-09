extends TestCase
## Вход окна клипмапа (AirWindowCase, AM-04) против эталона AM-01 (window_gpu_refs.py →
## fixtures/air_model/window/): рельеф окна, dθ̄/dz, сетка; зона релаксации. Поток тепла — не по
## эталону (C2 v8): H клетки окна = SurfaceHeat.mix_flux по её долям (TestAirPlace.expected_heat). Без GPU.

const FIX_W := "res://tests/atmosphere/fixtures/air_model/window/"


func test_window_input_vs_reference() -> void:
	var lw := TestAirPlace.load_detail("ongudai")
	check(lw.size() == 2 and lw[0] != null, "слой detail Онгудая")
	if lw.size() != 2:
		return
	var loc := TestAirPlace.load_loc("ongudai")
	var ctx := AirPlace.context(lw[0], loc, WeatherModel.config())
	for name in ["ongudai_w100_h12", "ongudai_w50_h12"]:
		var m := TestAirPicard.load_fix(FIX_W + name)
		var dx := float(m.dx)
		var half := 0.5 * AirWindowCase.N_WINDOW * dx
		var t0 := Time.get_ticks_usec()
		var c := AirWindowCase.window_case(
			lw[0],
			lw[1],
			loc,
			dx,
			float(m.x0) + half,
			float(m.y0) + half,
			12.0,
			3.0,
			150.0,
			NAN,
			"clear",
			true,
			ctx
		)
		var t1 := Time.get_ticks_usec()
		check(c != null, "окно построено")
		if c == null:
			return
		check(c.prepare_pair(), "подготовка пары")
		var t2 := Time.get_ticks_usec()
		check(
			c.x0 == float(m.x0) and c.y0 == float(m.y0) and c.nz == int(m.nz),
			"сетка как в эталоне (угол, nz)"
		)
		check(c.z_bot == float(m.z_bot) and c.dz == float(m.dz), "z_bot, dz как в эталоне")
		var dat: Dictionary = m.data
		var e_h := TestAirPlace._max_diff(c.hc, dat.hc)
		var e_q := TestAirPlace._max_diff_64(
			c.heat, TestAirPlace.expected_heat(c, lw[0], lw[1], loc, 12.0, 3.0, NAN, null, ctx)
		)
		var e_g := TestAirPlace._max_diff(c.gam, dat.gam)
		print(
			(
				(
					"  %s: вход %.0f мс, подготовка пары %.0f мс; max|Δhc| %s м, max|ΔH − mix_flux| %s Вт/м², "
					+ "max|Δγ| %s К/м"
				)
				% [
					name,
					(t1 - t0) / 1000.0,
					(t2 - t1) / 1000.0,
					TestAirPicard.sci(e_h),
					TestAirPicard.sci(e_q),
					TestAirPicard.sci(e_g)
				]
			)
		)
		check(e_h < 1e-3, "рельеф окна")
		check(e_q < 1e-9, "H окна = SurfaceHeat.mix_flux по долям клетки")
		check(e_g < 1e-7, "dθ̄/dz окна")
		# зона релаксации: 4 клетки у боков (для импульса и θ′), потолок 1000 м; фон setup не пишет
		var nyx := c.nx_h * c.ny_h
		var mid := (c.ny_h / 2) * c.nx_h
		var rate := float(c.p.sponge_rate)
		approx(c.col[6 * nyx + mid + 1], rate * pow(1.0 - 0.5 / 4.0, 2.0), 1e-9, "губка у края")
		approx(c.col[6 * nyx + mid + 5], 0.0, 1e-12, "за 4 клетками губки нет")
		check(c.col[7 * nyx + mid + 1] == c.col[6 * nyx + mid + 1], "θ′ — та же зона, все бока")
		check(c.prm[AirCase.P_NEST] == 1.0, "флаг окна в prm")
		check(c.without_heat() is AirWindowCase, "без нагрева — тоже окно")


## Сглаживание окна — то же, что прямая свёртка с отражением (σ больше окна).
func test_gauss_folded_equals_direct() -> void:
	var w := 13
	var h := 9
	var a := PackedFloat64Array()
	for q in w * h:
		a.append(sin(q * 0.7) + 0.01 * q)
	for sigma in [0.8, 3.0, 15.0]:
		var got := AirCase.gauss2d(a, w, h, sigma)
		var ref := _gauss_direct(a, w, h, sigma)
		var e := 0.0
		for q in a.size():
			e = maxf(e, absf(got[q] - ref[q]))
		check(e < 1e-12, "σ = %s: max|Δ| %s" % [sigma, e])


static func _gauss_direct(
	a: PackedFloat64Array, w: int, h: int, sigma: float
) -> PackedFloat64Array:
	var r := ceili(3.0 * sigma)
	var ker := PackedFloat64Array()
	var ks := 0.0
	for q in range(-r, r + 1):
		ker.append(exp(-0.5 * pow(q / sigma, 2.0)))
		ks += ker[-1]
	var tmp := PackedFloat64Array()
	tmp.resize(w * h)
	for j in h:
		for i in w:
			var s := 0.0
			for q in range(-r, r + 1):
				s += ker[q + r] / ks * a[j * w + AirCase._reflect(i + q, w)]
			tmp[j * w + i] = s
	var out := PackedFloat64Array()
	out.resize(w * h)
	for j in h:
		for i in w:
			var s := 0.0
			for q in range(-r, r + 1):
				s += ker[q + r] / ks * tmp[AirCase._reflect(j + q, h) * w + i]
			out[j * w + i] = s
	return out
