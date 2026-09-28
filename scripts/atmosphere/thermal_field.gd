class_name ThermalField
extends RefCounted
## Термики вокруг пилота: детерминированная генерация по клеткам, жизненный цикл,
## сетка быстрого поиска (бакеты) и профиль подъёма (Gedeon по радиусу, Allen по высоте).
##
## Мир разбит на клетки со стороной thermal_spacing_m в системе координат, повёрнутой по ветру
## (ось a — по ветру, c — поперёк). У каждой клетки свой период и фаза; в каждом цикле термик
## рождается или нет (освещённость источника, доля duty). Всё — чистые функции (клетка, цикл):
## погода, солнце, кромка и тень облаков берутся на момент рождения термика (day — AtmoDay), тень —
## от «голых» (без тени) термиков соседних клеток, без рекурсии. Поэтому день воспроизводим, не
## зависит от пути пилота и шага времени, и его можно начать сразу с любого момента (сеть, NET-00).

const _KEY_OFFSET := 1 << 20
## Плавность границы оторвавшегося низа термика, м (форма, не параметр погоды).
const _CUT_BLEND_M := 60.0
const _THIRD := 1.0 / 3.0
## Allen: радиус ∝ ξ^(1/3)·(1 − 0,25ξ); при ξ = 1 это 0,75 — нормируем, чтобы у верха был R.
const _ALLEN_NORM := 1.0 / 0.75
const _P_STRIDE := 13
const _KEY_MUL := 1 << 21
## Тень облака ищется у источников не дальше этого (снос + наклон столба), м — дальние
## уплывшие облака тени не дают (упрощение: окно поиска конечное и не зависит от истории).
const _SHADE_REACH_M := 6000.0
## Смещение тени от солнца не больше этого, м (низкое солнце).
const _SHADE_SUN_REACH_M := 4000.0

var thermals: Dictionary = {}  ## id -> AtmoThermal (все живые, включая статичные)
var cloudbase_msl: float = 1500.0
var mode: String = "dynamic"  ## dynamic | static | both
## Сколько живёт облако после конца термика (термик держим в списке до этого момента), с.
var cloud_linger_s: float = 0.0
## Размер облака от силы термика (для теней облаков на источниках), м.
var cloud_width_per_ms: float = 300.0
var cloud_width_min: float = 350.0
var cloud_width_max: float = 1800.0
## Облака в физике (подсос, поток в облаке); задаёт Atmosphere.
var cloud_phys: CloudPhysics
## Доля солнечного прогрева земли (перистая пелена её снижает), 0..1.
var insolation: float = 1.0
## Направление на солнце (для теней облаков).
var sun_dir: Vector3 = Vector3(0.0, 1.0, 0.0)
## День (погода, солнце, источники по времени) — задаёт Atmosphere.set_day; null — всё постоянно.
var day: AtmoDay
## Средняя высота земли (отсчёт кромки) и не задана ли кромка явно — для кромки по дню.
var cloudbase_ref: float = 0.0
var cloudbase_fixed: bool = false
## Доля солнца, которую гасит перистая пелена при покрытии 1 (cirrus.sun_block).
var cirrus_block: float = 0.0
## Диаметр облака на 1 м/с без поправки погоды (clouds.width_per_ms_m).
var cloud_width_per_ms_base: float = 300.0

var ground: GroundField
var wind: WindModel

var _cfg: Dictionary
var _w: Dictionary  ## погода
var _seed: int = 0
var _spacing: float = 2000.0
var _gen_r: float = 20000.0
var _phys_r: float = 6000.0
var _bucket: float = 400.0
var _inv_bucket: float = 1.0 / 400.0
var _buckets: Dictionary = {}
var _active: Array[AtmoThermal] = []  ## термики в радиусе физики (обновляются каждый шаг)
var _tp: PackedFloat64Array = PackedFloat64Array()  ## их параметры подряд, по _P_STRIDE чисел
var _empty_cycles: Dictionary = {}  ## id цикла без термика -> до какого момента его помнить
## «Голые» термики (без тени облаков) — для тени при рождении: id -> AtmoThermal, пустые циклы —
## id -> до какого момента помнить.
var _bare: Dictionary = {}
var _bare_empty: Dictionary = {}
var _prune_t: float = -1.0e18
## Клетка -> Vector2i(цикл, номер обновления), когда её последний раз обходили (_generate).
var _cell_seen: Dictionary = {}
var _gen_stamp: int = 0
var _statics: Array[AtmoThermal] = []
var _cells: Dictionary = {}  ## ключ клетки -> Vector2(период, фаза)
var _static_next_id: int = -1

# Профиль
var _ring: float = 1.6
var _cut2: float = 9.0
var _rmin: float = 0.45
var _ramp: float = 150.0
var _taper: float = 120.0
var _edge_k: float = 0.35
var _edge_w: float = 0.45
var _suck_depth: float = 250.0
var _in_cloud_mean: float = 0.25

