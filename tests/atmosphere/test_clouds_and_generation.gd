extends TestCase
## Облака-объекты (CloudModel: Cb, волновые), статичные термики, наклон ядра по ветру. Кучевые —
## поле (test_cloud_field_runtime.gd). Тень поля облачности, улицы, отрыв низа распадающегося
## термика, доля сильных и частота источников — слагаемые крейта (RW-12s: проверки через
## внутренности GD-слагаемого удалены, эквиваленты — в таблице отчёта RW-12s и в комментариях ниже).

const Rig := preload("res://tests/atmosphere/air_rig.gd")


func _thermal(strength: float) -> AtmoThermal:
	var th := AtmoThermal.new()
	th.id = 7
	th.src = Vector3(0, 0, 0)
	th.top = 1800.0
	th.strength = strength
	th.radius = 100.0
	th.t_birth = 0.0
	th.t_grow = 200.0
	th.t_mature = 600.0
	th.t_decay = 200.0
	th.has_cloud = true
	th.cloud_depth = 700.0
	th.drift_vel = Vector2(5, 0)
	th.lean = Vector2(1.0, 0.0)
	return th


func _model() -> CloudModel:
	var m := CloudModel.new()
	m.setup(Config.get_config("atmosphere").clouds)
	return m


func test_cloud_lifecycle_follows_thermal() -> void:
	var m := _model()
	var th := _thermal(3.0)
	check(m.stage(th, 10.0).x < 0.0, "в начале жизни термика облака ещё нет")
	var early := m.stage(th, 450.0)
	var late := m.stage(th, 600.0)
	check(early.x > 0.0 and late.x > early.x, "облако растёт: %.2f → %.2f" % [early.x, late.x])
	approx(early.y, 0.0, 1e-6, "растущее не распадается")
	var decaying := m.stage(th, 1050.0)
	check(decaying.y > 0.0, "после конца термика облако тает: %.2f" % decaying.y)
	check(decaying.z < 0.1, "активность (подсос) почти ноль у тающего: %.2f" % decaying.z)
	check(m.stage(th, 1.0e5).x < 0.0, "растаявшего облака нет")
	# Растущее ниже зрелого, распадающееся оседает.
	var h_grow := m.size(th, Vector3(0.3, 0, 1)).z
	var h_mature := m.size(th, Vector3(1, 0, 1)).z
	var h_decay := m.size(th, Vector3(1, 0.8, 0)).z
	check(h_grow < h_mature and h_decay < h_mature, "мощность: рост < зрелость > распад")


func test_cloud_over_leaning_column_and_drift() -> void:
	var m := _model()
	var th := _thermal(3.0)
	var c := m.center(th, 500.0)
	approx(c.x, 1800.0, 1.0, "облако над верхом наклонённого столба")
	var c2 := m.center(th, 900.0)
	approx(c2.x - c.x, 5.0 * 100.0, 1.0, "на распаде облако уплывает по ветру")


# test_cumulus_are_not_cloud_objects (has_cloud только у Cb) — rust/dp-air/tests/terms_objects.rs
# (records_match_gd_dump, core_storm_equals_storm_k) и terms_clouds.rs (cloud_hooks_default_zero…).


func _obj(id: int, c: Vector2, radius: float) -> CloudModel.Obj:
	var ob := CloudModel.Obj.new()
	ob.id = id
	ob.c = c
	ob.base_msl = 1800.0
	ob.stage = Vector3(1.0, 0.0, 1.0)
	ob.size = Vector4(radius, radius, 700.0, 0.0)
	ob.life_t0 = 0.0
	ob.life_t1 = 2000.0
	return ob


func test_overlapping_clouds_merge() -> void:
	var m := _model()
	var list := m.select(
		{
			7: _obj(7, Vector2(0.0, 0.0), 600.0),
			8: _obj(8, Vector2(100.0, 0.0), 400.0),
			9: _obj(9, Vector2(0.0, 8000.0), 600.0)
		},
		800.0,
		Vector3.ZERO
	)
	check(list.size() == 2, "два наложившихся облака слились: %d" % list.size())


