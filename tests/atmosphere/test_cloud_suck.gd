extends TestCase
## Облачный подсос (FR-14b) через фасад W2 v4: под крупным живым облаком подъём у основания сильнее;
## cloud_density_at; болтанка в облаке. Облако — естественное кучевое поля (Rig.cloud_day): заданное
## вручную (стадия, покрытие, мощность — прежний Fixture.force_cloud) крейт не принимает.
## Подсос по стадии облака (молодое/тающее), бурление и выброс к краю в облаке — крейт (RW-12s:
## проверки через cloud_phys/CloudField удалены): rust/dp-air/tests/terms_clouds.rs
## (physics_suck_vs_gd,
## hooks_shade_and_suck), terms_thermal_cloud.rs (suck_points_from_gd_in_tolerance).

const Rig := preload("res://tests/atmosphere/air_rig.gd")


func test_suck_under_mature_cloud() -> void:
	var a := Rig.cloud_day()
	var cb := a.cloudbase_msl()
	var mid := a.mean_wind_at(Vector3(0, cb * 0.5, 0)).y
	var base := a.mean_wind_at(Vector3(0, cb - 40.0, 0)).y
	check(base > mid * 1.2, "у основания крупного облака подъём сильнее: %.2f > %.2f" % [base, mid])
	a.free()


func test_cloud_density_at() -> void:
	var a := Rig.cloud_day()
	var cb := a.cloudbase_msl()
	check(a.cloud_density_at(Vector3(0, cb + 150.0, 0)) > 0.3, "в облаке плотность > 0")
	approx(a.cloud_density_at(Vector3(0, cb - 100.0, 0)), 0.0, 1e-6, "под облаком ясно")
	approx(a.cloud_density_at(Vector3(4500, cb + 150.0, 0)), 0.0, 1e-6, "в стороне ясно")
	# Дёшево: 10 000 вызовов.
	var t0 := Time.get_ticks_usec()
	for i in 10000:
		a.cloud_density_at(Vector3(i * 0.3, cb + 150.0, 0))
	var us := float(Time.get_ticks_usec() - t0) / 10000.0
	check(us < 20.0, "cloud_density_at дёшево: %.2f мкс" % us)
	a.free()


func test_turbulence_stronger_in_cloud() -> void:
	var a := Rig.cloud_day()
	var cb := a.cloudbase_msl()
	var s_in := 0.0
	var s_out := 0.0
	for i in 300:
		var p := Vector3(-300.0 + i * 2.0, cb + 150.0, 40.0)
		var q := Vector3(-300.0 + i * 2.0, cb - 350.0, 40.0)
		s_in += (a.air_velocity_at(p) - a.mean_wind_at(p)).length_squared()
		s_out += (a.air_velocity_at(q) - a.mean_wind_at(q)).length_squared()
	check(s_in > s_out * 1.2, "в облаке болтает сильнее: %.1f > %.1f" % [s_in / 300, s_out / 300])
	a.free()
