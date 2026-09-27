extends TestCase
## Тесты атмосферы: профиль термика, снос, жизненный цикл, фон, склон/подветренная сторона,
## кромка, детерминизм, турбулентность, производительность.

const RIDGE_H := 300.0
const RIDGE_W := 400.0


func _atmo(
	weather_over: Dictionary = {}, atmo_over: Dictionary = {}, preset: String = "weather/medium"
) -> Atmosphere:
	var a := Atmosphere.new()
	var w := Config._deep_merge(Config.get_config(preset), weather_over)
	a.configure(Config._deep_merge(Config.get_config("atmosphere"), atmo_over), w)
	a.turbulence_enabled = false
	return a


## Хребет вдоль оси Z (гребень на x = 0).
static func _ridge(x: float, _z: float) -> float:
	return RIDGE_H * exp(-(x / RIDGE_W) * (x / RIDGE_W))


static func _flat(_x: float, _z: float) -> float:
	return 0.0


static func _sun(_x: float, _z: float) -> float:
	return 1.0


static func _hills(x: float, z: float) -> float:
	return 400.0 + 150.0 * sin(x / 700.0) * cos(z / 900.0)


func _static_one(wind_kmh: float, strength: float = 3.0, radius: float = 100.0) -> Atmosphere:
	var a := _atmo({"wind_speed_kmh": wind_kmh, "thermal_mode": "static"})
	a.set_ground(_flat, _sun)
	a.add_static_thermal(0.0, 0.0, strength, radius)
	a.step(0.01)
	return a


func test_thermal_profile() -> void:
	var a := _static_one(0.0)
	var y := 800.0
	var bg := float(a.weather.background_sink_ms)
	var w0 := a.air_velocity_at(Vector3(0, y, 0)).y
	check(w0 > 2.0, "ядро поднимает: %.2f" % w0)
	# Убывает от ядра к краю.
	var prev := w0
	var mono := true
	for r in range(10, 90, 10):
		var w := a.air_velocity_at(Vector3(r, y, 0)).y
		if w > prev + 1.0e-4:
			mono = false
		prev = w
	check(mono, "подъём убывает от оси к краю ядра")
	# Кольцо опускания сильнее фона.
	var ring := a.air_velocity_at(Vector3(130, y, 0)).y
	check(ring < bg - 0.2, "кольцо опускания %.2f < фон %.2f" % [ring, bg])
	# Далеко — только фон.
	approx(a.air_velocity_at(Vector3(1500, y, 0)).y, bg, 0.01, "далеко от термика фон")
	# Радиус растёт с высотой (Allen): на 1/3 радиуса у кромки подъём внизу слабее относительного.
	var low := a.air_velocity_at(Vector3(70, 200, 0)).y / a.air_velocity_at(Vector3(0, 200, 0)).y
	var high := a.air_velocity_at(Vector3(70, 1400, 0)).y / a.air_velocity_at(Vector3(0, 1400, 0)).y
	check(high > low, "термик шире наверху: %.2f > %.2f" % [high, low])
	a.free()


func test_wing_asymmetry_at_edge() -> void:
	# FR-8: на краю ядра консоли крыла (±5 м) получают разный подъём — крыло кренит.
	var a := _static_one(0.0)
	var r := 90.0 * 0.6
	var inner := a.air_velocity_at(Vector3(r - 5.0, 800, 0)).y
	var outer := a.air_velocity_at(Vector3(r + 5.0, 800, 0)).y
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
		var w := a.air_velocity_at(Vector3(x, y, 0)).y
		if w > best_w:
			best_w = w
			best_x = x
	var th: Dictionary = a.thermals_near(Vector3(0, 0, 0), 100.0)[0]
	var expect: float = th.lean.x * y
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


func test_lifecycle_in_field() -> void:
	# Термики рождаются и умирают: через час набор другой, но их число держится.
	var a := _atmo({}, {}, "weather/strong")
	a.set_ground(_flat, _sun)
	a.step(0.01)
	var ids0 := a.field.thermals.keys()
	check(ids0.size() > 20, "в радиусе генерации есть термики: %d" % ids0.size())
	var alive := 0
	var growing := 0
	var decaying := 0
	for id in ids0:
		var th: AtmoThermal = a.field.thermals[id]
		var e := th.envelope(a.time_s)
		if e > 0.0:
			alive += 1
		if a.time_s < th.t_birth + th.t_grow:
			growing += 1
		elif a.time_s > th.t_decay_start():
			decaying += 1
	check(
		growing > 0 and decaying > 0,
		"есть растущие (%d) и распадающиеся (%d)" % [growing, decaying]
	)
	for i in 720:
		a.step(5.0)
	var ids1 := a.field.thermals.keys()
	var common := 0
	for id in ids1:
		if ids0.has(id):
			common += 1
	check(ids1.size() > 20, "через час термики есть: %d" % ids1.size())
	check(common < ids0.size() / 4, "через час почти все сменились (общих %d)" % common)
	a.free()


func test_background_sink() -> void:
	var a := _atmo({"wind_speed_kmh": 0.0, "thermal_mode": "static"})
	a.set_ground(_flat, _sun)
	a.step(0.01)
	var bg := float(a.weather.background_sink_ms)
	approx(a.air_velocity_at(Vector3(100, 600, 50)).y, bg, 1e-4, "фоновое опускание")
	approx(a.air_velocity_at(Vector3(100, 0, 50)).y, 0.0, 1e-4, "у земли вертикального потока нет")
	check(bg < 0.0, "фон отрицательный")
	a.free()