# Ветер в системе клеток
var _ax: Vector2 = Vector2(0, 1)  ## ось a (по ветру)
var _cx: Vector2 = Vector2(-1, 0)  ## ось c (поперёк)
var _street: float = 0.0  ## 0..1 — сила выстраивания в улицы
var _street_spacing: float = 3000.0



func setup(
	thermal_cfg: Dictionary, weather: Dictionary, seed_value: int, g: GroundField, wm: WindModel
) -> void:
	_cfg = thermal_cfg
	_w = weather
	_seed = seed_value
	ground = g
	wind = wm
	_spacing = float(weather.thermal_spacing_m)
	_gen_r = float(thermal_cfg.generation_radius_m)
	_phys_r = float(thermal_cfg.physics_radius_m)
	_bucket = float(thermal_cfg.bucket_m)
	_inv_bucket = 1.0 / _bucket
	_ring = float(thermal_cfg.ring_sink_factor)
	var cut := float(thermal_cfg.profile_cutoff_radii)
	_cut2 = cut * cut
	_rmin = float(thermal_cfg.radius_min_factor)
	_ramp = float(thermal_cfg.ground_ramp_m)
	_taper = float(thermal_cfg.top_taper_m)
	_suck_depth = float(thermal_cfg.suck_depth_m)
	_in_cloud_mean = float(thermal_cfg.in_cloud_mean_frac)
	mode = String(weather.get("thermal_mode", "dynamic"))
	update_wind_frame()


func set_turbulence_params(edge_factor: float, edge_width: float) -> void:
	_edge_k = edge_factor
	_edge_w = edge_width


func get_edge_factor() -> float:
	return _edge_k


## Новая погода без пересоздания поля (ход дня без day): новые термики рождаются с её числами,
## живые доживают со старыми. Шаг сетки клеток (thermal_spacing_m) и ветер не меняются.
func set_weather_soft(weather: Dictionary) -> void:
	_w = weather
	var st := _street_for(_w)
	_street = st.x
	_street_spacing = st.y


## Кромка плавно сдвинулась (ход дня): новые термики — до новой кромки, живые динамические
## доживают со своей; статичные — пересчитать верх.
func set_cloudbase_soft(msl: float) -> void:
	cloudbase_msl = msl
	for th in _statics:
		th.top = maxf(cloudbase_msl, th.src.y + float(_cfg.min_depth_m))
		_apply_wind(th, _street)


## Сила улиц 0..1 и расстояние между ними, м, для погоды w (ветер — текущий).
func _street_for(w: Dictionary) -> Vector2:
	var street_min := float(_cfg.street_min_wind_ms)
	var street_full := float(_cfg.street_full_wind_ms)
	var s_ms := wind.speed_at(float(w.cloudbase_agl_m) * 0.5)
	var k := (
		float(w.get("street_strength", 0.0))
		* clampf((s_ms - street_min) / maxf(street_full - street_min, 0.01), 0.0, 1.0)
	)
	return Vector2(k, float(_cfg.street_spacing_factor) * float(w.cloudbase_agl_m))


## Пересчитать систему клеток и наклоны под текущий ветер. Динамические термики рождаются заново.
func update_wind_frame() -> void:
	var d := Vector2(wind.dir.x, wind.dir.z)
	if d.length_squared() < 1.0e-6:
		d = Vector2(0, 1)
	_ax = d.normalized()
	_cx = Vector2(-_ax.y, _ax.x)
	var st := _street_for(_w)
	_street = st.x
	_street_spacing = st.y
	# Динамические — заново, статичные — пересчитать наклон.
	var keep: Dictionary = {}
	for id in thermals:
		var th: AtmoThermal = thermals[id]
		if th.is_static:
			_apply_wind(th, _street)
			keep[id] = th
	thermals = keep
	_clear_dynamic_caches()
	_cells.clear()
	_buckets.clear()
	_active.clear()


## Забыть динамические термики и всё, что о них помнили (начать заново с любого момента).
func reset_dynamic() -> void:
	for id in thermals.keys():
		if not thermals[id].is_static:
			thermals.erase(id)
	_clear_dynamic_caches()
	_buckets.clear()
	_active.clear()


func _clear_dynamic_caches() -> void:
	_empty_cycles.clear()
	_bare.clear()
	_bare_empty.clear()
	_cell_seen.clear()
	_prune_t = -1.0e18


