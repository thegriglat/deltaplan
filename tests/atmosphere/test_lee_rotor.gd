extends TestCase
## Подветренная зона за гребнем — смертельно опасна в умеренный и сильный ветер (пилот: «за
## гребнем ротор сразу бьёт сверху, туда нельзя»): сильное опускание, болтанка ротора, обратный
## поток у склона, рывки вниз. В слабый ветер — мягко. Наветренная сторона — прежняя.
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
			check(lee.x <= -0.5 * lee.y, "%.0f м/с: сильное опускание %.2f" % [wind, lee.x])
			check(lee.z >= 0.5 * lee.y, "%.0f м/с: ротор σ %.2f" % [wind, lee.z])
			check(ww.x > 0.3, "%.0f м/с: наветренный склон поднимает %.2f" % [wind, ww.x])
			check(ww.z < 0.35 * ww.y, "%.0f м/с: наветренный σ мал %.2f" % [wind, ww.z])
		else:
			check(lee.x >= -1.0, "слабый ветер: опускание мягкое %.2f" % lee.x)
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
