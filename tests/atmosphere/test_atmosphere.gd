extends TestCase
## Тесты атмосферы через фасад W2 v4: профиль термика, снос, фон, склон/подветренная сторона, кромка,
## детерминизм, турбулентность, производительность. Воздух — tests/atmosphere/air_rig.gd (место из
## функций, эталон погоды, статические термики); «без турбулентности» — mean_wind_at (SAMPLE_MEAN).
## Жизненный цикл термиков в поле, порционное обновление, источники по солнцу — слагаемое крейта
## (RW-12s: проверки через внутренности GD удалены, эквиваленты — в отчёте RW-12s и ниже).

const Rig := preload("res://tests/atmosphere/air_rig.gd")
const RIDGE_H := 300.0
const RIDGE_W := 400.0


## Хребет вдоль оси Z (гребень на x = 0).
static func _ridge(x: float, _z: float) -> float:
	return RIDGE_H * exp(-(x / RIDGE_W) * (x / RIDGE_W))


static func _hills(x: float, z: float) -> float:
	return 400.0 + 150.0 * sin(x / 700.0) * cos(z / 900.0)


## Rig.make с часом старта и скоростью: air_rig их не задаёт, а крейт требует start_hour и speed (W5, input.md) — без них
## set_conditions отклоняется, погода пуста, термики дают 0. 12 ч — как у прежних тестов.
static func _make(o: Dictionary) -> Atmosphere:
	var oo := o.duplicate()
	if not oo.has("cond"):
		oo["cond"] = {
			"preset": Rig.preset(String(o.get("preset", "weather/medium")), o.get("over", {})),
			"start_hour": float(o.get("start_hour", 12.0)),
			"speed": 1.0,
		}
	return Rig.make(oo)


func _static_one(wind_kmh: float, strength: float = 3.0, radius: float = 100.0) -> Atmosphere:
	return _make(
		{
			"over": {"wind_speed_kmh": wind_kmh},
			"statics": [[0.0, 0.0, strength, radius]],
			"advance": 0.01,
		}
	)


func test_thermal_profile() -> void:
	var a := _static_one(0.0)
	var y := 800.0
	var bg := float(a.weather().background_sink_ms)
	var w0 := a.mean_wind_at(Vector3(0, y, 0)).y
	check(w0 > 2.0, "ядро поднимает: %.2f" % w0)
	# Убывает от ядра к краю.
	var prev := w0
	var mono := true
	for r in range(10, 90, 10):
		var w := a.mean_wind_at(Vector3(r, y, 0)).y
		if w > prev + 1.0e-4:
			mono = false
		prev = w
	check(mono, "подъём убывает от оси к краю ядра")
	# Кольцо опускания сильнее фона.
	var ring := a.mean_wind_at(Vector3(130, y, 0)).y
	check(ring < bg - 0.2, "кольцо опускания %.2f < фон %.2f" % [ring, bg])
	# Далеко — только фон.
	approx(a.mean_wind_at(Vector3(1500, y, 0)).y, bg, 0.01, "далеко от термика фон")
	# Радиус растёт с высотой (Allen): на 1/3 радиуса у кромки подъём внизу слабее относительного.
	var low := a.mean_wind_at(Vector3(70, 200, 0)).y / a.mean_wind_at(Vector3(0, 200, 0)).y
	var high := a.mean_wind_at(Vector3(70, 1400, 0)).y / a.mean_wind_at(Vector3(0, 1400, 0)).y
	check(high > low, "термик шире наверху: %.2f > %.2f" % [high, low])
	a.free()


func test_wing_asymmetry_at_edge() -> void:
	# FR-8: на краю ядра консоли крыла (±5 м) получают разный подъём — крыло кренит.
	var a := _static_one(0.0)
	var r := 90.0 * 0.6
	var inner := a.mean_wind_at(Vector3(r - 5.0, 800, 0)).y
	var outer := a.mean_wind_at(Vector3(r + 5.0, 800, 0)).y
	check(inner - outer > 0.15, "разница на консолях %.2f м/с" % (inner - outer))
	a.free()


func test_wind_drift_and_lean() -> void:
	var a := _static_one(18.0)  # ветер с запада (270) — дует на восток, +X
	var mw := a.mean_wind_at(Vector3(0, 500, 0))
	check(mw.x > 4.0 and absf(mw.z) < 0.01, "ветер с запада дует на восток: %s" % mw)
	var best_x := -1.0e9
	var best_w := -1.0e9
	var y := 1000.0
	for x in range(-500, 3000, 10):
		var w := a.mean_wind_at(Vector3(x, y, 0)).y
		if w > best_w:
			best_w = w
			best_x = x
	var cores := a.cores(Vector3(0, 0, 0), 100.0)
	check(cores.size() >= Atmosphere.CORE_STRIDE, "ядро есть")
	var expect: float = cores[Atmosphere.CORE_LEAN_X] * y
	check(best_x > 200.0, "ось на 1000 м снесена по ветру: %.0f м" % best_x)
	approx(best_x, expect, 15.0, "снос = наклон × высота")
	a.free()