## Наклон ствола и снос ветром. Динамический термик через drift_delay_s после рождения отрывается
## от источника и дрейфует с воздухом (доля drift_factor от ветра на середине столба) — пилот,
## кружа, уходит с ним; наклон — только от остатка (1 − доля). Источник в следующем цикле клетки
## порождает новый пузырь. Статичный (MVP) стоит над источником, наклонён целиком.
func _apply_wind(th: AtmoThermal, street: float) -> void:
	var span := th.top - th.src.y
	var wmid := wind.vec2_at(span * 0.5)
	var rise := maxf(th.strength * float(_cfg.rise_factor), float(_cfg.rise_min_ms))
	var f := 0.0 if th.is_static else clampf(float(_cfg.get("drift_factor", 0.0)), 0.0, 1.0)
	var lean := wmid * (1.0 - f) / rise
	var max_lean := tan(deg_to_rad(float(_cfg.max_lean_deg)))
	if lean.length() > max_lean:
		lean = lean.normalized() * max_lean
	th.lean = lean
	if f > 0.0:
		th.drift_vel = wmid * f
		th.drift_delay = float(_cfg.get("drift_delay_s", 0.0))
	else:
		th.drift_vel = wind.vec2_at(span)
		th.drift_delay = -1.0
	th.cloud_stretch = 1.0 + float(_cfg.street_cloud_stretch) * street


func add_static(x: float, z: float, strength_ms: float, radius_m: float) -> AtmoThermal:
	var th := AtmoThermal.new()
	th.id = _static_next_id
	_static_next_id -= 1
	th.is_static = true
	th.noise_seed = hash(Vector2i(int(x), int(z)))
	var h := ground.height(x, z)
	th.src = Vector3(x, h, z)
	th.top = maxf(cloudbase_msl, h + float(_cfg.min_depth_m))
	th.strength = strength_ms
	th.radius = radius_m
	_setup_cloud(th, strength_ms, 0.0, _w)
	# Статичные (MVP) — всегда с облаком, если достаточно сильные.
	th.has_cloud = strength_ms >= float(_w.cloud_min_strength_ms)
	_apply_wind(th, _street)
	th.update_time(0.0)
	thermals[th.id] = th
	_statics.append(th)
	return th


func clear_static() -> void:
	for id in thermals.keys():
		if thermals[id].is_static:
			thermals.erase(id)
	_statics.clear()
	_buckets.clear()
	_active.clear()


## Кромка поменялась — верх статичных термиков пересчитать; динамические родятся заново.
func set_cloudbase(msl: float) -> void:
	cloudbase_msl = msl
	for id in thermals.keys():
		var th: AtmoThermal = thermals[id]
		if th.is_static:
			th.top = maxf(cloudbase_msl, th.src.y + float(_cfg.min_depth_m))
			_apply_wind(th, _street)
		else:
			thermals.erase(id)
	_clear_dynamic_caches()


## Очень сильный термик — широкий.
func rmax_extreme(r: float, w: Dictionary = {}) -> float:
	return maxf(r, float((_w if w.is_empty() else w).thermal_radius_m[1]))


func _setup_cloud(
	th: AtmoThermal, strength_ms: float, rnd: float, w: Dictionary, force_cloud: bool = false
) -> void:
	# Сухие («голубые») термики — без облака: их ищут только по вариометру. Термики «+8» —
	# всегда с крупным облаком (пилот: «по облакам идут — под ними большая скороподъёмность»).
	var dry := float(w.get("dry_thermal_fraction", 0.0))
	var rnd_dry := fposmod(rnd * 7.31 + 0.137, 1.0)
	th.has_cloud = force_cloud or (strength_ms >= float(w.cloud_min_strength_ms) and rnd_dry >= dry)
	var smax := float(w.thermal_strength_ms[1])
	var k := clampf(strength_ms / maxf(smax, 0.01), 0.0, 1.0)
	th.cloud_depth = float(w.cloud_depth_m) * (0.35 + 0.65 * k)
	th.overdevelop = 0.0
	if rnd < float(w.get("overdevelopment_chance", 0.0)) and k > 0.6:
		th.overdevelop = 1.0


# ---------------------------------------------------------------- генерация


func _cell_params(ia: int, ic: int) -> Vector2:
	var key := (ia + _KEY_OFFSET) * _KEY_MUL + (ic + _KEY_OFFSET)
	var v: Variant = _cells.get(key)
	if v != null:
		return v
	var rng := RandomNumberGenerator.new()
	rng.seed = _mix(ia, ic, 0x51F1)
	var lo := 0.0
	var hi := 0.0
	for k in ["grow_s", "mature_s", "decay_s", "gap_s"]:
		lo += float(_cfg[k][0])
		hi += float(_cfg[k][1])
	var period := rng.randf_range(lo, hi)
	var p := Vector2(period, rng.randf() * period)
	_cells[key] = p
	return p


func _mix(a: int, b: int, c: int) -> int:
	var h := _seed * 73856093
	h = (h ^ (a * 19349663)) & 0x7FFFFFFF
	h = (h * 31 + b * 83492791) & 0x7FFFFFFF
	h = (h * 31 + c * 2654435761) & 0x7FFFFFFF
	return h


## До какого момента после начала цикла (t_start) термик клетки может жить с облаком, с:
## обычный кончается до конца цикла, Cb (если в погоде его рождения грозы возможны) живёт дольше
## (зрелость × cb_mature_factor); облако тает ещё linger.
func _reach_of(t_start: float, period: float) -> float:
	var cb := float(_weather_at(t_start).get("cb_chance", 0.0)) > 0.0
	return period * (_cb_factor() if cb else 1.0) + cloud_linger_s