func test_cloudbase_limits_climb() -> void:
	var a := _static_one(0.0, 4.0, 120.0)
	var cb := a.get_cloudbase_msl()
	var mid := a.air_velocity_at(Vector3(0, cb - 600, 0)).y
	var near_base := a.air_velocity_at(Vector3(0, cb - 20, 0)).y
	var above := a.air_velocity_at(Vector3(0, cb + 50, 0)).y
	check(mid > 3.0, "в середине слоя сильный подъём %.2f" % mid)
	check(near_base < mid * 0.5, "у кромки подъём гаснет %.2f" % near_base)
	check(above <= 0.0, "выше кромки не поднимает %.2f" % above)
	a.free()


func test_ridge_lift_windward_and_lee_sink() -> void:
	var a := _atmo({"wind_speed_kmh": 25.0, "wind_from_deg": 270.0, "thermal_mode": "static"})
	a.set_ground(_ridge, _sun)
	a.step(0.01)
	var bg := float(a.weather.background_sink_ms)
	var xw := -300.0
	var ww := a.air_velocity_at(Vector3(xw, _ridge(xw, 0) + 50.0, 0)).y
	check(ww > 1.0, "наветренный склон поднимает: %.2f" % ww)
	var ww_high := a.air_velocity_at(Vector3(xw, _ridge(xw, 0) + 700.0, 0)).y
	check(ww_high < ww * 0.5, "подъём затухает с высотой: %.2f < %.2f" % [ww_high, ww])
	# Зона подъёма выдвинута вперёд склона.
	var front := a.air_velocity_at(Vector3(-650, 250, 0)).y
	check(front > bg + 0.3, "перед склоном уже поднимает: %.2f" % front)
	var xl := 300.0
	var wl := a.air_velocity_at(Vector3(xl, _ridge(xl, 0) + 30.0, 0)).y
	check(wl < bg - 0.5, "подветренный склон опускает: %.2f" % wl)
	# Ветер слабее в подветренной зоне.
	var pl := Vector3(xl, _ridge(xl, 0) + 30.0, 0)
	var hl := a.mean_wind_at(pl).x
	var vl := a.air_velocity_at(pl).x
	check(vl < hl, "в тени гребня ветер ослаблен")
	a.free()


func test_lee_turbulence_stronger() -> void:
	var a := _atmo(
		{
			"wind_speed_kmh": 25.0,
			"wind_from_deg": 270.0,
			"thermal_mode": "static",
			"convective_turbulence_ms": 0.0
		}
	)
	a.set_ground(_ridge, _sun)
	a.turbulence_enabled = true
	a.step(0.01)
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
	var a := _atmo(
		{"wind_speed_kmh": 20.0, "thermal_mode": "static", "convective_turbulence_ms": 0.0}
	)
	a.set_ground(_flat, _sun)
	a.turbulence_enabled = true
	a.step(0.01)
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
	var a := _atmo({}, {}, "weather/strong")
	var b := _atmo({}, {}, "weather/strong")
	a.set_ground(_hills, _sun)
	b.set_ground(_hills, _sun)
	a.turbulence_enabled = true
	b.turbulence_enabled = true
	for i in 10:
		a.step(1.0)
		b.step(1.0)
	check(a.field.thermals.size() == b.field.thermals.size(), "одинаковые наборы термиков")
	var same := true
	for i in 200:
		var p := Vector3(i * 37.0 - 3000.0, 900.0 + i, i * 23.0 - 2000.0)
		if not a.air_velocity_at(p).is_equal_approx(b.air_velocity_at(p)):
			same = false
	check(same, "одинаковые скорости в одних точках")
	a.free()
	b.free()


func test_sun_controls_sources() -> void:
	# Источники только там, где солнце: на «тёмной» половине (x < 0) термиков нет.
	var a := _atmo({}, {}, "weather/strong")
	a.set_ground(_flat, func(x: float, _z: float) -> float: return 1.0 if x > 0.0 else 0.0)
	a.step(0.01)
	var dark := 0
	for id in a.field.thermals:
		if a.field.thermals[id].src.x < 0.0:
			dark += 1
	check(a.field.thermals.size() > 10, "на солнечной стороне термики есть")
	check(dark == 0, "на тёмной стороне источников нет: %d" % dark)
	a.free()


func test_performance() -> void:
	var a := _atmo({}, {}, "weather/strong")
	a.set_ground(_hills, _sun)
	a.turbulence_enabled = true
	for i in 20:
		a.step(0.5)
	# Прогреть кеш рельефа в районе запросов.
	for i in 200:
		a.air_velocity_at(Vector3((i % 20) * 50.0, 1200.0, (i / 20) * 50.0))
	var n := 10000
	var t0 := Time.get_ticks_usec()
	var acc := Vector3.ZERO
	for i in n:
		acc += a.air_velocity_at(Vector3((i % 100) * 9.0, 900.0 + (i % 7) * 50.0, (i / 100) * 9.0))
	var us := Time.get_ticks_usec() - t0
	print(
		(
			"         air_velocity_at: %d вызовов за %.1f мс (%.2f мкс/вызов), активных термиков %d"
			% [n, us / 1000.0, float(us) / n, a.field.active_count()]
		)
	)
	# Бюджет: планер зовёт ~5 точек × 120 Гц = 600 вызовов/с;
	# 20 мкс/вызов — это 12 мс в секунду (~0,2 мс на кадр).
	check(us < 200000, "10000 вызовов быстрее 200 мс: %.1f мс" % (us / 1000.0))
	var t1 := Time.get_ticks_usec()
	for i in 120:
		a.step(1.0 / 120.0)
	var step_us := (Time.get_ticks_usec() - t1) / 120.0
	print("         step: %.1f мкс в среднем" % step_us)
	check(acc.is_finite(), "значения конечны")
	a.free()
