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


func _rig(ref_msl: Variant) -> Atmosphere:
	return Rig.make({"cond": _cond(18.0, ref_msl), "ground": _flat, "mode": 1, "advance": 0.01})


func test_wind_grows_above_launch() -> void:
	# Профиль W5 v8: ветер растёт с высотой над опорной по gain_per_km (в игре — climate_place крейта, запасной
	# 0,6/км): ×(1 + gain·км); прежняя оценка «до 15 м/с на 1 км выше старта» была у старого профиля по
	# устойчивости (WindProfile) и условиям без gain. Точный множитель — rust/dp-air/tests/terms_frame.rs
	# (altitude_factor); здесь — потребитель: в сумме с полем Пикара он сохраняется в пределах нескольких %.
	var wc: Dictionary = Config.get_config("atmosphere").wind
	var a := _rig(1000.0)  # 5 м/с на старте (1000 м)
	var at_launch := a.mean_wind_at(Vector3(0, 1000.0 + float(wc.reference_height_m), 0)).length()
	check(absf(at_launch - 5.0) < 0.25, "на старте — ветер прогноза (±5 %%): %.2f" % at_launch)
	var above := a.mean_wind_at(Vector3(0, 2000.0, 0)).length()
	var k := above / at_launch
	check(k > 1.45 and k < 1.7, "на 1 км выше старта ×%.2f (gain 0,6/км: ×1,6): %.1f м/с" % [k, above])
	a.free()
	var b := _rig(1600.0)  # старт выше — в долине (1000 м) слабее
	check(b.mean_wind_at(Vector3(0, 1010.0, 0)).length() < 5.0, "ниже старта ветер слабее")
	b.free()
	var c := _rig(null)  # без опорной высоты — профиль считается от земли (здесь та же 1000 м)
	var plain := c.mean_wind_at(Vector3(0, 2000.0, 0)).length()
	check(absf(plain - above) < 0.3, "без опоры над ровной землёй — как с опорой на земле (%.1f / %.1f)" % [plain, above])
	c.free()