func _cb_factor() -> float:
	return maxf(float(_cfg.cb_mature_factor), 1.0)


func _weather_at(t: float) -> Dictionary:
	return day.weather_at(t) if day != null and day.has_weather() else _w


## Обновить набор термиков вокруг focus на момент t и перестроить сетку поиска.
func refresh(t: float, focus: Vector3, margin_s: float) -> void:
	# Удалить закончившиеся (облако тоже растаяло) и те, чья клетка вышла из круга генерации:
	# набор термиков — чистая функция (фокус, t), не зависит от пути пилота (сеть, NET-00).
	var linger := cloud_linger_s
	var fc := _focus_cell(focus)
	var r2 := _circle_r2()
	for id in thermals.keys():
		var th: AtmoThermal = thermals[id]
		if th.is_static:
			continue
		if t > th.t_end() + linger:
			thermals.erase(id)
			_empty_cycles[id] = th.cycle_forget
		elif float((th.cell - fc).length_squared()) > r2:
			thermals.erase(id)
	if mode != "static":
		_generate(t, focus)
		_prune(t)
	_rebuild_buckets(t, focus, margin_s)


## Клетка фокуса (a, c).
func _focus_cell(focus: Vector3) -> Vector2i:
	var f := Vector2(focus.x, focus.z)
	return Vector2i(floori(f.dot(_ax) / _spacing), floori(f.dot(_cx) / _spacing))


## Круг генерации в клетках: (радиус / шаг + 1)².
func _circle_r2() -> float:
	return (_gen_r / _spacing + 1.0) * (_gen_r / _spacing + 1.0)


func _generate(t: float, focus: Vector3) -> void:
	_gen_stamp += 1
	var fc := _focus_cell(focus)
	var n := int(ceil(_gen_r / _spacing))
	var ia0 := fc.x
	var ic0 := fc.y
	var r2 := _circle_r2()
	var cbf := _cb_factor()
	for dc in range(-n, n + 1):
		for da in range(-n, n + 1):
			if float(da * da + dc * dc) > r2:
				continue
			var ia := ia0 + da
			var ic := ic0 + dc
			var pp := _cell_params(ia, ic)
			var cycle := floori((t + pp.y) / pp.x)
			# Клетка была в круге и на прошлом обновлении, цикл тот же — всё уже рождено.
			var key := (ia + _KEY_OFFSET) * _KEY_MUL + (ic + _KEY_OFFSET)
			var seen: Variant = _cell_seen.get(key)
			_cell_seen[key] = Vector2i(cycle, _gen_stamp)
			if seen != null and seen.x == cycle and seen.y == _gen_stamp - 1:
				continue
			# Текущий цикл клетки и прежние, чей термик (Cb) или облако ещё живы: с «прыжка» в t
			# они должны быть те же, что при прогоне от 0.
			var k := 0
			while true:
				var cy := cycle - k
				var t_start := cy * pp.x - pp.y
				k += 1
				if k > 1:
					if t_start + pp.x * cbf + cloud_linger_s < t:
						break
					if t_start + _reach_of(t_start, pp.x) < t:
						continue
				_ensure(ia, ic, cy, t_start, pp.x, t)


## Термик цикла cy клетки (ia, ic) — в список живых, если он есть и ещё жив в момент t.
func _ensure(ia: int, ic: int, cy: int, t_start: float, period: float, t: float) -> void:
	var id := _mix(ia, ic, cy) | 1  # > 0: динамические
	if thermals.has(id) or _empty_cycles.has(id):
		return
	var th := _real_thermal(ia, ic, id, t_start, period)
	if th != null and t <= th.t_end() + cloud_linger_s:
		thermals[id] = th
	else:
		_empty_cycles[id] = t_start + _reach_of(t_start, period)


## Термик с тенью облаков: «голый» (без тени) и, если его источник в тени, — заново с тенью
## (тень только ослабляет: без тени не родился — с тенью тоже).
func _real_thermal(ia: int, ic: int, id: int, t_start: float, period: float) -> AtmoThermal:
	var bare := _bare_thermal(ia, ic, id, t_start, period)
	if bare == null:
		return null
	var shade := _shade_pure(Vector2(bare.src.x, bare.src.z), t_start, _env_at(t_start))
	if shade <= 0.0:
		return bare
	var th := _spawn(ia, ic, id, t_start, period, shade)
	if th != null:
		th.cycle_forget = bare.cycle_forget
	return th


