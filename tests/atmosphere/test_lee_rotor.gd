extends TestCase
## Подветренная зона за гребнем.
## 1. Аналитика (без поля воздуха; путь main и запасной): опускание, болтанка ротора, обратный поток
##    у склона, рывки вниз — коэффициенты эвристики lee.* (не из физики). Пороги проверок ниже —
##    регрессия аналитики, не физическое ожидание: аналитика завышает опускание и рывки против
##    слоя смешения (σ_w ≈ 0,14·ΔU, Bell & Mehta 1990) — известное ограничение (docs/guide/air-model.md →
##    «Чего не умеет»).
## 2. С полем воздуха (C4 v4, AM-08в: w = w поля без болтанки, рывки σ_w ≈ 0,14·ΔU, обратный поток
##    эвристики 0,22·U_H только при грубой сетке) — слагаемое крейта, проверки через air_field /
##    field_turb / ground удалены (RW-12s): rust/dp-air/tests/terms_turb.rs
##    (separation_zone_bursts_sigma_and_reverse_flow, slot_in_sum_on_island_field,
##    ongudai_replay_matches_air_velocity_field), terms_analytic.rs (подветренный поток).
## Хребет вдоль Z высотой 300 м, гребень на x = 0, ветер с запада (дует на +X).

const Sim := preload("res://tests/flight/flight_sim.gd")
const Rig := preload("res://tests/atmosphere/air_rig.gd")
const RIDGE_H := 300.0
const RIDGE_W := 400.0
## Пятно в тени гребня: расстояние за гребнем, м, и высота над землёй, м.
const LEE_X: Array[float] = [150.0, 200.0, 250.0, 300.0, 350.0]
const LEE_AGL: Array[float] = [20.0, 40.0, 60.0, 80.0]
const WIND_X := -300.0


static func _ridge(x: float, _z: float) -> float:
	return RIDGE_H * exp(-(x / RIDGE_W) * (x / RIDGE_W))


func _atmo(wind_ms: float) -> Atmosphere:
	var over := {
		"wind_speed_kmh": Units.to_kmh(wind_ms) if wind_ms > 0.0 else 0.0,
		"wind_from_deg": 270.0,
		"background_sink_ms": 0.0,
		"convective_turbulence_ms": 0.0,
	}
	return Rig.make(
		{"over": over, "mode": 1, "ground": _ridge, "half": 3000.0, "advance": 0.01}
	)


## Числа lee взяты из AP-10 (tools/research/air_phase/analysis/AP-10): угол 12°, ротор 0,6–0,7,
## высота ротора 0,6, слой сдвига 300–400 м, опускание 0,05–0,1.
func test_lee_config_from_ap10() -> void:
	var l: Dictionary = Config.get_config("atmosphere").lee
	check(float(l.shadow_angle_deg) == 12.0, "угол тени 12°")
	check(float(l.rotor_reverse) >= 0.6 and float(l.rotor_reverse) <= 0.7, "rotor_reverse 0,6–0,7")
	check(absf(float(l.rotor_height_fraction) - 0.6) < 1e-6, "rotor_height_fraction 0,6")
	check(float(l.shear_layer_m) >= 300.0 and float(l.shear_layer_m) <= 400.0, "слой сдвига")
	check(float(l.danger_sink_per_wind) >= 0.05 and float(l.danger_sink_per_wind) <= 0.1, "опускание")


# test_rotor_weakens_with_heating (ротор слабеет с нагревом земли: lee_heat_wm2, _conv_amp) —
# rust/dp-air/tests/terms_turb.rs (sigma_lee_sep_scales_match_godot, separation_zone_bursts_sigma_and_reverse_flow).


# test_lee_sink_and_rotor_scale_with_wind (опускание и ротор растут с ветром, наветренный склон) и
# test_rotor_reverse_flow_near_slope (обратный поток у склона) — rust/dp-air/tests/gd_atmosphere_ported.rs
# (lee_sink_and_rotor_scale_with_wind, rotor_reverse_flow_near_slope): слагаемые analytic + ridge без
# поля, пороги прежние; u — ветер профиля, как `mean_wind_at` эталона GD. В фасаде при поле «всегда»
# поле Пикара (шаг 400 м) склон 300 м не разрешает, и эти числа меряют сумму с полем, а не эвристику.


func test_same_seed_same_air() -> void:
	var a := _atmo(6.0)
	var b := _atmo(6.0)
	var p := Vector3(220.0, _ridge(220.0, 0.0) + 40.0, 55.0)
	a.advance_to(12.3)
	b.advance_to(12.3)
	check(a.air_velocity_at(p).is_equal_approx(b.air_velocity_at(p)), "детерминизм")
	a.free()
	b.free()


## Полёт на триммере через гребень на 50 м выше него: за гребнем высота теряется намного быстрее,
## чем в штиль (последствие, без подсказок).
func _fly_over_crest(wind_ms: float) -> float:
	var a := _atmo(wind_ms)
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
		Rig.step(a, dt)
		m.step(dt, inp, air, gnd)
		guard += 1
	var y0 := m.position.y
	for i in int(30.0 / dt):
		if m.mode != FlightModel.Mode.AIR:
			break
		Rig.step(a, dt)
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