func test_lifecycle_envelope() -> void:
	var th := AtmoThermal.new()
	th.src = Vector3(0, 0, 0)
	th.top = 1000.0
	th.t_birth = 100.0
	th.t_grow = 100.0
	th.t_mature = 200.0
	th.t_decay = 100.0
	th.drift_vel = Vector2(5, 0)
	approx(th.envelope(50.0), 0.0, 1e-6, "до рождения нет")
	var g := th.envelope(150.0)
	check(g > 0.2 and g < 0.8, "рост: %.2f" % g)
	approx(th.envelope(300.0), 1.0, 1e-6, "зрелость")
	var d := th.envelope(450.0)
	check(d > 0.1 and d < 0.9, "распад: %.2f" % d)
	approx(th.envelope(510.0), 0.0, 1e-6, "после конца нет")
	th.update_time(450.0)
	approx(th.cut_h, 500.0, 1.0, "на середине распада низ оторван до половины столба")
	approx(th.drift.x, 250.0, 1.0, "оторвавшийся термик сносится ветром")
	th.update_time(300.0)
	check(th.cut_h < -1.0e8, "в зрелости низ не оторван")


# test_lifecycle_in_field (рождение и смена термиков за час) — rust/dp-air/tests/terms_thermal.rs
# (lifecycle_in_field, lifecycle_envelope_cut_and_drift).


func test_background_sink() -> void:
	var a := _make({"over": {"wind_speed_kmh": 0.0}, "mode": 1, "advance": 0.01})
	var bg := float(a.weather().background_sink_ms)
	approx(a.mean_wind_at(Vector3(100, 600, 50)).y, bg, 1e-4, "фоновое опускание")
	approx(a.mean_wind_at(Vector3(100, 0, 50)).y, 0.0, 1e-4, "у земли вертикального потока нет")
	check(bg < 0.0, "фон отрицательный")
	a.free()


func test_cloudbase_limits_climb_without_cloud() -> void:
	# Термик без облака (слабее порога облака): у кромки подъём гаснет, выше — не поднимает.
	var a := _static_one(0.0, 0.8, 120.0)
	var cb := a.cloudbase_msl()
	var mid := a.mean_wind_at(Vector3(0, cb - 600, 0)).y
	var near_base := a.mean_wind_at(Vector3(0, cb - 20, 0)).y
	var above := a.mean_wind_at(Vector3(0, cb + 50, 0)).y
	check(mid > 0.3, "в середине слоя подъём %.2f" % mid)
	check(near_base < mid * 0.5, "у кромки подъём гаснет %.2f" % near_base)
	check(above <= 0.0, "выше кромки не поднимает %.2f" % above)
	a.free()


func test_ridge_lift_windward_and_lee_sink() -> void:
	var a := _make(
		{
			"over": {"wind_speed_kmh": 25.0, "wind_from_deg": 270.0},
			"mode": 1,
			"ground": _ridge,
			"half": 3000.0,
			"spacing": 50.0,
			"advance": 0.01,
		}
	)
	var bg := float(a.weather().background_sink_ms)
	var xw := -300.0
	var ww := a.mean_wind_at(Vector3(xw, _ridge(xw, 0) + 50.0, 0)).y
	check(ww > 1.0, "наветренный склон поднимает: %.2f" % ww)
	var ww_high := a.mean_wind_at(Vector3(xw, _ridge(xw, 0) + 700.0, 0)).y
	check(ww_high < ww * 0.5, "подъём затухает с высотой: %.2f < %.2f" % [ww_high, ww])
	# Зона подъёма выдвинута вперёд склона.
	var front := a.mean_wind_at(Vector3(-650, 250, 0)).y
	check(front > bg + 0.3, "перед склоном уже поднимает: %.2f" % front)
	var xl := 300.0
	var wl := a.mean_wind_at(Vector3(xl, _ridge(xl, 0) + 30.0, 0)).y
	check(wl < bg - 0.5, "подветренный склон опускает: %.2f" % wl)
	# Ветер слабее в подветренной зоне (против набегающего той же высоты над землёй).
	var vl := a.mean_wind_at(Vector3(xl, _ridge(xl, 0) + 30.0, 0)).x
	var vu := a.mean_wind_at(Vector3(-2500.0, 30.0, 0)).x
	check(vl < vu, "в тени гребня ветер ослаблен: %.2f < %.2f" % [vl, vu])
	a.free()


func test_lee_turbulence_stronger() -> void:
	var a := _make(
		{
			"over": {
				"wind_speed_kmh": 25.0,
				"wind_from_deg": 270.0,
				"convective_turbulence_ms": 0.0
			},
			"mode": 1,
			"ground": _ridge,
			"half": 3000.0,
			"spacing": 50.0,
			"advance": 0.01,
		}
	)
	var lee := _variance_w(a, 350.0, 40.0)
	var wind_side := _variance_w(a, -600.0, 40.0)
	check(lee > wind_side * 1.3, "за гребнем болтает сильнее: σ² %.3f > %.3f" % [lee, wind_side])
	a.free()