## Погода, солнце, кромка и улицы на момент t (рождение термика): из day или текущие.
func _env_at(t: float) -> Dictionary:
	if day == null:
		return {
			"w": _w,
			"ins": insolation,
			"cb": cloudbase_msl,
			"street": Vector2(_street, _street_spacing),
			"sun": sun_dir,
			"wpm": cloud_width_per_ms,
		}
	var w: Dictionary = day.weather_at(t) if day.has_weather() else _w
	var ins := insolation
	var cb := cloudbase_msl
	if day.has_weather():
		ins = 1.0 - clampf(float(w.get("cirrus_cover", 0.0)), 0.0, 1.0) * cirrus_block
		if not cloudbase_fixed:
			cb = cloudbase_ref + day.value_at(t, "cloudbase_agl_m", float(_w.cloudbase_agl_m))
	var sd := day.sun_at(t)
	return {
		"w": w,
		"ins": ins,
		"cb": cb,
		"street": _street_for(w),
		"sun": sd if sd != Vector3.ZERO else sun_dir,
		"wpm": cloud_width_per_ms_base * float(w.get("cloud_size_factor", 1.0)),
	}


func _source_at(x: float, z: float, t: float) -> float:
	if day != null:
		var s := day.source_at(x, z, t)
		if s >= 0.0:
			return s
	return ground.sun(x, z)


## Термик цикла, рождённого в t_start; shade — тень облаков на источнике 0..1 (0 — «голый»).
func _spawn(
	ia: int, ic: int, id: int, t_start: float, period: float, shade_in: float = 0.0
) -> AtmoThermal:
	var rng := RandomNumberGenerator.new()
	rng.seed = id
	var env := _env_at(t_start)
	var w: Dictionary = env.w
	if rng.randf() > float(w.thermal_duty):
		return null
	var street: Vector2 = env.street
	# Источник: лучшая по освещённости из нескольких точек клетки, с подтяжкой к линии улицы.
	var best_sun := -1.0
	var best := Vector2.ZERO
	for k in int(_cfg.source_candidates):
		var a := (ia + rng.randf()) * _spacing
		var c := (ic + rng.randf()) * _spacing
		if street.x > 0.0:
			var line := roundf(c / street.y) * street.y
			c = lerpf(c, line + rng.randf_range(-0.1, 0.1) * street.y, street.x)
		var p := _ax * a + _cx * c
		var s := _source_at(p.x, p.y, t_start) * rng.randf_range(0.85, 1.0)
		if s > best_sun:
			best_sun = s
			best = p
	# В тени зрелого облака земля греется слабее (VR-2): меньше шанс и сила термика.
	var shade := shade_in * float(_cfg.cloud_shade_factor)
	best_sun *= 1.0 - shade
	# Перистая пелена ослабляет солнце: источники реже и слабее (VR-28).
	var ins: float = env.ins
	best_sun *= ins
	if best_sun < float(_cfg.sun_min):
		return null
	# Частота термиков — от силы источника (солнце, камни, границы поле–лес — sun_fn).
	if rng.randf() > pow(best_sun, float(_cfg.source_frequency_exponent)):
		return null
	var th := AtmoThermal.new()
	th.id = id
	th.noise_seed = id
	th.cell = Vector2i(ia, ic)
	var h := ground.height(best.x, best.y)
	th.src = Vector3(best.x, h, best.y)
	th.top = maxf(float(env.cb), h + float(_cfg.min_depth_m))
	var smin := float(w.thermal_strength_ms[0])
	var smax := float(w.thermal_strength_ms[1])
	var u := pow(rng.randf(), 1.4)  # слабых больше, чем сильных
	var sun_k := pow(best_sun, float(_cfg.sun_strength_exponent))
	th.strength = lerpf(smin, smax, u) * lerpf(1.0, sun_k, 0.5)
	th.strength = maxf(th.strength, smin) * (1.0 - shade)
	th.strength *= pow(ins, float(_cfg.insolation_strength_exponent))
	var rmin := float(w.thermal_radius_m[0])
	var rmax := float(w.thermal_radius_m[1])
	th.radius = lerpf(rmin, rmax, clampf(0.5 * rng.randf() + 0.5 * u, 0.0, 1.0))
	# Изредка — очень сильные термики (8–9 м/с): опасные, «по варику +8 уже надо валить».
	var ext: Array = w.get("thermal_extreme_ms", [])
	var is_extreme := false
	if rng.randf() < float(w.get("thermal_extreme_chance", 0.0)) and ext.size() == 2:
		th.strength = rng.randf_range(float(ext[0]), float(ext[1])) * sun_k * ins
		th.radius = rmax_extreme(th.radius, w)
		is_extreme = true
	# Времена: пауза + рост + зрелость + распад = период клетки.
	var gap := rng.randf_range(float(_cfg.gap_s[0]), float(_cfg.gap_s[1]))
	var g := rng.randf_range(float(_cfg.grow_s[0]), float(_cfg.grow_s[1]))
	var m := rng.randf_range(float(_cfg.mature_s[0]), float(_cfg.mature_s[1]))
	var d := rng.randf_range(float(_cfg.decay_s[0]), float(_cfg.decay_s[1]))
	var life := maxf(period - gap, 1.0)
	var k := life / (g + m + d)
	th.t_birth = t_start
	th.t_grow = g * k
	th.t_mature = m * k
	th.t_decay = d * k
	_setup_cloud(th, th.strength, rng.randf(), w, is_extreme)
	_setup_cb(th, rng.randf(), w)
	_apply_wind(th, street.x)
	return th


