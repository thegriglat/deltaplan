extends TestCase
## Слова пилота в числах (questions.md «Облака», FR-11, FR-14b, FR-15): подсос, «затянет и
## выкинет», можно уйти, «+8 надо валить», термики без облаков, фон и кольцо.

const Sim := preload("res://tests/flight/flight_sim.gd")

const _BASE_STRENGTH := 4.0
const _BASE_RADIUS := 130.0


# ---------------------------------------------------------------- атмосфера-хелперы


func _atmo(
	seed_v: int, weather_over: Dictionary = {}, preset: String = "weather/strong"
) -> Atmosphere:
	var a := Atmosphere.new()
	var acfg := Config._deep_merge(Config.get_config("atmosphere"), {"seed": seed_v})
	var w := Config._deep_merge(Config.get_config(preset), weather_over)
	a.configure(acfg, w)
	a.set_ground(func(_x: float, _z: float) -> float: return 0.0,
		func(_x: float, _z: float) -> float: return 1.0)
	return a


func _cloud_atmo(seed_v: int, stage: Vector3 = Vector3(-1, 0, 0)) -> Atmosphere:
	var a := _atmo(seed_v, {"thermal_mode": "static", "wind_speed_kmh": 0.0})
	var id := a.add_static_thermal(0.0, 0.0, _BASE_STRENGTH, _BASE_RADIUS)
	if stage.x >= 0.0:
		a.cloud_phys.model.stage_override[id] = stage
	a.step(1.0)
	return a


func _mean_rise(a: Atmosphere, y0: float, y1: float, n: int) -> float:
	var s := 0.0
	for i in n:
		var y := lerpf(y0, y1, float(i) / float(n - 1))
		s += a.air_velocity_at(Vector3(0, y, 0)).y
	return s / float(n)


## Круговой полёт с фиксированным креном (простой держатель виража); возвращает время (с)
## первого превышения базы облаков, либо -1, если за seconds базу не превысили.
## Держатель виража — простой П-регулятор крена (без него несимметричный подъём в ядре
## сам раскручивает крен в спираль — FR-8, test_asymmetric_lift_rolls_wing).
func _fly_until_above(m: FlightModel, a: Atmosphere, bank_deg: float, seconds: float) -> float:
	m.bank = deg_to_rad(bank_deg)
	var target := deg_to_rad(bank_deg)
	var dt := 1.0 / 20.0  # крупнее Sim.DT — держатель виража устойчив, тесты на 3-5 минут дешевле
	var n := int(round(seconds / dt))
	var air := Callable(a, "air_velocity_at")
	var cb := a.get_cloudbase_msl()
	for i in n:
		var roll := clampf((target - m.bank) * 3.0, -1.0, 1.0)
		m.step(dt, Sim.input(0.0, roll), air, Callable())
		if m.position.y > cb:
			return float(i + 1) * dt
	return -1.0


func _peak_load_circling(a: Atmosphere, pos: Vector3, seconds: float = 15.0) -> float:
	var m := Sim.make("sport")
	m.reset_in_air(pos, 0.0)
	var target := deg_to_rad(28.0)
	m.bank = target
	m.load.reset()
	var air := Callable(a, "air_velocity_at")
	var n := int(round(seconds / Sim.DT))
	for i in n:
		var roll := clampf((target - m.bank) * 3.0, -1.0, 1.0)
		m.step(Sim.DT, Sim.input(0.0, roll), air, Callable())
	return m.load.load_max


# ---------------------------------------------------------------- 1. Подсос


func test_suck_layer_under_mature_cloud() -> void:
	var a := _cloud_atmo(1)
	var cb := a.get_cloudbase_msl()
	var layer := _mean_rise(a, cb - 150.0, cb, 5)
	var mid := a.air_velocity_at(Vector3(0, cb * 0.5, 0)).y
	check(
		layer >= mid * 1.3,
		"под крупным зрелым облаком слой у базы >= 1.3x середины: %.2f >= %.2f" % [layer, mid * 1.3]
	)
	var m := Sim.make("sport")
	m.reset_in_air(Vector3(0, cb - 150.0, 0), 0.0)
	var t_enter := _fly_until_above(m, a, 28.0, 180.0)
	check(
		t_enter >= 0.0,
		"крыло в ядре крупного облака входит в облако за <= 3 мин: %.0f с" % maxf(t_enter, 0.0)
	)
	a.free()


func test_no_suck_under_young_or_decaying_cloud() -> void:
	for st in [Vector3(0.3, 0.0, 1.0), Vector3(1.0, 0.7, 0.2)]:
		var a := _cloud_atmo(2, st)
		var cb := a.get_cloudbase_msl()
		var layer := _mean_rise(a, cb - 150.0, cb, 5)
		var mid := a.air_velocity_at(Vector3(0, cb * 0.5, 0)).y
		check(
			layer <= mid * 1.0,
			"стадия %s: у базы не сильнее середины: %.2f <= %.2f" % [st, layer, mid]
		)
		var m := Sim.make("sport")
		m.reset_in_air(Vector3(0, cb - 150.0, 0), 0.0)
		var t_enter := _fly_until_above(m, a, 28.0, 300.0)
		check(t_enter < 0.0, "стадия %s: не входит в облако за 5 мин" % st)
		a.free()