func _variance_w(a: Atmosphere, x: float, agl: float) -> float:
	var s := 0.0
	var s2 := 0.0
	var n := 400
	for i in n:
		var p := Vector3(x + (i % 20) * 3.0, _ridge(x, 0) + agl, (i / 20) * 7.0)
		var w := a.air_velocity_at(p).y
		s += w
		s2 += w * w
	var m := s / n
	return s2 / n - m * m


func test_turbulence_deterministic_and_ground_stronger() -> void:
	var a := _make(
		{"over": {"wind_speed_kmh": 20.0, "convective_turbulence_ms": 0.0}, "mode": 1, "advance": 0.01}
	)
	var p := Vector3(123, 40, -77)
	var v1 := a.air_velocity_at(p)
	var v2 := a.air_velocity_at(p)
	check(v1 == v2, "детерминированно")
	var low := 0.0
	var high := 0.0
	for i in 400:
		var q := Vector3(i * 13.0, 0, i * 7.0)
		var dl := a.air_velocity_at(q + Vector3(0, 20, 0)) - a.mean_wind_at(q + Vector3(0, 20, 0))
		var dh := a.air_velocity_at(q + Vector3(0, 900, 0)) - a.mean_wind_at(q + Vector3(0, 900, 0))
		low += dl.x * dl.x
		high += dh.x * dh.x
	check(low > high * 1.2, "у земли порывистее: %.2f > %.2f" % [low / 400, high / 400])
	check(high > 0.0, "на высоте тоже есть пульсации")
	a.free()


func test_deterministic_generation() -> void:
	var o := {"preset": "weather/strong", "ground": _hills, "advance": 10.0}
	var a := _make(o)
	var b := _make(o)
	var ca := a.cores(Vector3(0, 300, 0), 8000.0)
	var cb := b.cores(Vector3(0, 300, 0), 8000.0)
	check(ca == cb and not ca.is_empty(), "одинаковые наборы термиков (%d)" % (ca.size() / Atmosphere.CORE_STRIDE))
	var same := true
	for i in 200:
		var p := Vector3(i * 37.0 - 3000.0, 900.0 + i, i * 23.0 - 2000.0)
		if not a.air_velocity_at(p).is_equal_approx(b.air_velocity_at(p)):
			same = false
	check(same, "одинаковые скорости в одних точках")
	a.free()
	b.free()


# test_sun_controls_sources (источники только на «солнечной» половине) — rust/dp-air/tests/terms_thermal.rs
# (source_strength_controls_frequency) и terms_thermal_src.rs (grid_equals_pointwise, edge_boost_near_class_boundary).


func test_performance() -> void:
	var a := _make({"preset": "weather/strong", "ground": _hills, "advance": 10.0})
	# Прогреть кеши в районе запросов.
	for i in 200:
		a.air_velocity_at(Vector3((i % 20) * 50.0, 1200.0, (i / 20) * 50.0))
	# Медиана 7 серий по 2000 вызовов: устойчиво к нагрузке соседних процессов
	# (одна «плохая» серия не роняет тест), но заметное замедление кода ловится.
	var n := 2000
	var runs: Array[float] = []
	var acc := Vector3.ZERO
	for r in 7:
		var t0 := Time.get_ticks_usec()
		for i in n:
			var p := Vector3((i % 100) * 9.0, 900.0 + (i % 7) * 50.0, (i / 100) * 9.0 + r * 3.0)
			acc += a.air_velocity_at(p)
		runs.append(float(Time.get_ticks_usec() - t0) / n)
	runs.sort()
	var med := runs[runs.size() / 2]
	print(
		(
			"         air_velocity_at: медиана %.2f мкс/вызов (серии %.1f…%.1f), ядер %d"
			% [med, runs[0], runs[-1], a.cores(Vector3(0, 300, 0), 8000.0).size() / Atmosphere.CORE_STRIDE]
		)
	)
	# Бюджет: планер зовёт ~5 точек × 120 Гц = 600 вызовов/с; 40 мкс/вызов — это 24 мс
	# в секунду (~0,4 мс на кадр). Порог с запасом ×4 на нагрузку и слабый CPU.
	check(med < 40.0, "air_velocity_at медиана < 40 мкс: %.2f мкс" % med)
	var t1 := Time.get_ticks_usec()
	for i in 120:
		Rig.step(a, 1.0 / 120.0)
	var step_us := (Time.get_ticks_usec() - t1) / 120.0
	print("         advance_to: %.1f мкс в среднем" % step_us)
	check(acc.is_finite(), "значения конечны")
	a.free()


# PF-8 (test_refresh_chunked_equals_sync, test_refresh_abort_midway_then_sync_equals_sync) — порционное
# обновление GD-ThermalField (begin_refresh/step_refresh) удалено вместе с GD-слагаемым; эквиваленты —
# rust/dp-air/tests/terms_thermal.rs (advance_cadence_and_inputs, start_at_equals_run_from_zero) и
# terms_thermal_field.rs (rebuild_by_key_keeps_live_thermals, advance_builds_in_background).