func test_static_thermals_from_weather_config() -> void:
	# Статичные термики — set_static_thermals (W2 v4); замена списка = новая загрузка места.
	var over := {"wind_speed_kmh": 0.0}
	var a := Rig.make({"over": over, "statics": [[500.0, -300.0, 3.0, 90.0]], "focus": Vector3(500, 800, -300)})
	check(a.thermals_near(Vector3(500, 800, -300), 3000.0).size() == 1, "один статичный термик")
	var w := a.mean_wind_at(Vector3(500, 800, -300)).y
	check(w > 2.0, "статичный термик поднимает: %.2f" % w)
	a.free()
	var b := Rig.make({"over": over, "statics": [[-500.0, 0.0, 2.0, 80.0]], "focus": Vector3(-500, 800, 0)})
	check(b.mean_wind_at(Vector3(-500, 800, 0)).y > 1.0, "другой список даёт другой термик")
	b.free()
	var c := Rig.make({"over": over, "mode": 1, "focus": Vector3(500, 800, -300)})
	check(c.thermals_near(Vector3(500, 800, -300), 3000.0).is_empty(), "пустой статический список — термиков нет")
	# фон -0,5 м/с над пустым списком — rust/dp-air/tests/terms_thermal.rs (background_sink_fades_to_ground):
	# в сумме с полем Пикара над ровной землёй вертикаль поля 0, фон есть только у слагаемого thermal
	c.free()


# test_decaying_thermal_bottom_cut — rust/dp-air/tests/terms_thermal.rs (decaying_thermal_bottom_cut);
# test_cloud_streets_align_across_wind — streets_align_sources; test_cloud_shadow_weakens_new_thermals и
# test_shade_weakens_born_thermals — terms_thermal.rs cloud_hooks_default_zero_and_shade_weakens,
# terms_thermal_cloud.rs hooks_shade_scales_source_strength; test_extreme_thermals — extreme_thermals_exist;
# test_source_strength_controls_frequency — source_strength_controls_frequency.


func test_wind_changes_lean_and_mean_wind() -> void:
	# Ветер с запада — ядро наклонено на восток; с севера (дует на юг, +Z) — на юг.
	var west := Rig.make({"over": {"wind_speed_kmh": 10.0, "wind_from_deg": 270.0},
		"statics": [[0.0, 0.0, 3.0, 100.0]]})
	var cw := west.cores(Vector3(0, 300, 0), 1000.0)
	check(cw.size() >= Atmosphere.CORE_STRIDE, "ядро есть (запад)")
	if cw.size() >= Atmosphere.CORE_STRIDE:
		check(cw[Atmosphere.CORE_LEAN_X] > 0.0, "ветер с запада — наклон на восток")
	west.free()
	var north := Rig.make({"over": {"wind_speed_kmh": 20.0, "wind_from_deg": 0.0},
		"statics": [[0.0, 0.0, 3.0, 100.0]]})
	var cn := north.cores(Vector3(0, 300, 0), 1000.0)
	check(cn.size() >= Atmosphere.CORE_STRIDE, "ядро есть (север)")
	if cn.size() >= Atmosphere.CORE_STRIDE:
		check(
			cn[Atmosphere.CORE_LEAN_Z] > 0.0 and absf(cn[Atmosphere.CORE_LEAN_X]) < 1e-6,
			"ветер с севера — наклон на юг"
		)
	var lo := north.mean_wind_at(Vector3(0, 10, 0)).length()
	var hi := north.mean_wind_at(Vector3(0, 300, 0)).length()
	# скорость пресета на опорной высоте — слагаемое профиля, rust/dp-air/tests/terms_frame.rs
	# (профиль ветра по высоте); в сумме с полем Пикара на 10 м она 5,43 против 5,56 м/с пресета
	check(hi > lo, "с высотой ветер сильнее")
	north.free()