## Сильный зрелый термик в грозовой день может переразвиться в Cb (VR-26).
func _setup_cb(th: AtmoThermal, rnd: float, w: Dictionary) -> void:
	var smax := float(w.thermal_strength_ms[1])
	var chance := float(w.get("cb_chance", 0.0))
	if chance <= 0.0 or rnd >= chance or th.strength < smax * float(_cfg.cb_min_strength_frac):
		return
	th.is_cb = true
	th.has_cloud = true
	th.strength *= float(_cfg.cb_strength_factor)
	th.suck = float(_cfg.cb_suck)
	th.t_mature *= float(_cfg.cb_mature_factor)
	th.cloud_depth = maxf(float(w.get("cb_top_above_base_m", 6000.0)), th.cloud_depth)
	th.overdevelop = 1.0


## Насколько точка p в тени облаков (0..1) в момент t (статичные и динамические термики —
## без тени на них самих, см. _shade_pure). Для тестов и отладки.
func _cloud_shade(p: Vector2, t: float) -> float:
	return _shade_pure(p, t, _env_at(t))


## Тень облаков в точке p в момент t: облако — над верхом наклонённого столба зрелого термика
## с облаком, тень смещена от облака против солнца. Динамические термики — «голые» (рождённые
## без тени) соседних клеток: чистая функция (клетка, цикл), не зависит от того, какие термики
## сейчас в списке. Ищем в конечном окне против ветра (снос, наклон) и против солнца.
func _shade_pure(p: Vector2, t: float, env: Dictionary) -> float:
	var sd: Vector3 = env.sun
	if sd.y < 0.05:
		return 0.0
	var sxz := Vector2(sd.x, sd.z) / sd.y
	var wpm: float = env.wpm
	var shade := 0.0
	for th in _statics:
		shade = maxf(shade, _static_shade(th, p, float(env.cb), sxz, wpm))
	if mode == "static":
		return shade
	# Окно источников: p − (снос + наклон)·ось ветра − смещение тени, ± радиус облака.
	var span := maxf(float(env.cb) - cloudbase_ref, 0.0) + float(_cfg.min_depth_m)
	var sh := sxz * span
	if sh.length() > _SHADE_SUN_REACH_M:
		sh = sh.normalized() * _SHADE_SUN_REACH_M
	var up := _ax * _SHADE_REACH_M if wind.speed_ref > 0.0 else Vector2.ZERO
	var r := cloud_width_max * 0.5 + _spacing
	var a_lo := INF
	var a_hi := -INF
	var c_lo := INF
	var c_hi := -INF
	for corner: Vector2 in [p, p - up, p + sh, p - up + sh]:
		var ca := corner.dot(_ax)
		var cc := corner.dot(_cx)
		a_lo = minf(a_lo, ca)
		a_hi = maxf(a_hi, ca)
		c_lo = minf(c_lo, cc)
		c_hi = maxf(c_hi, cc)
	var cbf := _cb_factor()
	for ic in range(floori((c_lo - r) / _spacing), floori((c_hi + r) / _spacing) + 1):
		for ia in range(floori((a_lo - r) / _spacing), floori((a_hi + r) / _spacing) + 1):
			var pp := _cell_params(ia, ic)
			var cycle := floori((t + pp.y) / pp.x)
			# Текущий цикл; прежние — только Cb (обычный термик кончается до конца цикла).
			var k := 0
			while true:
				var cy := cycle - k
				var t_start := cy * pp.x - pp.y
				k += 1
				if k > 1:
					if t_start + pp.x * cbf < t:
						break
					if float(_weather_at(t_start).get("cb_chance", 0.0)) <= 0.0:
						continue
				var th := _bare_thermal(ia, ic, _mix(ia, ic, cy) | 1, t_start, pp.x)
				if th != null:
					shade = maxf(shade, _shade_of(th, p, t, sxz, wpm))
	return shade


## Тень статичного термика при кромке cb (верх и наклон — на тот момент, не текущие).
func _static_shade(th: AtmoThermal, p: Vector2, cb: float, sxz: Vector2, wpm: float) -> float:
	if not th.has_cloud:
		return 0.0
	var span := maxf(cb, th.src.y + float(_cfg.min_depth_m)) - th.src.y
	var rise := maxf(th.strength * float(_cfg.rise_factor), float(_cfg.rise_min_ms))
	var lean := wind.vec2_at(span * 0.5) / rise
	var max_lean := tan(deg_to_rad(float(_cfg.max_lean_deg)))
	if lean.length() > max_lean:
		lean = lean.normalized() * max_lean
	var c := Vector2(th.src.x, th.src.z) + lean * span - sxz * span
	var r := clampf(wpm * th.strength, cloud_width_min, cloud_width_max) * 0.5
	var d := c.distance_to(p)
	if d >= r:
		return 0.0
	return 1.0 - smoothstep(r * 0.6, r, d)


