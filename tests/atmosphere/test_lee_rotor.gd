extends TestCase
## Подветренная зона за гребнем.
## 1. Аналитика (без поля воздуха; путь main и запасной): опускание, болтанка ротора, обратный поток
##    у склона, рывки вниз — коэффициенты эвристики lee.* (не из физики). Пороги проверок ниже —
##    регрессия аналитики, не физическое ожидание: аналитика завышает опускание и рывки против
##    слоя смешения (σ_w ≈ 0,14·ΔU, Bell & Mehta 1990) — известное ограничение (docs/guide/air-model.md →
##    «Чего не умеет»).
## 2. С полем воздуха (C4 v4, AM-08в, test_field_*): в зоне отрыва без болтанки w = w поля; рывки —
##    часть болтанки слоя смешения (пики ≤ 0,42·ΔU, σ_w ≈ 0,14·ΔU); обратный поток эвристики
##    0,22·U_H (Menke 2019) — только при грубой сетке, при мелкой пузырь даёт поле.
## Хребет вдоль Z высотой 300 м, гребень на x = 0, ветер с запада (дует на +X).

const Sim := preload("res://tests/flight/flight_sim.gd")
const RIDGE_H := 300.0
const RIDGE_W := 400.0
## Пятно в тени гребня: расстояние за гребнем, м, и высота над землёй, м.
const LEE_X: Array[float] = [150.0, 200.0, 250.0, 300.0, 350.0]
const LEE_AGL: Array[float] = [20.0, 40.0, 60.0, 80.0]
const WIND_X := -300.0


static func _ridge(x: float, _z: float) -> float:
	return RIDGE_H * exp(-(x / RIDGE_W) * (x / RIDGE_W))


static func _sun(_x: float, _z: float) -> float:
	return 1.0


func _atmo(wind_ms: float) -> Atmosphere:
	var w: Dictionary = Config.get_config("weather/medium").duplicate(true)
	w.wind_speed_kmh = Units.to_kmh(wind_ms) if wind_ms > 0.0 else 0.0
	w.wind_from_deg = 270.0
	w.thermal_mode = "static"
	w.static_thermals = []
	w.background_sink_ms = 0.0
	w.convective_turbulence_ms = 0.0
	var a := Atmosphere.new()
	a.visuals_enabled = false
	a.configure(Config.get_config("atmosphere"), w)
	a.set_ground(_ridge, _sun)
	a.turbulence_enabled = false
	a.step(0.01)
	return a


## Среднее по пятну (вдоль гребня и по времени): Vector4(w, u, σ, горизонталь вдоль ветра).
func _patch(a: Atmosphere, xs: Array[float], agls: Array[float]) -> Vector4:
	var sw := 0.0
	var su := 0.0
	var ss := 0.0
	var sh := 0.0
	var n := 0
	for t in 5:
		a.time_s = 10.0 + t * 7.0
		for x in xs:
			for agl in agls:
				for k in 20:
					var p := Vector3(x, _ridge(x, 0.0) + agl, k * 37.0)
					var v := a.air_velocity_at(p)
					sw += v.y
					sh += v.x
					su += a.mean_wind_at(p).length()
					ss += a.turbulence_intensity_at(p)
					n += 1
	return Vector4(sw / n, su / n, ss / n, sh / n)


func test_lee_sink_and_rotor_scale_with_wind() -> void:
	for wind in [2.0, 5.0, 8.0]:
		var a := _atmo(wind)
		var lee := _patch(a, LEE_X, LEE_AGL)
		var ww := _patch(a, [WIND_X] as Array[float], LEE_AGL)
		print(
			(
				(
					"  ветер %.0f м/с: за гребнем w %.2f (%.2f·u), σ %.2f (%.2f·u), u %.2f; "
					+ "наветренный w %.2f σ %.2f"
				)
				% [wind, lee.x, lee.x / lee.y, lee.z, lee.z / lee.y, lee.y, ww.x, ww.z]
			)
		)
		if wind > 4.0:
			# аналитика: пороги — регрессия эвристики lee.* (не физика)
			# AP-10: опускание в полосе у линии тени 0,03–0,05 U, литература 0,06–0,17 U_H; сверху
			# рывки («бьёт сверху») — опасность за гребнем это ротор и болтанка, не провал
			check(lee.x < 0.0 and lee.x >= -0.35 * lee.y, "%.0f м/с: опускание %.2f" % [wind, lee.x])
			# порог — регрессия аналитики, без источника: 0,5·u → 0,45·u по факту 0,47·u при 8 м/с
			# (профиль притока откалиброван, Б2); эвристика не подгоняется
			check(lee.z >= 0.45 * lee.y, "%.0f м/с: ротор σ %.2f" % [wind, lee.z])
			check(ww.x > 0.3, "%.0f м/с: наветренный склон поднимает %.2f" % [wind, ww.x])
			check(ww.z < 0.35 * ww.y, "%.0f м/с: наветренный σ мал %.2f" % [wind, ww.z])
		else:
			check(lee.x >= -1.0, "слабый ветер: опускание мягкое %.2f" % lee.x)
		a.free()


