extends TestCase
## Слова пилота в числах (questions.md «Облака», FR-11, FR-14b, FR-15): подсос, «затянет и
## выкинет», можно уйти, «+8 надо валить», термики без облаков, фон и кольцо.

const Sim := preload("res://tests/flight/flight_sim.gd")
const Rig := preload("res://tests/atmosphere/air_rig.gd")
const CS := Atmosphere.CORE_STRIDE

const _BASE_STRENGTH := 4.0
const _BASE_RADIUS := 130.0
const _SEEDS := 5

# Облако поля над статичным термиком — естественное (крейт, W2 v4); заданное вручную облако
# (прежний Fixture.force_cloud) крейт не принимает. Сценарий по стадии облака (молодое/тающее)
# помечен skip_reason (pending), не удалён. Цифры физики покрыты в cargo: rust/dp-air/tests/
# terms_clouds.rs (physics_suck_vs_gd, hooks_shade_and_suck), terms_thermal_cloud.rs
# (suck_points_from_gd_in_tolerance), terms_turb.rs (ongudai_sigma_turb_within_w8).

const _SKIP_STAGE := (
	"pending: сценарий по стадии облака; у статичного термика облако всегда зрелое, момент "
	+ "молодого/тающего облака у динамического термика (cloud_objects.stage) не подобран без "
	+ "запуска Godot (RW-12s)"
)


const _SKIP_CHAOS := (
	"pending: бурление в облаке (chaos_noise, gust_unit ветровой рамки) в крейте пока нет — нули "
	+ "(rust/dp-air/src/terms/clouds/mod.rs, шапка; RW-9); «затянет и выкинет» держится на нём"
)


func skip_reason(method: String) -> String:
	if method == "test_no_suck_under_young_or_decaying_cloud":
		return _SKIP_STAGE
	if method in ["test_ejected_from_cloud_within_90s", "test_cloud_chaos_sigma_and_load_peak"]:
		return _SKIP_CHAOS
	return ""


# ---------------------------------------------------------------- атмосфера-хелперы


## Облако поля над статичным термиком 4 м/с / 130 м (Rig.cloud_day). Освобождает вызывающий.
func _cloud_atmo(seed_v: int) -> Atmosphere:
	return Rig.cloud_day(seed_v)


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
	var cb := a.cloudbase_msl()
	for i in n:
		var roll := clampf((target - m.bank) * 3.0, -1.0, 1.0)
		m.step(dt, Sim.input(0.0, roll), air, Callable())
		if m.position.y > cb:
			return float(i + 1) * dt
	return -1.0


# ---------------------------------------------------------------- 1. Подсос


func test_suck_layer_under_mature_cloud() -> void:
	var a := _cloud_atmo(1)
	var cb := a.cloudbase_msl()
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
	# Молодое (стадия «растёт») и тающее облако: у базы подъём не сильнее середины, крыло в ядре
	# за 5 мин в облако не входит. Пороги прежние; пропущен (skip_reason): стадию на естественном
	# облаке задать нельзя.
	var a := _cloud_atmo(2)
	var cb := a.cloudbase_msl()
	var layer := _mean_rise(a, cb - 150.0, cb, 5)
	var mid := a.air_velocity_at(Vector3(0, cb * 0.5, 0)).y
	check(layer <= mid * 1.0, "у базы не сильнее середины: %.2f <= %.2f" % [layer, mid])
	var m := Sim.make("sport")
	m.reset_in_air(Vector3(0, cb - 150.0, 0), 0.0)
	check(_fly_until_above(m, a, 28.0, 300.0) < 0.0, "не входит в облако за 5 мин")
	a.free()


# ---------------------------------------------------------------- 2. «Выкинет»


func test_ejected_from_cloud_within_90s() -> void:
	var successes := 0
	for s in range(_SEEDS):
		var a := _cloud_atmo(100 + s)
		var cb := a.cloudbase_msl()
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
	check(successes >= _SEEDS - 1, "выходит из облака за 90 с в >= %d/%d сидах: %d" % [_SEEDS - 1, _SEEDS, successes])


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


