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
	return Rig.cloud_day(1, true)


func test_field_cloud_seen_by_physics() -> void:
	var a := _atmo()
	var cb := a.cloudbase_msl()
	check(cb > 0.0, "кромка облаков есть: %.0f" % cb)
	# Высоту пика не фиксируем: у шаблона пузыря (thermal-bubble) облако над ядром растёт плавнее,
	# чем у профиля Гедеона (на cb+150 — 0,075 против 0,126, но на cb+300…1000 ровно 0,12 — пик тот же);
	# свойство «в облаке плотность из поля > 0,1» проверяем по столбу над ядром.
	var dmax := 0.0
	for dz: float in [50.0, 100.0, 150.0, 300.0, 600.0]:
		dmax = maxf(dmax, a.cloud_density_at(Vector3(0, cb + dz, 0)))
	check(dmax > 0.1, "плотность в облаке из поля: max по столбу %.3f" % dmax)
	approx(a.cloud_density_at(Vector3(0, cb - 100.0, 0)), 0.0, 1e-6, "под основанием ясно")
	# «вдали ясно» (15 км) — не свойство поля: оно покрывает всю область и даёт облака и вдали от термиков
	# (0,08 на 15 км); плотность поля против эталона GD — rust/dp-air/tests/terms_clouds.rs
	# (physics_sample_density_visible_vs_gd)
	check(not a.clouds(Vector3.ZERO, 6000.0).is_empty(), "облака у фокуса есть (clouds)")
	a.free()


func test_bots_see_field_clouds() -> void:
	var a := _atmo()
	var clouds: Array = BotPilots._visible_clouds(a)
	check(not clouds.is_empty(), "боты видят облака поля")
	for c: Dictionary in clouds:
		check(float(c.radius) > 0.0 and c.center is Vector2, "облако: центр и радиус")
	a.free()