func _shade_of(th: AtmoThermal, p: Vector2, t: float, sxz: Vector2, wpm: float) -> float:
	if not th.has_cloud:
		return 0.0
	var e := th.envelope(t)
	if e < 0.5:
		return 0.0
	var c := th.cloud_center(t) - sxz * (th.top - th.src.y)
	var r := clampf(wpm * th.strength, cloud_width_min, cloud_width_max) * 0.5
	var d := c.distance_to(p)
	if d >= r:
		return 0.0
	return e * (1.0 - smoothstep(r * 0.6, r, d))


func _bare_thermal(ia: int, ic: int, id: int, t_start: float, period: float) -> AtmoThermal:
	var v: Variant = _bare.get(id)
	if v != null:
		return v
	if _bare_empty.has(id):
		return null
	var th := _spawn(ia, ic, id, t_start, period, 0.0)
	var forget := t_start + _reach_of(t_start, period)
	if th == null:
		_bare_empty[id] = forget
	else:
		th.cycle_forget = forget
		_bare[id] = th
	return th


## Раз в минуту — забыть пустые циклы и «голые» термики, которые уже не понадобятся (с запасом
## на самые старые циклы, что ещё рождаются), и клетки далеко от круга.
func _prune(t: float) -> void:
	if t - _prune_t < 60.0 and t >= _prune_t:
		return
	_prune_t = t
	for id in _empty_cycles.keys():
		if t > float(_empty_cycles[id]):
			_empty_cycles.erase(id)
	var hi := 0.0
	for k in ["grow_s", "mature_s", "decay_s", "gap_s"]:
		hi += float(_cfg[k][1])
	var old := t - 2.0 * (hi * _cb_factor() + cloud_linger_s)
	for id in _bare.keys():
		if (_bare[id] as AtmoThermal).cycle_forget < old:
			_bare.erase(id)
	for id in _bare_empty.keys():
		if float(_bare_empty[id]) < old:
			_bare_empty.erase(id)
	for key in _cell_seen.keys():
		if (_cell_seen[key] as Vector2i).y < _gen_stamp - 1:
			_cell_seen.erase(key)


func _rebuild_buckets(t: float, focus: Vector3, margin_s: float) -> void:
	_buckets.clear()
	_active.clear()
	var cut := sqrt(_cut2)
	for id in thermals:
		var th: AtmoThermal = thermals[id]
		if not th.is_static and t > th.t_end():
			continue
		th.update_time(t)
		var p0 := th.axis_at(th.src.y)
		# Поток продолжается внутрь облака (подсос) — столб до верха облака.
		var p1 := th.axis_at(th.top + th.cloud_depth)
		# Снос за интервал до следующего обновления — запас.
		var pad := th.radius * cut + th.drift_vel.length() * margin_s
		if not th.is_static and t + margin_s > th.drift_start():
			p1 += th.drift_vel * margin_s
		var mid := (p0 + p1) * 0.5
		var near_d := Vector2(focus.x, focus.z).distance_to(mid) - p0.distance_to(p1) * 0.5 - pad
		if near_d > _phys_r:
			continue
		var off := _active.size() * _P_STRIDE
		_active.append(th)
		_insert_capsule(p0, p1, pad, off)
	_tp.resize(_active.size() * _P_STRIDE)
	_write_params(t)


## Вписать отрезок p0–p1 с запасом pad в ячейки поиска: по строкам z находим диапазон x.
func _insert_capsule(p0: Vector2, p1: Vector2, pad: float, off: int) -> void:
	var bz0 := floori((minf(p0.y, p1.y) - pad) * _inv_bucket)
	var bz1 := floori((maxf(p0.y, p1.y) + pad) * _inv_bucket)
	var dz := p1.y - p0.y
	for bz in range(bz0, bz1 + 1):
		# Полоса строки, расширенная на pad: какая часть отрезка в неё попадает.
		var z_lo := bz * _bucket - pad
		var z_hi := (bz + 1) * _bucket + pad
		var ta := 0.0
		var tb := 1.0
		if absf(dz) > 1.0e-6:
			var t1 := (z_lo - p0.y) / dz
			var t2 := (z_hi - p0.y) / dz
			ta = clampf(minf(t1, t2), 0.0, 1.0)
			tb = clampf(maxf(t1, t2), 0.0, 1.0)
		var xa := lerpf(p0.x, p1.x, ta)
		var xb := lerpf(p0.x, p1.x, tb)
		var bx0 := floori((minf(xa, xb) - pad) * _inv_bucket)
		var bx1 := floori((maxf(xa, xb) + pad) * _inv_bucket)
		for bx in range(bx0, bx1 + 1):
			var key := (bx + _KEY_OFFSET) * _KEY_MUL + (bz + _KEY_OFFSET)
			var arr: Variant = _buckets.get(key)
			if arr == null:
				arr = []
				_buckets[key] = arr
			arr.append(off)


