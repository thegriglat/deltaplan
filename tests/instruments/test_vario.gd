extends TestCase
## Вычислитель вариометра: инерция датчика, среднее, качество, след.

func _cfg(tau: float, window: float) -> Dictionary:
	var cfg: Dictionary = Config.get_config("instruments").duplicate(true)
	cfg.vario.filter_time_constant_s = tau
	cfg.vario.average_window_s = window
	return cfg


func _run(v: Vario, value: float, seconds: float, dt: float) -> void:
	for i in int(round(seconds / dt)):
		v.update_raw(value, dt)


func test_config_has_realistic_filter() -> void:
	var v := Vario.new()
	v.setup()
	var tau := v.get_filter_time_constant_s()
	check(tau >= 0.5 and tau <= 1.0, "постоянная времени датчика 0,5–1 с, сейчас %.2f" % tau)
	var w := v.get_average_window_s()
	check(w >= 20.0 and w <= 30.0, "окно среднего 20–30 с, сейчас %.1f" % w)


func test_step_response_time_constant() -> void:
	# Ступенька 0 → 1 м/с: через τ выход 63,2 %, через 3τ — 95 %.
	for dt in [1.0 / 120.0, 1.0 / 60.0, 1.0 / 200.0]:
		var v := Vario.new()
		v.setup(_cfg(0.8, 25.0))
		_run(v, 0.0, 1.0, dt)
		_run(v, 1.0, 0.8, dt)
		approx(v.vario_ms, 1.0 - exp(-1.0), 0.01, "через τ при dt=%.4f" % dt)
		_run(v, 1.0, 1.6, dt)
		approx(v.vario_ms, 1.0 - exp(-3.0), 0.01, "через 3τ при dt=%.4f" % dt)


func test_filter_follows_sine_with_lag() -> void:
	# Синус 0,5 Гц сглаживается: амплитуда меньше входной (датчик инерционный).
	var v := Vario.new()
	v.setup(_cfg(0.8, 25.0))
	var dt := 1.0 / 120.0
	var peak := 0.0
	for i in int(20.0 / dt):
		var t := i * dt
		v.update_raw(2.0 * sin(TAU * 0.5 * t), dt)
		if t > 10.0:
			peak = maxf(peak, v.vario_ms)
	var expected := 2.0 / sqrt(1.0 + pow(TAU * 0.5 * 0.8, 2.0))
	approx(peak, expected, 0.03, "амплитуда после фильтра")


func test_average_over_window() -> void:
	var v := Vario.new()
	v.setup(_cfg(0.7, 25.0))
	var dt := 1.0 / 120.0
	_run(v, 2.0, 40.0, dt)
	approx(v.average_ms, 2.0, 0.01, "среднее при постоянных 2 м/с")
	_run(v, 0.0, 12.5, dt)
	approx(v.average_ms, 1.0, 0.03, "полокна нулей — среднее 1 м/с")
	_run(v, 0.0, 12.6, dt)
	approx(v.average_ms, 0.0, 0.02, "через окно — 0")
	_run(v, -1.5, 30.0, dt)
	approx(v.average_ms, -1.5, 0.01, "снижение")


func test_average_window_configurable() -> void:
	var v := Vario.new()
	v.setup(_cfg(0.7, 20.0))
	var dt := 1.0 / 120.0
	_run(v, 3.0, 25.0, dt)
	_run(v, 0.0, 10.0, dt)
	approx(v.average_ms, 1.5, 0.03, "окно 20 с: 10 с нулей — половина")


func test_average_before_window_filled() -> void:
	# Первые секунды: среднее по тому, что есть (не делим на полное окно).
	var v := Vario.new()
	v.setup(_cfg(0.7, 25.0))
	_run(v, 1.0, 5.0, 1.0 / 120.0)
	approx(v.average_ms, 1.0, 0.02, "среднее за 5 с")


func test_glide_ratio_and_track() -> void:
	var v := Vario.new()
	v.setup()
	var t := Telemetry.new()
	t.on_ground = false
	t.airspeed = 11.0
	t.groundspeed = 10.0
	t.vario = -1.0
	t.position = Vector3(0, 1500, 0)
	var dt := 1.0 / 120.0
	for i in int(60.0 / dt):
		t.position += Vector3(10.0, -1.0, 0.0) * dt
		t.altitude_msl = t.position.y
		v.update(t, dt)
	approx(v.glide_ratio, 10.0, 0.1, "качество = 10 м/с / 1 м/с")
	check(v.in_flight, "полёт начался")
	approx(v.flight_time_s, 60.0, 0.05, "время полёта")
	approx(v.distance_from_takeoff_m, 600.0, 1.0, "расстояние от взлёта")
	check(v.track.size() >= 25 and v.track.size() <= 35, "след ~ каждые 2 с: %d точек" % v.track.size())
	# Набор — качество не считается.
	t.vario = 1.0
	for i in int(30.0 / dt):
		t.position += Vector3(10.0, 1.0, 0.0) * dt
		v.update(t, dt)
	check(v.glide_ratio == INF, "в наборе качество — «--»")


func test_on_ground_no_flight() -> void:
	var v := Vario.new()
	v.setup()
	var t := Telemetry.new()
	t.on_ground = true
	for i in 240:
		v.update(t, 1.0 / 120.0)
	check(not v.in_flight, "на земле полёт не начат")
	approx(v.flight_time_s, 0.0, 0.0, "время полёта стоит")
