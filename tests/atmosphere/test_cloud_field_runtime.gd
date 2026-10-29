extends TestCase
## Поле облачности в симуляции (CLF-3) через фасад W2 v4: облачность поля видна как плотность
## (cloud_density_at) и список облаков (clouds), боты видят облака. Воздух — tests/atmosphere/air_rig.gd.
## Рабочий поток поля, сравнение потока с синхронным шагом, время refresh на главном потоке и тень поля —
## слагаемое крейта (RW-12s: проверки через cloud_phys удалены): rust/dp-air/tests/terms_clouds.rs
## (timing_step_and_spinup, start_at_deterministic_and_close_to_run_from_zero, hooks_shade_and_suck,
## physics_sample_density_visible_vs_gd), runtime.rs (same_input_same_field_bitwise_at_2_4_20_threads,
## nondeterministic_advance_does_not_wait_for_the_background).

const Rig := preload("res://tests/atmosphere/air_rig.gd")


func _atmo() -> Atmosphere:
	return Rig.make(
		{
			"preset": "weather/strong",
			"over": {"wind_speed_kmh": 0.0},
			"statics": [[0.0, 0.0, 4.0, 130.0], [1500.0, 800.0, 3.5, 120.0]],
			"start_at": 3000.0,
			"advance": 1.0,
		}
	)


func test_field_cloud_seen_by_physics() -> void:
	var a := _atmo()
	var cb := a.cloudbase_msl()
	check(cb > 0.0, "кромка облаков есть: %.0f" % cb)
	check(a.cloud_density_at(Vector3(0, cb + 150.0, 0)) > 0.1, "плотность в облаке из поля")
	approx(a.cloud_density_at(Vector3(0, cb - 100.0, 0)), 0.0, 1e-6, "под основанием ясно")
	approx(a.cloud_density_at(Vector3(15000, cb + 150.0, 0)), 0.0, 0.05, "вдали ясно")
	check(not a.clouds(Vector3.ZERO, 6000.0).is_empty(), "облака у фокуса есть (clouds)")
	a.free()


func test_bots_see_field_clouds() -> void:
	var a := _atmo()
	var clouds: Array = BotPilots._visible_clouds(a)
	check(not clouds.is_empty(), "боты видят облака поля")
	for c: Dictionary in clouds:
		check(float(c.radius) > 0.0 and c.center is Vector2, "облако: центр и радиус")
	a.free()