## Параметры активных термиков — в плоский массив (горячий путь sample() без обращений к объектам).
func _write_params(t: float) -> void:
	var o := 0
	for th in _active:
		_tp[o] = th.src.x + th.drift.x
		_tp[o + 1] = th.src.y
		_tp[o + 2] = th.src.z + th.drift.y
		_tp[o + 3] = th.top
		_tp[o + 4] = th.lean.x
		_tp[o + 5] = th.lean.y
		_tp[o + 6] = th.radius
		_tp[o + 7] = th.strength * th.env
		_tp[o + 8] = th.cut_h
		_tp[o + 9] = th.env
		_tp[o + 10] = 1.0 / maxf(th.top - th.src.y, 1.0)
		# Облачный подсос: усиление у основания и высота потока в облаке (FR-14b).
		var sk := cloud_phys.suck(th, t) if cloud_phys != null else Vector2(th.suck, 0.0)
		_tp[o + 11] = sk.x
		_tp[o + 12] = sk.y
		o += _P_STRIDE


## Обновить огибающие/снос термиков в радиусе физики (каждый шаг).
func update_time(t: float) -> void:
	for th in _active:
		th.update_time(t)
	_write_params(t)


func active_count() -> int:
	return _active.size()


## Вертикальный поток от термиков в точке: (сумма w, маска ядра 0..1, СКО болтанки на краю).
func sample(pos: Vector3) -> Vector3:
	var key := (
		(floori(pos.x * _inv_bucket) + _KEY_OFFSET) * _KEY_MUL
		+ (floori(pos.z * _inv_bucket) + _KEY_OFFSET)
	)
	var arr: Variant = _buckets.get(key)
	if arr == null:
		return Vector3.ZERO
	var tp := _tp
	var w := 0.0
	var mask := 0.0
	var edge2 := 0.0
	for o: int in arr:
		var dh := pos.y - tp[o + 1]
		var top := tp[o + 3]
		var in_h := tp[o + 12]
		if dh <= 0.0 or pos.y >= top + in_h or tp[o + 9] <= 0.0:
			continue
		# Быстрый отсев по максимальному радиусу (у верха), до дорогих pow/exp.
		var cx := tp[o] + tp[o + 4] * dh - pos.x
		var cz := tp[o + 2] + tp[o + 5] * dh - pos.z
		var d2 := cx * cx + cz * cz
		var r0 := tp[o + 6]
		if d2 > r0 * r0 * _cut2:
			continue
		# Оторвавшийся низ на распаде: плавная граница.
		var cutk := 1.0
		var cut_h := tp[o + 8]
		if pos.y < cut_h + _CUT_BLEND_M:
			cutk = (pos.y - cut_h) / _CUT_BLEND_M
			if cutk <= 0.0:
				continue
		var xi := minf(dh * tp[o + 10], 1.0)
		var rf := maxf(_rmin, pow(xi, _THIRD) * (1.0 - 0.25 * xi) * _ALLEN_NORM)
		var r := r0 * rf
		var x2 := d2 / (r * r)
		if x2 > _cut2:
			continue
		var vert := minf(1.0, pow(dh / _ramp, _THIRD))
		var top_d := top - pos.y
		var suck := tp[o + 11]
		if top_d < 0.0:
			# В облаке упорядоченного потока почти нет — бурлящий воздух (болтанку и «выкидывание»
			# к краю добавляет Atmosphere); средний подъём слабый, к верхушке гаснет.
			vert *= _in_cloud_mean * (1.0 + suck) * (1.0 - smoothstep(0.5, 1.0, -top_d / in_h))
		elif suck > 0.0:
			# Облачный подсос: в последних suck_depth м под основанием подъём растёт.
			vert *= 1.0 + suck * (1.0 - smoothstep(0.0, _suck_depth, top_d))
		elif top_d < _taper:
			vert *= smoothstep(0.0, _taper, top_d)
		var a := tp[o + 7] * vert * cutk
		var ex := exp(-x2)
		var g := ex * (1.0 - x2)
		if g < 0.0:
			g *= _ring
		w += a * g
		mask = maxf(mask, tp[o + 9] * vert * cutk * ex)
		var e := (sqrt(x2) - 1.0) / _edge_w
		var ea := _edge_k * a * exp(-e * e)
		edge2 += ea * ea
	return Vector3(w, mask, sqrt(edge2))


## Термики рядом с точкой (для тестов, птиц, отладки — НЕ для подсказок пилоту).
func near(pos: Vector3, radius: float) -> Array[AtmoThermal]:
	var out: Array[AtmoThermal] = []
	var r2 := radius * radius
	for id in thermals:
		var th: AtmoThermal = thermals[id]
		var a := th.axis_at(clampf(pos.y, th.src.y, th.top))
		var dx := a.x - pos.x
		var dz := a.y - pos.z
		if dx * dx + dz * dz <= r2:
			out.append(th)
	return out