## Числа lee взяты из AP-10 (tools/research/air_phase/analysis/AP-10): угол 12°, ротор 0,6–0,7,
## высота ротора 0,6, слой сдвига 300–400 м, опускание 0,05–0,1.
func test_lee_config_from_ap10() -> void:
	var l: Dictionary = Config.get_config("atmosphere").lee
	check(float(l.shadow_angle_deg) == 12.0, "угол тени 12°")
	check(float(l.rotor_reverse) >= 0.6 and float(l.rotor_reverse) <= 0.7, "rotor_reverse 0,6–0,7")
	check(absf(float(l.rotor_height_fraction) - 0.6) < 1e-6, "rotor_height_fraction 0,6")
	check(float(l.shear_layer_m) >= 300.0 and float(l.shear_layer_m) <= 400.0, "слой сдвига")
	check(float(l.danger_sink_per_wind) >= 0.05 and float(l.danger_sink_per_wind) <= 0.1, "опускание")


## Ротор слабеет с нагревом земли (AP-10: 100–250 Вт/м² убирает пузырь при крутизне 0,3, при
## 0,5 укорачивает с 9,3 до 4,3–5,4 h): конвективная болтанка погоды → H → множитель ротора.
func test_rotor_weakens_with_heating() -> void:
	var a := _atmo(8.0)
	var p := Vector3(250.0, _ridge(250.0, 0.0) + 8.0, 0.0)
	var h0 := a.air_velocity_at(p).x
	check(a.lee_heat_wm2() == 0.0, "без конвекции нагрева нет")
	var prev := h0
	for conv in [0.4, 0.8, 1.3, 1.5]:
		a._conv_amp = conv
		a._cloudbase_agl = 1700.0
		var heat := a.lee_heat_wm2()
		var h := a.air_velocity_at(p).x
		print("  σ конв. %.1f → H %.0f Вт/м², горизонталь у склона %.2f (без нагрева %.2f)" % [conv, heat, h, h0])
		check(h >= prev - 1e-6, "сильнее нагрев — слабее обратный поток (%.2f)" % h)
		prev = h
	a._conv_amp = 1.5
	a._cloudbase_agl = 1000.0
	check(a.lee_heat_wm2() >= 300.0, "H ≥ порога убирает ротор: %.0f" % a.lee_heat_wm2())
	check(a.air_velocity_at(p).x > 0.0, "ротор убран нагревом")
	a.free()


func test_rotor_reverse_flow_near_slope() -> void:
	var a := _atmo(8.0)
	var reversed := 0
	for x in LEE_X:
		for agl in [5.0, 10.0, 15.0]:
			var h := a.air_velocity_at(Vector3(x, _ridge(x, 0.0) + agl, 0.0)).x
			if h < 0.5:
				reversed += 1
	check(reversed >= 3, "у подветренного склона обратный/нулевой поток: %d клеток" % reversed)
	# Высоко над линией тени — воздух не тронут.
	var p := Vector3(250.0, 700.0, 0.0)
	approx(a.air_velocity_at(p).x, a.mean_wind_at(p).x, 0.01, "над тенью ветер прежний")
	a.free()


func test_same_seed_same_air() -> void:
	var a := _atmo(6.0)
	var b := _atmo(6.0)
	a.turbulence_enabled = true
	b.turbulence_enabled = true
	var p := Vector3(220.0, _ridge(220.0, 0.0) + 40.0, 55.0)
	a.time_s = 12.3
	b.time_s = 12.3
	check(a.air_velocity_at(p).is_equal_approx(b.air_velocity_at(p)), "детерминизм")
	a.free()
	b.free()