# ---------------------------------------------------------------- 2. «Выкинет»


func test_ejected_from_cloud_within_90s() -> void:
	var successes := 0
	for s in range(10):
		var a := _cloud_atmo(100 + s)
		a.turbulence_enabled = true
		var cb := a.get_cloudbase_msl()
		var m := Sim.make("sport")
		m.reset_in_air(Vector3(0, cb + 150.0, 0), 0.0)
		var air := Callable(a, "air_velocity_at")
		var n := int(round(90.0 / Sim.DT))
		var exited := false
		for i in n:
			m.step(Sim.DT, Sim.input(), air, Callable())
			if a.cloud_density_at(m.position) < 0.1:
				exited = true
				break
		if exited:
			successes += 1
		a.free()
	check(successes >= 8, "выходит из облака за 90 с в >= 8/10 сидах: %d/10" % successes)


func test_cloud_chaos_sigma_and_load_peak() -> void:
	var a := _cloud_atmo(3)
	a.turbulence_enabled = true
	var cb := a.get_cloudbase_msl()
	var sig_in := a.turbulence_intensity_at(Vector3(150, cb + 200, 30))
	var sig_out := a.turbulence_intensity_at(Vector3(3000, cb - 500, 0))
	check(sig_in >= 3.0, "σ вертикального воздуха в облаке >= 3 м/с: %.2f" % sig_in)
	check(sig_out <= 1.5, "σ вне облака на той же высоте <= 1,5 м/с: %.2f" % sig_out)
	var peak_cloud := _peak_load_circling(a, Vector3(0, cb + 200.0, 0))
	var peak_clear := _peak_load_circling(a, Vector3(3000.0, cb - 500.0, 0))
	check(
		peak_cloud >= peak_clear * 1.5,
		"пик перегрузки в облаке >= 1.5x пика в ясном воздухе: %.2f >= %.2f"
			% [peak_cloud, peak_clear * 1.5]
	)
	a.free()


# ---------------------------------------------------------------- 3. Уйти можно


func test_can_escape_pulling_away_from_base() -> void:
	var successes := 0
	for s in range(10):
		var a := _cloud_atmo(200 + s)
		a.turbulence_enabled = true
		var cb := a.get_cloudbase_msl()
		var m := Sim.make("sport")
		m.reset_in_air(Vector3(0, cb - 150.0, 0), 90.0)  # курс на восток, прочь от источника
		var air := Callable(a, "air_velocity_at")
		var dt := 1.0 / 20.0
		var n := int(round(45.0 / dt))
		var entered := false
		for i in n:
			m.step(dt, Sim.input(-0.7), air, Callable())  # трапеция на себя — разгон прочь
			if m.position.y > cb:
				entered = true
				break
		if not entered:
			successes += 1
		a.free()
	check(
		successes >= 8,
		"трапеция на себя + курс прочь — не входит в облако: >= 8/10: %d/10" % successes
	)


# ---------------------------------------------------------------- 4. «+8 надо валить»


## Все термики, рождающиеся за hours_s в клетках (ia, ic), — напрямую из генератора клеток
## (без реального времени и полёта — статистика по 20×20 км за 2 ч).
func _cell_births(f: ThermalField, ia: int, ic: int, hours_s: float) -> Array[AtmoThermal]:
	var out: Array[AtmoThermal] = []
	var pp := f._cell_params(ia, ic)
	var period: float = pp.x
	var phase: float = pp.y
	var cyc := 0
	while true:
		var t_start := cyc * period - phase
		if t_start >= hours_s:
			break
		if t_start >= 0.0:
			var id := f._mix(ia, ic, cyc) | 1
			var th := f._spawn(ia, ic, id, t_start, period)
			if th != null:
				out.append(th)
		cyc += 1
	return out


func _all_births(a: Atmosphere, hours_s: float, half_m: float) -> Array[AtmoThermal]:
	var f := a.field
	var n := int(ceil(half_m / f._spacing))
	var out: Array[AtmoThermal] = []
	for ic in range(-n, n + 1):
		for ia in range(-n, n + 1):
			out.append_array(_cell_births(f, ia, ic, hours_s))
	return out


