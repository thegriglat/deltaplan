extends TestCase
## Облака с первого кадра полёта (CLF-12) через фасад W2 v4: после старта в t = 13 ч
## (Atmosphere.start_at, как Game.set_world_time) поле облачности разогнано и отдаётся растром
## (cloud_raster) за <= 2 с реального времени — недетерминированный режим, как в игре с экраном
## (рабочие потоки крейта), готовое принимается покадровым pump. Печатает cloud_ready_after_s.
## Поток поля против синхронного и метка версии GD (mark_field_changed) — крейт (RW-12s):
## rust/dp-air/tests/terms_clouds.rs (timing_step_and_spinup,
## start_at_deterministic_and_close_to_run_from_zero),
## runtime.rs (nondeterministic_advance_does_not_wait_for_the_background).

const Rig := preload("res://tests/atmosphere/air_rig.gd")
const T_START := 13.0 * 3600.0


func _atmo() -> Atmosphere:
	return Rig.make(
		{
			"preset": "weather/strong",
			"over": {"wind_speed_kmh": 0.0},
			"statics": [[0.0, 0.0, 4.0, 130.0], [1500.0, 800.0, 3.5, 120.0]],
			"deterministic": false,  # как в игре с экраном
			"advance": 0.0,
		}
	)


func test_cloud_ready_after_start() -> void:
	var a := _atmo()
	var step_s := float(Config.get_config("atmosphere").cloud_field.step_s)
	var v0 := a.cloud_raster_version()
	var t0 := Time.get_ticks_usec()
	a.start_at(T_START)
	var ready := -1.0
	# кадры по 16 мс: покадровый pump + опрос растра, как у CloudLayer
	for k in 1500:
		a.pump(4000)
		if a.is_ready() and a.cloud_raster_version() > 0:
			var r := a.cloud_raster()
			if float(r.get("time_s", -1.0)) >= T_START - step_s:
				ready = float(Time.get_ticks_usec() - t0) / 1.0e6
				break
		OS.delay_msec(16)
	print("cloud_ready_after_s=%.2f" % ready)
	check(ready >= 0.0 and ready <= 2.0, "поле готово ≤ 2 с после старта (%.2f)" % ready)
	check(a.cloud_raster_version() > v0, "версия данных поля выросла")
	a.free()
