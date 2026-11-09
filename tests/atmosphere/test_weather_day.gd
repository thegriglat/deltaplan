extends TestCase
## Погода из прогноза в атмосфере (docs/archive/plan/weather-by-temperature.md) через фасад W2 v4:
## ветер прогноза — на старте и растёт с высотой над стартом (пилот, 28.09.2026). Воздух — прогноз
## в set_conditions (tests/atmosphere/air_rig.gd, ключ cond), рельеф плоский на 1000 м.
## Ход дня (мягкое обновление погоды без пересоздания термиков) и профиль ветра по устойчивости
## (WindProfile по часу) — слагаемое крейта (RW-12s: проверки через set_weather и WindModel
## удалены): rust/dp-air/tests/weather_day.rs (soft_blend_follows_update_weather, blend_steps_compose_exactly,
## day_keeps_wind_and_spacing_and_bumps_version_per_step, wind_conditions_follow_hour, day_state_follows_apply_day),
## terms_thermal_field.rs (rebuild_by_key_keeps_live_thermals), terms_analytic.rs (профиль ветра).

const Rig := preload("res://tests/atmosphere/air_rig.gd")


static func _flat(_x: float, _z: float) -> float:
	return 1000.0


## Прогноз: ветер kmh с запада, 14:00; wind_ref — опорная высота ветра (null — без неё).
func _cond(kmh: float, ref_msl: Variant, gain: float = 0.6) -> Dictionary:
	var wind_ref: Variant = null
	if ref_msl != null:
		wind_ref = {"ref_msl": float(ref_msl), "gain_per_km": gain}
	return {
		"forecast":
		{"temperature_c": 26.0, "wind_speed_kmh": kmh, "wind_from_deg": 270.0, "sky": "clear"},
		"start_hour": 14.0,
		"speed": 1.0,
		"wind_ref": wind_ref,
	}


func _rig(ref_msl: Variant, gain: float = 0.6) -> Atmosphere:
	return Rig.make({"cond": _cond(18.0, ref_msl, gain), "ground": _flat, "mode": 1, "advance": 0.01})


## Фоновый ветер Terms на высоте y (MSL): |background_wind| — аналитика без поля Пикара. mean_wind_at в сумме
## берёт поле (оно считается по U10 прогноза и опорной высоты не знает), поэтому рост по опоре — здесь.
func _bg(a: Atmosphere, y: float) -> float:
	var w := a.background_wind(PackedFloat32Array([y]))
	return Vector2(w[0], w[1]).length()


func test_wind_grows_above_launch() -> void:
	# Профиль W5 v8: ветер растёт с высотой над опорной по gain_per_km (в игре — climate_place крейта, запасной
	# 0,6/км): ×(1 + gain·км). Опора ветра прогноза с WF-К1 v3 — отметка открытой местности места (игра wind_ref
	# не кладёт); явный wind_ref (здесь) её переопределяет. Точный множитель — rust/dp-air/tests/terms_frame.rs
	# (altitude_factor); здесь — потребитель: фасад передаёт опору, фон на ней = ветер прогноза.
	var wc: Dictionary = Config.get_config("atmosphere").wind
	var a := _rig(1000.0)  # 5 м/с на опоре (1000 м)
	var at_launch := _bg(a, 1000.0 + float(wc.reference_height_m))
	check(absf(at_launch - 5.0) < 0.25, "на опоре — ветер прогноза (±5 %%): %.2f" % at_launch)
	var above := _bg(a, 2000.0)
	# профиль над землёй (стабильность, z_sat) без роста по высоте: gain 0
	var g0 := _rig(1000.0, 0.0)
	var prof := _bg(g0, 2000.0) / _bg(g0, 1000.0 + float(wc.reference_height_m))
	g0.free()
	var k := above / at_launch / prof
	check(k > 1.55 and k < 1.65, "на 1 км выше опоры ×%.2f сверх профиля (gain 0,6/км: ×1,6): %.1f м/с" % [k, above])
	a.free()
	var b := _rig(1600.0)  # опора выше - на 1010 м ветер слабее
	check(_bg(b, 1010.0) < 5.0, "ниже опоры ветер слабее")
	b.free()
	var c := _rig(null)  # без явной опоры - отметка долины места (здесь та же 1000 м), рост по климату места
	var gain := float(c.weather()._derived.gain_per_km)
	var kc := _bg(c, 2000.0) / at_launch / prof
	var want := minf(1.0 + gain, float(wc.altitude_max_factor))
	check(absf(kc - want) < 0.05, "без явной опоры - от долины, рост по климату: ×%.2f (ждём ×%.2f)" % [kc, want])
	c.free()