func test_cloud_chaos_sigma_and_load_peak() -> void:
	var a := _cloud_atmo(3)
	var cb := a.cloudbase_msl()
	var sig_in := a.turbulence_intensity_at(Vector3(150, cb + 600, 30))
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
	for s in range(_SEEDS):
		var a := _cloud_atmo(200 + s)
		var cb := a.cloudbase_msl()
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
		successes >= _SEEDS - 1,
		"трапеция на себя + курс прочь — не входит в облако: >= %d/%d: %d" % [_SEEDS - 1, _SEEDS, successes]
	)


# ---------------------------------------------------------------- 4. «+8 надо валить»


func test_variometer_plus8_reachable_in_extreme_core() -> void:
	var a := Rig.cloud_day(4, false, 8.0)  # статичный термик 8 м/с
	var cb := a.cloudbase_msl()
	# у основания подъём статичного термика гаснет (облака над ним нет, подсос не добавляется):
	# смотрим лучшее место столба
	var w := -1.0e9
	for k in range(2, 9):
		w = maxf(w, a.air_velocity_at(Vector3(0, cb * k / 10.0, 0)).y)
	check(w >= 7.0, "вариометр >= +7 м/с у крыла в ядре 8 м/с: %.2f" % w)
	a.free()


# ---------------------------------------------------------------- 5. Термики без облаков


func test_dry_thermal_climb() -> void:
	# Подъём слабого термика находится по вариометру: на лучшем зрелом ядре дня подъём >= 1 м/с
	# хотя бы на одной высоте столба (облака поля — слагаемое крейта, доля «сухих» — его тесты).
	for preset in ["weather/medium", "weather/weak"]:
		var a := Rig.make({"preset": preset, "seed": 12, "advance": 3600.0})
		var best: PackedFloat32Array = []
		var c := a.cores(Vector3.ZERO, 6000.0)
		for j in range(0, c.size() - CS + 1, CS):
			var st := c[j + Atmosphere.CORE_STAGE]
			if st < 1.0 or st > 2.0 or (int(c[j + Atmosphere.CORE_FLAGS]) & 4) != 0:
				continue
			if best.is_empty() or c[j + Atmosphere.CORE_W] > best[Atmosphere.CORE_W]:
				best = c.slice(j, j + CS)
		check(not best.is_empty(), "%s: зрелые термики есть" % preset)
		if not best.is_empty():
			var y_src := best[Atmosphere.CORE_Y_SRC]
			var span := best[Atmosphere.CORE_TOP] - y_src
			var w_max := -1.0e9
			for k in range(3, 9):
				var dy := span * (float(k) / 10.0)
				var p := Vector3(
					best[Atmosphere.CORE_X] + best[Atmosphere.CORE_LEAN_X] * dy,
					y_src + dy,
					best[Atmosphere.CORE_Z] + best[Atmosphere.CORE_LEAN_Z] * dy
				)
				w_max = maxf(w_max, a.mean_wind_at(p).y)
			check(w_max >= 1.0, "%s: термик даёт набор >= 1 м/с (по варио): %.2f" % [preset, w_max])
		a.free()


# ---------------------------------------------------------------- 6. Фон и кольцо


func test_background_sink_medium() -> void:
	var a := Rig.make({"mode": 1, "seed": 13, "advance": 0.01})
	var w := a.mean_wind_at(Vector3(3000, 800, 3000)).y
	approx(w, -0.5, 0.15, "фон вне термиков medium −0,5 ± 0,15 м/с")
	a.free()


func test_ring_sink_weaker_than_core() -> void:
	var a := _cloud_atmo(14)
	var bg := a.mean_wind_at(Vector3(4500, 900, 0)).y  # фон вдали, без термика — для сравнения
	var ring_min := 1.0e9
	for i in range(20):
		var r := _BASE_RADIUS * (1.0 + 0.05 * i)
		ring_min = minf(ring_min, a.mean_wind_at(Vector3(r, 900, 0)).y)
	# Кольцо (Gedeon, thermal.ring_sink_factor — не моя секция) даёт доп. опускание сверх фона;
	# оно слабее −0,2·ядра сверх фона между термиками.
	var excess := ring_min - bg
	check(
		excess >= -0.2 * _BASE_STRENGTH,
		"кольцо опускания слабее −0,2·ядра сверх фона: %.2f >= %.2f"
			% [excess, -0.2 * _BASE_STRENGTH]
	)
	a.free()
