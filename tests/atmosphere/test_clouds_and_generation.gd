extends TestCase
## Облака (CloudModel), улицы, статичные термики из конфига, отрыв низа распадающегося термика.


func _atmo(weather_over: Dictionary = {}, preset: String = "weather/medium") -> Atmosphere:
	var a := Atmosphere.new()
	var w := Config._deep_merge(Config.get_config(preset), weather_over)
	a.configure(Config.get_config("atmosphere"), w)
	a.turbulence_enabled = false
	return a


static func _flat(_x: float, _z: float) -> float:
	return 0.0


static func _sun(_x: float, _z: float) -> float:
	return 1.0


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


func test_weak_thermal_no_cloud_and_blue_day() -> void:
	var a := _atmo({"cloud_min_strength_ms": 99.0}, "weather/weak")
	a.set_ground(_flat, _sun)
	a.step(0.01)
	var with_cloud := 0
	for id in a.field.thermals:
		if a.field.thermals[id].has_cloud:
			with_cloud += 1
	check(a.field.thermals.size() > 0, "термики есть")
	check(with_cloud == 0, "голубой день — без облаков")
	a.free()


func test_overlapping_clouds_merge() -> void:
	var m := _model()
	var th1 := _thermal(3.0)
	var th2 := _thermal(2.0)
	th2.id = 8
	th2.src = Vector3(100, 0, 0)
	var th3 := _thermal(3.0)
	th3.id = 9
	th3.src = Vector3(0, 0, 8000)
	var list := m.select({7: th1, 8: th2, 9: th3}, 800.0, Vector3.ZERO)
	check(list.size() == 2, "два наложившихся облака слились: %d" % list.size())


func test_static_thermals_from_weather_config() -> void:
	var st := [{"x_m": 500.0, "z_m": -300.0, "strength_ms": 3.0, "radius_m": 90.0}]
	var a := _atmo({"thermal_mode": "static", "static_thermals": st, "wind_speed_kmh": 0.0})
	a.set_ground(_flat, _sun)
	a.step(0.01)
	check(a.field.thermals.size() == 1, "один статичный термик")
	var w := a.air_velocity_at(Vector3(500, 800, -300)).y
	check(w > 2.0, "статичный термик поднимает: %.2f" % w)
	a.load_static_thermals([{"x_m": -500.0, "z_m": 0.0, "strength_ms": 2.0, "radius_m": 80.0}])
	a.step(1.0)
	check(a.air_velocity_at(Vector3(-500, 800, 0)).y > 1.0, "load_static_thermals добавляет")
	a.clear_static_thermals()
	a.step(1.0)
	approx(a.air_velocity_at(Vector3(500, 800, -300)).y, -0.5, 0.01, "после очистки — фон")
	a.free()


func test_decaying_thermal_bottom_cut() -> void:
	# Низко под распадающимся термиком подъёма уже нет, выше — ещё есть.
	var a := _atmo({"thermal_mode": "static", "wind_speed_kmh": 0.0})
	a.set_ground(_flat, _sun)
	var id := a.add_static_thermal(0.0, 0.0, 3.0, 100.0)
	var th: AtmoThermal = a.field.thermals[id]
	th.is_static = false
	th.t_birth = -1000.0
	th.t_grow = 100.0
	th.t_mature = 800.0
	th.t_decay = 400.0
	a.time_s = 0.0
	a.step(0.01)  # середина распада: низ оторван до половины столба
	var low := a.air_velocity_at(Vector3(0, 300, 0)).y
	var high := a.air_velocity_at(Vector3(0, 1300, 0)).y
	check(low < 0.0, "внизу пусто: %.2f" % low)
	check(high > 0.3, "наверху ещё поднимает: %.2f" % high)
	a.free()


func test_cloud_streets_align_across_wind() -> void:
	# При сильном ветре источники стягиваются к линиям улиц вдоль ветра.
	var a := _atmo({"wind_speed_kmh": 35.0, "wind_from_deg": 270.0, "street_strength": 1.0})
	var b := _atmo({"wind_speed_kmh": 35.0, "wind_from_deg": 270.0, "street_strength": 0.0})
	a.set_ground(_flat, _sun)
	b.set_ground(_flat, _sun)
	a.step(0.01)
	b.step(0.01)
	var spacing := a.field._street_spacing
	check(_line_spread(a, spacing) < _line_spread(b, spacing) * 0.5, "источники вдоль улиц")
	a.free()
	b.free()


## Средний разброс поперёк ветра (ветер вдоль X → поперёк Z) до ближайшей линии улицы.
func _line_spread(a: Atmosphere, spacing: float) -> float:
	var s := 0.0
	var n := 0
	for id in a.field.thermals:
		var th: AtmoThermal = a.field.thermals[id]
		var c := th.src.z
		s += absf(c - roundf(c / spacing) * spacing)
		n += 1
	return s / maxi(n, 1)


func test_set_wind_changes_lean_and_mean_wind() -> void:
	var a := _atmo({"thermal_mode": "static", "wind_speed_kmh": 10.0, "wind_from_deg": 270.0})
	a.set_ground(_flat, _sun)
	var id := a.add_static_thermal(0.0, 0.0, 3.0, 100.0)
	a.step(0.01)
	check(a.field.thermals[id].lean.x > 0.0, "ветер с запада — наклон на восток")
	a.set_wind(20.0, 0.0)  # с севера — дует на юг (+Z)
	a.step(0.01)
	var th: AtmoThermal = a.field.thermals[id]
	check(th.lean.y > 0.0 and absf(th.lean.x) < 1e-6, "ветер с севера — наклон на юг")
	var lo := a.mean_wind_at(Vector3(0, 10, 0)).length()
	var hi := a.mean_wind_at(Vector3(0, 300, 0)).length()
	approx(lo, 20.0 / 3.6, 0.01, "на опорной высоте — скорость пресета")
	check(hi > lo, "с высотой ветер сильнее")
	a.free()


func test_cloud_shadow_weakens_new_thermals() -> void:
	# VR-2: источник в тени зрелого облака — слабее.
	var a := _atmo({"thermal_mode": "static", "wind_speed_kmh": 0.0})
	a.set_ground(_flat, _sun)
	a.set_sun_direction(Vector3(0, 1, 0))  # солнце в зените — тень прямо под облаком
	a.add_static_thermal(0.0, 0.0, 3.0, 100.0)
	check(a.field._cloud_shade(Vector2(0, 0), 0.0) > 0.9, "под облаком тень")
	check(a.field._cloud_shade(Vector2(3000, 0), 0.0) == 0.0, "вдали тени нет")
	a.set_sun_direction(Vector3(0.6, 0.8, 0))  # солнце на востоке — тень к западу
	check(a.field._cloud_shade(Vector2(-1350, 0), 0.0) > 0.9, "тень смещена от солнца")
	a.free()
