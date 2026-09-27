extends TestCase
## Калибровка погоды (карточка 03, входные данные A07): сила термиков по дням, снос термика
## ветром целиком (одна позиция для подъёма и облака, VR-0), источники на триггерах у стартов.

## Полоса «гребня» в синтетическом рельефе: |x| < _RIDGE_HALF_M — сильный источник.
const _RIDGE_HALF_M := 60.0
const _SUN_RIDGE := 1.0
const _SUN_PLAIN := 0.5


func _atmo(preset: String, weather_over: Dictionary = {}, seed_v: int = 20) -> Atmosphere:
	var a := Atmosphere.new()
	var acfg := Config._deep_merge(Config.get_config("atmosphere"), {"seed": seed_v})
	var w := Config._deep_merge(Config.get_config(preset), weather_over)
	a.configure(acfg, w)
	a.turbulence_enabled = false
	a.set_ground(_flat, _sun_flat)
	return a


static func _flat(_x: float, _z: float) -> float:
	return 0.0


static func _sun_flat(_x: float, _z: float) -> float:
	return 1.0


## Гребень вдоль Z (x ≈ 0): скалы/опушка — сильный источник, равнина — средний.
static func _sun_ridge(x: float, _z: float) -> float:
	return _SUN_RIDGE if absf(x) < _RIDGE_HALF_M else _SUN_PLAIN


## Все термики, родившиеся за hours_s в квадрате ±half_m — прямо из генератора клеток.
func _births(a: Atmosphere, hours_s: float, half_m: float) -> Array[AtmoThermal]:
	var f := a.field
	var n := int(ceil(half_m / f._spacing))
	var out: Array[AtmoThermal] = []
	for ic in range(-n, n + 1):
		for ia in range(-n, n + 1):
			var pp := f._cell_params(ia, ic)
			var cyc := 0
			while true:
				var t_start := cyc * pp.x - pp.y
				if t_start >= hours_s:
					break
				if t_start >= 0.0:
					var th := f._spawn(ia, ic, f._mix(ia, ic, cyc) | 1, t_start, pp.x)
					if th != null:
						out.append(th)
				cyc += 1
	return out


func _mean_strength(preset: String) -> float:
	var a := _atmo(preset)
	a.step(0.01)
	var born := _births(a, 7200.0, 6000.0)
	var s := 0.0
	for th in born:
		s += th.strength
	a.free()
	return s / float(maxi(born.size(), 1))


# ---------------------------------------------------------------- 1. Сила термиков по дням


func test_thermal_strength_by_day() -> void:
	# A07: средний день — подъём у оси ≈ 2,3–2,5 м/с на рабочих высотах (идеальный пилот при
	# снижении на вираже ≈ 1,2 м/с набирает ≥ +1); слабый — трудный; сильный — сильнее среднего.
	var weak := _mean_strength("weather/weak")
	var medium := _mean_strength("weather/medium")
	var strong := _mean_strength("weather/strong")
	check(medium >= 2.2 and medium <= 3.2, "medium: средняя сила ядра 2,2–3,2 м/с: %.2f" % medium)
	check(weak < medium - 0.5, "weak слабее medium: %.2f < %.2f" % [weak, medium])
	check(weak >= 0.9, "weak: термики держат крыло (>= 0,9 м/с): %.2f" % weak)
	check(strong > medium + 0.3, "strong сильнее medium: %.2f > %.2f" % [strong, medium])
	check(strong <= 5.0, "strong: средняя сила ядра в рамках FR-11 (<= 5 м/с): %.2f" % strong)


func test_medium_lift_at_working_height() -> void:
	# Подъём воздуха на оси зрелого термика на половине высоты слоя: медиана >= 2,2 м/с.
	var a := _atmo("weather/medium", {"wind_speed_kmh": 0.0})
	a.step(0.01)
	var born := _births(a, 3600.0, 3000.0)
	var ws: Array[float] = []
	for th in born:
		if ws.size() >= 40:
			break
		var t := th.t_birth + th.t_grow + th.t_mature * 0.5
		a.field.thermals.clear()
		a.field.thermals[th.id] = th
		a.field._rebuild_buckets(t, th.src, 1.0)
		var y := th.src.y + (th.top - th.src.y) * 0.5
		var axis := th.axis_at(y)
		ws.append(a.air_velocity_at(Vector3(axis.x, y, axis.y)).y)
	ws.sort()
	var med := ws[int(ws.size() * 0.5)] if not ws.is_empty() else 0.0
	check(ws.size() >= 20, "medium: зрелых термиков для замера >= 20: %d" % ws.size())
	check(med >= 2.2, "medium: медиана подъёма на оси на 0,5 слоя >= 2,2 м/с: %.2f" % med)
	a.free()


# ---------------------------------------------------------------- 2. Снос ветром целиком