## Полёт на триммере через гребень на 50 м выше него: за гребнем высота теряется намного быстрее,
## чем в штиль (последствие, без подсказок).
func _fly_over_crest(wind_ms: float) -> float:
	var a := _atmo(wind_ms)
	a.turbulence_enabled = true
	var m := Sim.make("sport")
	var start := Vector3(-250.0, RIDGE_H + 50.0, 0.0)
	m.reset_in_air(start, 90.0, 0.0, a.mean_wind_at(start))
	var inp := Sim.input()
	var air := func(p: Vector3) -> Vector3: return a.air_velocity_at(p)
	var gnd := func(x: float, z: float) -> float: return _ridge(x, z)
	var dt := Sim.DT
	# До гребня.
	var guard := 0
	while m.position.x < 0.0 and guard < int(60.0 / dt):
		a.time_s += dt
		m.step(dt, inp, air, gnd)
		guard += 1
	var y0 := m.position.y
	for i in int(30.0 / dt):
		if m.mode != FlightModel.Mode.AIR:
			break
		a.time_s += dt
		m.step(dt, inp, air, gnd)
	var lost := y0 - m.position.y
	if m.mode != FlightModel.Mode.AIR:
		lost = maxf(lost, y0 - _ridge(m.position.x, 0.0)) + 100.0
	a.free()
	return lost


func test_flying_into_lee_loses_height() -> void:
	var calm := _fly_over_crest(0.0)
	var lee := _fly_over_crest(6.0)
	print("  за 30 с после гребня: штиль −%.0f м, ветер 6 м/с −%.0f м" % [calm, lee])
	check(lee >= 2.0 * calm, "за гребнем теряем ≥ 2× штиля: %.0f м vs %.0f м" % [lee, calm])


# ------------------------------------------------------------------ с полем воздуха (C4 v4)

## Высота верха следа за гребнем (абсолютная), м: ниже — медленный поток, выше — U_TOP.
const WAKE_TOP := 250.0
const U_TOP := 10.0
const U_WAKE := 1.0
## Точки в глубине зоны: за гребнем, м; над землёй, м; вдоль гребня, м.
const F_X: Array[float] = [200.0, 250.0, 300.0, 350.0]
## То же для грубой сетки 400 м: дальше от гребня — столбцы сетки у гребня (рельеф ~230 м) уже
## выше верха следа.
const F_X_COARSE: Array[float] = [600.0, 700.0, 800.0, 900.0]
const F_AGL: Array[float] = [15.0, 30.0, 45.0]


## Синтетическое поле над хребтом: рельеф сетки — хребет; за гребнем (x > 0) ниже WAKE_TOP — след
## U_WAKE и опускание −0,8 м/с (признак отрыва поля), выше — U_TOP; перед гребнем — U_TOP и подъём.
static func _ridge_field(dx: float, x0: float, nx: int, y_half: float) -> WindField:
	var dz := 25.0
	var ny := int(2.0 * y_half / dx)
	var nz := 48
	var g := {dx = dx, dz = dz, x0 = x0, y0 = -y_half, z_bot = 0.0, nx = nx, ny = ny, nz = nz}
	var n := nx * ny * nz
	var u := PackedFloat32Array()
	var zero := PackedFloat32Array()
	var w := PackedFloat32Array()
	for arr in [u, zero, w]:
		arr.resize(n)
	var hc := PackedFloat32Array()
	hc.resize(nx * ny)
	for j in ny:
		for i in nx:
			hc[j * nx + i] = _ridge(x0 + (i + 0.5) * dx, 0.0)
	for k in nz:
		var z := (k + 0.5) * dz
		for j in ny:
			for i in nx:
				var x := x0 + (i + 0.5) * dx
				var c := (k * ny + j) * nx + i
				var lee := x > 0.0
				u[c] = U_WAKE if lee and z < WAKE_TOP else U_TOP
				w[c] = -0.8 if lee else 0.3
	return WindField.from_arrays(g, u, zero, w, zero, zero, hc)


func _field_atmo(dx: float) -> Atmosphere:
	var a := _atmo(8.0)
	a.wave.enabled = false
	var f: WindField
	if dx < 100.0:
		f = _ridge_field(dx, -1000.0, int(2500.0 / dx), 500.0)
	else:
		f = _ridge_field(dx, -2400.0, 14, 2400.0)
	a.set_air_field(f, 0.0)
	return a


## Точки зоны отрыва поля: [позиция, w поля, ΔU, U_H, признак отрыва lee_f, превышение r].
func _zone(a: Atmosphere) -> Array:
	var out: Array = []
	var xs := F_X if a.air_field.levels[0].dx < 100.0 else F_X_COARSE
	for x in xs:
		for agl in F_AGL:
			for k in 5:
				var p := Vector3(x, _ridge(x, 0.0) + agl, -160.0 + k * 80.0)
				var gh := _ridge(x, 0.0)
				var fw := a.air_field.sample(p, gh)
				if fw.w < 0.999:
					continue
				var uf := Vector2(fw.x, fw.z).length()
				var lee_f := a.field_turb.lee(uf, agl, a.air_field.sample_turb(p, gh))
				if lee_f < 0.99:
					continue
				var r := a.ground.relief_at(p.x, p.z)
				var fh := a.air_field.sample(Vector3(p.x, gh + maxf(r, agl), p.z), gh)
				var u_h := Vector2(fh.x, fh.z).length()
				out.append([p, fw.y, maxf(u_h - uf, 0.0) * lee_f, u_h, lee_f, r, fw])
	return out


