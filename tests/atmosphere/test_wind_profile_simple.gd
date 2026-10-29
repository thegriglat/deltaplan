extends TestCase
## Упрощённый ветер (режим поля off): профиль по высоте — как в 0.8.0 (α = 0,14, предел ×1,8,
## опорная высота 10 м), без зависимости от часа и облачности — через фасад W2 v4 (прогноз в
## set_conditions, set_air_mode("off"), отношение горизонтальной скорости на высоте к скорости на
## 10 м). Переключение auto/off в рабочем режиме и параметры профиля WindProfile (с полем) —
## крейт (RW-12s): rust/dp-air/tests/terms_analytic.rs (simple_profile_matches_080_any_hour_and_sky,
## off_mode_case_equals_medium_and_uses_simple_profile).

const Rig := preload("res://tests/atmosphere/air_rig.gd")
const HEIGHTS := [10.0, 50.0, 100.0, 300.0, 1000.0]
const GROUND := 1000.0


static func _flat(_x: float, _z: float) -> float:
	return GROUND


static func _v080(agl: float) -> float:
	return minf(pow(maxf(agl, 1.0) / 10.0, 0.14), 1.8)


static func _horiz(a: Atmosphere, agl: float) -> float:
	var v := a.mean_wind_at(Vector3(0.0, GROUND + agl, 0.0))
	return Vector2(v.x, v.z).length()


func test_off_matches_080_any_hour() -> void:
	for hour in [9.0, 12.0, 15.0, 20.0]:
		for sky in ["clear", "overcast"]:
			var a := Rig.make(
				{
					"cond":
					{
						"forecast":
						{
							"temperature_c": 26.0,
							"wind_speed_kmh": 10.8,
							"wind_from_deg": 270.0,
							"sky": sky
						},
						"start_hour": hour,
					},
					"air_mode": "off",
					"ground": _flat,
					"mode": 1,
					"advance": 0.01,
				}
			)
			var v10 := _horiz(a, 10.0)
			approx(v10, 3.0, 0.02, "off %s ч %s: 3 м/с на 10 м" % [hour, sky])
			for h in HEIGHTS:
				approx(_horiz(a, h) / v10, _v080(h), 2.0e-3, "off %s ч %s: ×(%s м)" % [hour, sky, h])
			a.free()
	approx(_v080(1000.0), 1.8, 1.0e-9, "предел 0.8.0 достигнут на 1000 м")