func test_thermal_drifts_with_wind_as_a_whole() -> void:
	var a := _atmo("weather/medium", {"wind_speed_kmh": 15.0, "wind_from_deg": 270.0})
	a.step(0.01)
	var born := _births(a, 3600.0, 3000.0)
	check(not born.is_empty(), "термики рождаются")
	if born.is_empty():
		a.free()
		return
	var th: AtmoThermal = born[0]
	var tcfg: Dictionary = a.cfg.thermal
	var f := float(tcfg.drift_factor)
	var span := th.top - th.src.y
	var wmid := a.field.wind.vec2_at(span * 0.5)
	check(wmid.x > 3.0, "ветер с запада дует на восток: %s" % wmid)
	approx(th.drift_vel.x, wmid.x * f, 0.01, "скорость сноса = drift_factor × ветер середины")
	check(
		th.lean.length() <= wmid.length() * (1.0 - f) / 1.0 + 1.0e-4,
		"наклон — только от остатка (1 − drift_factor): %.3f" % th.lean.length()
	)
	# До отрыва основание над источником, после — уходит по ветру вместе с облаком.
	var t0 := th.drift_start()
	approx(th.drift_start() - th.t_birth, float(tcfg.drift_delay_s), 1.0e-3, "отрыв от источника")
	th.update_time(t0 - 1.0)
	approx(th.axis_at(th.src.y).x, th.src.x, 1.0e-3, "до отрыва основание над источником")
	var t1 := t0 + 300.0
	th.update_time(t1)
	var base := th.axis_at(th.src.y)
	approx(base.x - th.src.x, th.drift_vel.x * 300.0, 0.5, "за 5 мин основание снесено по ветру")
	# VR-0: облако — над верхом того же столба, что и подъём.
	var top_axis := th.axis_at(th.top)
	var cc := th.cloud_center(t1)
	check(top_axis.distance_to(cc) < 0.5, "облако над верхом столба: %s vs %s" % [top_axis, cc])
	# Пилот, кружа на 800 м, уносится ветром этой высоты; ось уходит почти так же — за минуту
	# расхождение меньше радиуса ядра (раньше столб стоял, пилота выносило на u·60 ≈ 400 м).
	var y := th.src.y + 800.0
	var u := a.field.wind.vec2_at(800.0).x
	var t2 := t1 + 60.0
	th.update_time(t2)
	var axis_move := th.axis_at(y).x - base.x - th.lean.x * 800.0
	var rel := absf(u * 60.0 - axis_move)
	check(rel < th.radius, "пилот не выносится из ядра за 1 мин: %.0f м < R %.0f м" % [rel, th.radius])
	a.free()


func test_static_thermal_stays_over_source() -> void:
	var a := _atmo(
		"weather/medium", {"thermal_mode": "static", "wind_speed_kmh": 15.0, "wind_from_deg": 270.0}
	)
	var id := a.add_static_thermal(0.0, 0.0, 3.0, 100.0)
	a.step(0.01)
	a.step(600.0)
	var th: AtmoThermal = a.field.thermals[id]
	approx(th.axis_at(th.src.y).x, 0.0, 1.0e-3, "статичный (MVP) стоит над источником")
	check(th.lean.x > 0.0, "статичный наклонён ветром")
	a.free()


# ---------------------------------------------------------------- 3. Источники у стартов


func test_sources_prefer_ridge_triggers() -> void:
	var a := _atmo("weather/medium", {"wind_speed_kmh": 0.0})
	a.set_ground(_flat, _sun_ridge)
	a.step(0.01)
	var sp := a.field._spacing
	var born := _births(a, 7200.0, 8000.0)
	var on_ridge := 0
	var ridge_cells := 0
	var plain_cells := 0
	for th in born:
		if absf(th.src.x) < _RIDGE_HALF_M:
			on_ridge += 1
		# Клетки, пересекающие гребень (x ∈ [−sp, sp]) и далёкие от него (|x| > 2·sp).
		if absf(th.src.x) < sp:
			ridge_cells += 1
		elif absf(th.src.x) > 2.0 * sp:
			plain_cells += 1
	# Без ветра ось c клеток — вдоль −X: у гребня 2 столбца клеток, между ними и «равниной» —
	# ещё по одному с каждой стороны; «равнинные» — остальные.
	var n := int(ceil(8000.0 / sp))
	var cols_plain := 2 * n + 1 - 4
	var per_ridge := float(ridge_cells) / 2.0
	var per_plain := float(plain_cells) / float(maxi(cols_plain, 1))
	check(
		float(on_ridge) >= 0.55 * float(ridge_cells),
		"у гребня источник садится на гребень: %d из %d" % [on_ridge, ridge_cells]
	)
	check(
		per_ridge >= 1.4 * per_plain,
		"гребень даёт термики чаще равнины: %.1f vs %.1f на столбец" % [per_ridge, per_plain]
	)
	a.free()


func test_thermal_within_3km_after_start() -> void:
	# С гребня-старта в любой момент дня (каждые 2 мин за 2 ч) в 3 км есть зрелый термик.
	for preset in ["weather/medium", "weather/strong"]:
		var a := _atmo(preset, {"wind_speed_kmh": 15.0, "wind_from_deg": 270.0})
		a.set_ground(_flat, _sun_ridge)
		a.step(0.01)
		var born := _births(a, 7200.0, 6000.0)
		var ok := 0
		var total := 0
		var start := Vector2(0.0, 0.0)
		var smin := float(Config.get_config(preset).thermal_strength_ms[0])
		for k in range(10, 60):
			var t := float(k) * 120.0
			total += 1
			for th in born:
				if th.envelope(t) < 0.7 or th.strength < smin:
					continue
				th.update_time(t)
				var p := th.axis_at(th.src.y + 300.0)
				if p.distance_to(start) <= 3000.0:
					ok += 1
					break
		check(
			ok >= int(0.9 * total),
			"%s: зрелый термик в 3 км от старта в >= 90%% моментов: %d/%d" % [preset, ok, total]
		)
		a.free()