func test_extreme_thermals_rare_and_only_strong() -> void:
	var a := _atmo(10, {}, "weather/strong")
	a.step(0.01)
	var born := _all_births(a, 7200.0, 10000.0)
	var extreme := 0
	for th in born:
		if th.strength >= 7.0:
			extreme += 1
			var diam := 2.0 * minf(a.cloud_phys.model.size(th, Vector3(1, 0, 1)).x,
				a.cloud_phys.model.size(th, Vector3(1, 0, 1)).y)
			check(th.has_cloud, "под термиком >= 7 м/с — облако")
			check(diam >= float(a.cfg.thermal.suck_size_m[1]),
				"под термиком >= 7 м/с — крупное облако (диаметр %.0f м)" % diam)
	var frac := float(extreme) / float(maxi(born.size(), 1))
	check(
		frac >= 0.02 and frac <= 0.06,
		"strong: доля термиков с ядром >= 7 м/с 2-6%%: %.3f (%d/%d)" % [frac, extreme, born.size()]
	)
	a.free()
	for preset in ["weather/medium", "weather/weak"]:
		var b := _atmo(11, {}, preset)
		b.step(0.01)
		var born2 := _all_births(b, 7200.0, 10000.0)
		var ext2 := 0
		for th in born2:
			if th.strength >= 7.0:
				ext2 += 1
		check(ext2 == 0, "%s: термиков с ядром >= 7 м/с нет: %d" % [preset, ext2])
		b.free()


func test_variometer_plus8_reachable_in_extreme_core() -> void:
	var a := _cloud_atmo(4)
	a.field.thermals[a.field.thermals.keys()[0]].strength = 8.0
	a.step(1.0)
	var cb := a.get_cloudbase_msl()
	var w := a.air_velocity_at(Vector3(0, cb - 60.0, 0)).y
	check(w >= 7.0, "вариометр >= +7 м/с у крыла в ядре 8 м/с: %.2f" % w)
	a.free()


# ---------------------------------------------------------------- 5. Термики без облаков


func test_dry_thermal_fraction_and_climb() -> void:
	for row in [["weather/medium", 0.15, 0.35], ["weather/weak", 0.40, 1.01]]:
		var preset: String = row[0]
		var a := _atmo(12, {}, preset)
		a.turbulence_enabled = false
		a.step(0.01)
		var born := _all_births(a, 7200.0, 10000.0)
		var dry := 0
		var dry_th: AtmoThermal = null
		for th in born:
			if not th.has_cloud:
				dry += 1
				if dry_th == null or th.strength > dry_th.strength:
					dry_th = th
		var frac := float(dry) / float(maxi(born.size(), 1))
		check(
			frac >= float(row[1]) and frac <= float(row[2]),
			"%s: доля сухих термиков %.2f-%.2f: %.3f (%d/%d)"
				% [preset, row[1], row[2], frac, dry, born.size()]
		)
		if dry_th != null:
			# Найденный «в стороне» термик не зарегистрирован в поле сетки поиска — вписать
			# его вручную, чтобы проверить реальный подъём через air_velocity_at.
			a.field.thermals[dry_th.id] = dry_th
			var t_mature := dry_th.t_birth + dry_th.t_grow + dry_th.t_mature * 0.5
			a.field._rebuild_buckets(t_mature, dry_th.src, 1.0)
			# Найден по варио — берём лучшую высоту в столбе (пилот ищет максимум набора).
			var w_max := -1.0e9
			for k in range(3, 9):
				var y := dry_th.src.y + (dry_th.top - dry_th.src.y) * (float(k) / 10.0)
				var axis := dry_th.axis_at(y)  # ось столба на высоте с учётом наклона ветром
				w_max = maxf(w_max, a.air_velocity_at(Vector3(axis.x, y, axis.y)).y)
			check(w_max >= 1.0, "%s: сухой термик даёт набор >= 1 м/с (по варио): %.2f" % [preset, w_max])
		a.free()


# ---------------------------------------------------------------- 6. Фон и кольцо


func test_background_sink_medium() -> void:
	var a := _atmo(13, {"thermal_mode": "static"}, "weather/medium")
	a.turbulence_enabled = false
	a.step(0.01)
	var w := a.air_velocity_at(Vector3(5000, 800, 5000)).y
	approx(w, -0.5, 0.15, "фон вне термиков medium −0,5 ± 0,15 м/с")
	a.free()


func test_ring_sink_weaker_than_core() -> void:
	var a := _cloud_atmo(14)
	a.turbulence_enabled = false
	var bg := a.air_velocity_at(Vector3(6000, 900, 0)).y  # фон вдали, без термика — для сравнения
	var ring_min := 1.0e9
	for i in range(20):
		var r := _BASE_RADIUS * (1.0 + 0.05 * i)
		ring_min = minf(ring_min, a.air_velocity_at(Vector3(r, 900, 0)).y)
	# Кольцо (Gedeon, thermal.ring_sink_factor — не моя секция) даёт доп. опускание сверх фона;
	# оно слабее −0,2·ядра сверх фона между термиками.
	var excess := ring_min - bg
	check(
		excess >= -0.2 * _BASE_STRENGTH,
		"кольцо опускания слабее −0,2·ядра сверх фона: %.2f >= %.2f"
			% [excess, -0.2 * _BASE_STRENGTH]
	)
	a.free()
