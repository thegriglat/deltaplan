extends TestCase
## Перистая пелена (VR-28), грозы Cb (VR-26), подветренные волны (VR-27).

const RIDGE_H := 800.0
const RIDGE_W := 1500.0


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


## Хребет поперёк ветра (гребень вдоль Z на x = 0).
static func _ridge(x: float, _z: float) -> float:
	return 500.0 + RIDGE_H * exp(-(x / RIDGE_W) * (x / RIDGE_W))


func _mean_strength(a: Atmosphere) -> Vector2:
	var s := 0.0
	for id in a.field.thermals:
		s += a.field.thermals[id].strength
	var n := a.field.thermals.size()
	return Vector2(s / maxi(n, 1), n)


func test_cirrus_weakens_thermals() -> void:
	var clear := _atmo({"cirrus_cover": 0.0}, "weather/strong")
	var veil := _atmo({"cirrus_cover": 0.9}, "weather/strong")
	for a in [clear, veil]:
		a.set_ground(_flat, func(_x: float, _z: float) -> float: return 0.8)
		a.step(0.01)
	var c := _mean_strength(clear)
	var v := _mean_strength(veil)
	check(veil.get_insolation() < 0.6, "пелена снижает прогрев: %.2f" % veil.get_insolation())
	check(v.x < c.x * 0.9, "термики под пеленой слабее: %.2f < %.2f м/с" % [v.x, c.x])
	check(v.y < c.y, "и реже: %d < %d" % [int(v.y), int(c.y)])
	clear.free()
	veil.free()


func _storm_atmo() -> Array:
	var a := _atmo({"wind_speed_kmh": 0.0, "thermal_mode": "static"}, "weather/storm")
	a.set_ground(_flat, _sun)
	var id := a.add_static_thermal(0.0, 0.0, 4.0, 150.0)
	var th: AtmoThermal = a.field.thermals[id]
	# Превратить в Cb посреди бури.
	th.is_static = false
	th.is_cb = true
	th.suck = 0.6
	th.has_cloud = true
	th.t_birth = -2000.0
	th.t_grow = 200.0
	th.t_mature = 3000.0
	th.t_decay = 400.0
	a.time_s = 0.0
	a.step(0.01)
	return [a, th]


func test_cb_downdraft_and_outflow() -> void:
	var r := _storm_atmo()
	var a: Atmosphere = r[0]
	var th: AtmoThermal = r[1]
	check(a.storm.cells.size() == 1, "грозовая ячейка есть")
	check(a.storm.intensity(th, a.time_s) > 0.9, "буря в разгаре")
	var c := th.cloud_center(a.time_s)
	# Ливневый поток — рядом с центром, сбоку от ядра термика.
	var rd := a.storm.downdraft_radius(th)
	var p_dd := Vector3(c.x + rd * 0.5, 900.0, c.y)
	var w_dd := a.air_velocity_at(p_dd).y
	check(w_dd < -3.0, "под Cb сильный нисходящий поток: %.2f м/с" % w_dd)
	# Растекание у земли: ветер от облака, порывистый; на фронте — подъём.
	var rf := a.storm.front_radius(th, a.time_s)
	var p_out := Vector3(c.x + rf * 0.6, 50.0, c.y)
	var u_out := a.air_velocity_at(p_out).x
	check(u_out > 5.0, "у земли ветер от облака: %.1f м/с" % u_out)
	var w_front := a.air_velocity_at(Vector3(c.x + rf, 400.0, c.y)).y
	var bg := float(a.weather.background_sink_ms)
	check(w_front > bg + 0.8, "над фронтом порывов подъём: %.2f" % w_front)
	var far := a.air_velocity_at(Vector3(c.x + rf + 4000.0, 50.0, c.y))
	check(absf(far.x) < 0.5, "за фронтом тихо: %.2f" % far.x)
	a.free()


func test_cb_suck_under_base() -> void:
	var r := _storm_atmo()
	var a: Atmosphere = r[0]
	var th: AtmoThermal = r[1]
	var cb := a.get_cloudbase_msl()
	var ax := th.axis_at(cb - 40.0)
	var w_suck := a.air_velocity_at(Vector3(ax.x, cb - 40.0, ax.y)).y
	var ax2 := th.axis_at(cb * 0.4)
	var w_mid := a.air_velocity_at(Vector3(ax2.x, cb * 0.4, ax2.y)).y
	check(w_suck > w_mid, "под основанием Cb подсос сильнее: %.2f > %.2f" % [w_suck, w_mid])
	a.free()


func test_storm_preset_makes_cb() -> void:
	var a := _atmo({}, "weather/storm")
	a.set_ground(_flat, _sun)
	a.step(0.01)
	var n := 0
	for id in a.field.thermals:
		if a.field.thermals[id].is_cb:
			n += 1
	check(n > 0, "в грозовой день есть Cb: %d" % n)
	a.free()


func test_lee_wave_crest_lift() -> void:
	var a := _atmo({"thermal_mode": "static"}, "weather/wave")
	a.set_ground(_ridge, _sun)
	a.step(0.01)
	check(a.wave.enabled, "волна включена")
	var lam := a.wave.wavelength()
	check(lam > 3000.0 and lam < 20000.0, "длина волны правдоподобна: %.0f м" % lam)
	# Вдоль ветра (+X) за хребтом на высоте 1,5 км над гребнем — есть и подъём, и опускание.
	var y := 500.0 + RIDGE_H + 1500.0
	var w_max := -1.0e9
	var w_min := 1.0e9
	var x_max := 0.0
	for i in 120:
		var x := 1000.0 + i * 150.0
		var w := a.air_velocity_at(Vector3(x, y, 0.0)).y
		if w > w_max:
			w_max = w
			x_max = x
		w_min = minf(w_min, w)
	var bg := float(a.weather.background_sink_ms)
	check(w_max > bg + 1.0, "в гребне волны подъём: %.2f м/с на x = %.0f" % [w_max, x_max])
	check(w_min < bg - 0.5, "в ложбине опускание: %.2f" % w_min)
	# Высоко над волной поток слабее.
	var w_high := a.air_velocity_at(Vector3(x_max, y + 12000.0, 0.0)).y
	check(absf(w_high - bg) < absf(w_max - bg) * 0.5, "с высотой волна гаснет")
	# Лентикулярные облака: гребни η найдены.
	var cr := a.wave.crests(Vector3(8000, 0, 0), 12000.0, 50.0)
	check(not cr.is_empty(), "гребни волн (лентикуляры) найдены: %d" % cr.size())
	a.free()


func test_no_wave_without_preset() -> void:
	var a := _atmo({"thermal_mode": "static"}, "weather/medium")
	a.set_ground(_ridge, _sun)
	a.step(0.01)
	check(not a.wave.enabled, "в обычный день волн нет")
	a.free()