func test_field_no_turbulence_w_is_field() -> void:
	for dx in [25.0, 400.0]:
		var a := _field_atmo(dx)
		var zone := _zone(a)
		check(zone.size() >= 30, "dx %.0f: точек в зоне отрыва поля %d" % [dx, zone.size()])
		var worst := 0.0
		for t in 4:
			a.time_s = 10.0 + t * 13.0
			for z: Array in zone:
				worst = maxf(worst, absf(a.air_velocity_at(z[0]).y - float(z[1])))
		print("  dx %.0f м: без болтанки |w − w поля| ≤ %.4f м/с (%d точек)" % [dx, worst, zone.size()])
		check(worst <= 0.05, "dx %.0f: без болтанки w = w поля (%.4f)" % [dx, worst])
		a.free()


func test_field_bursts_and_sigma_w() -> void:
	var a := _field_atmo(25.0)
	a.turbulence_enabled = true
	var zone := _zone(a)
	var s2 := 0.0
	var peak := 0.0
	var peak_b := 0.0
	var n := 0
	var du_mean := 0.0
	var g_mean := a.field_turb.burst_mean(a.wind, a._lee_burst_k, a._lee_burst_thr, a._lee_burst_width)
	for t in 40:
		a.time_s = 5.0 + t * 9.7
		for z: Array in zone:
			var du := float(z[2])
			var p: Vector3 = z[0]
			var r := (a.air_velocity_at(p).y - float(z[1])) / du
			s2 += r * r
			peak = maxf(peak, absf(r))
			# рывок отдельно: амплитуда × (g − ḡ), опасность 1 при 8 м/с
			var gb := a._lee_burst_g(p, a.wind.speed_at_pos(p.y - _ridge(p.x, 0.0), p.y))
			peak_b = maxf(peak_b, absf(a.field_turb.burst_per_du * (gb - g_mean)))
			du_mean += du
			n += 1
	var sw := sqrt(s2 / n)
	print(
		(
			"  с болтанкой: ΔU ср. %.2f м/с, σ_w/ΔU %.3f, пик |w′|/ΔU %.2f, пик рывка/ΔU %.2f (%d)"
			% [du_mean / n, sw, peak, peak_b, n]
		)
	)
	check(du_mean / n > 5.0, "в зоне ΔU от ветра на уровне гребня: %.2f" % (du_mean / n))
	check(peak_b <= 0.45, "пики рывков ≤ 0,45·ΔU: %.2f" % peak_b)
	check(absf(sw - 0.14) <= 0.2 * 0.14, "σ_w ≈ 0,14·ΔU ±20 %%: %.3f" % sw)
	a.free()


func test_field_reverse_only_when_unresolved() -> void:
	for dx in [25.0, 400.0]:
		var a := _field_atmo(dx)
		var zone := _zone(a)
		var dev := 0.0
		var dev_rel := 0.0
		var mean_add := 0.0
		for z: Array in zone:
			var p: Vector3 = z[0]
			var fw: Vector4 = z[6]
			var add := a.air_velocity_at(p).x - fw.x
			mean_add += add
			if dx < 100.0:
				dev = maxf(dev, absf(add))
			else:
				var agl := p.y - _ridge(p.x, 0.0)
				var r := float(z[5])
				var core := exp(-agl / maxf(float(Config.get_config("atmosphere").lee.rotor_height_fraction) * r, 1.0))
				var want := -0.22 * float(z[3]) * float(z[4]) * core
				var unres := a.field_turb.reverse_unresolved(r, a.air_field.sample_dx(p, p.y - agl))
				check(unres > 0.99, "dx 400: пузырь (2,8·%.0f м) не разрешён" % r)
				dev_rel = maxf(dev_rel, absf(add - want) / maxf(absf(want), 1.0e-3))
		print(
			(
				"  dx %.0f м: обратная добавка эвристики ср. %.3f м/с; |откл.| %.4f, отн. %.4f"
				% [dx, mean_add / maxf(zone.size(), 1), dev, dev_rel]
			)
		)
		if dx < 100.0:
			check(dev < 0.01, "dx 25: пузырь разрешён — обратной добавки нет (%.5f)" % dev)
		else:
			check(mean_add < -0.3, "dx 400: обратный поток эвристики есть (%.3f)" % mean_add)
			check(dev_rel < 0.01, "dx 400: добавка = −0,22·U_H·lee·ядро (%.4f)" % dev_rel)
		a.free()
