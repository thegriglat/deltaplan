class_name BotPilot
extends RefCounted
## «Мозги» бота-пилота (перенесён из tests/atmosphere/xc/xc_pilot.gd): маршрутник XC (FR-34a,
## тесты tests/atmosphere/xc) и основа «других пилотов в небе» (WanderPilot — без цели).
##
## Бот-маршрутник (FR-34a): летит на поворотную точку и ищет термики только по вариометру —
## как пилот (FR-22). Видит: вариометр, высоту, AGL, курс, крен (чувствует телом), позицию,
## путевую скорость; знает поляру своего крыла, кромку облаков (видно глазами) и, если включено,
## облака на небе. Термики атмосферы (thermals_near) НЕ использует.
##
## Режимы: CRUISE (переход по МакКриди) → ENTER (подъём сильнее порога — «пощупать» сторону) →
## CIRCLE (вираж 35–40°, центровка по Райхману, выход по набору за круг) → CRUISE.
## PROBE — проверка стороны после «кольца» опускания рядом с термиком.
## RIDGE — «восьмёрка у склона» (карточка 05): галсы вдоль гребня, разворот в конце каждого
## галса всегда от склона (к долине) — включается setup_ridge(), термики бот в этом режиме
## не ищет (используется на голом склоне для проверки склоновой модели).
## Ниже save_agl_m — «спасение»: скорость минимального снижения, берёт любой подъём.

enum Mode { CRUISE, ENTER, CIRCLE, PROBE, AVOID, RIDGE }

const POLAR_STEP := 0.25
## Запаздывание отклика вариометра за подъёмом (для карты подъёма), с.
const LAG_FAST_S := 1.2
## Запаздывание середины скользящего среднего (+ отклик крыла), с — длина истории позиций.
const LAG_BOX_S := 2.5

# --- настройки (м, м/с, с, градусы) ---
## Порог входа: нетто (усреднённый вариометр + собственное снижение) выше, м/с.
var enter_netto_ms: float = 0.5
## Порог входа в режиме спасения, м/с.
var save_enter_netto_ms: float = 0.3
## Ниже этой высоты над землёй — режим спасения.
var save_agl_m: float = 300.0
## Крен в термике, °.
var circle_bank_deg: float = 38.0
## Пределы крена при центровке, °.
var circle_bank_min_deg: float = 8.0
var circle_bank_max_deg: float = 50.0
## Центровка: память карты подъёма (позиции с сильным вариометром), с.
var centering_tau_s: float = 12.0
## Сдвиг круга к цели: за сколько секунд центр виража подходит к центру подъёма, с.
var center_shift_tau_s: float = 10.0
## Предел выполаживания виража при сдвиге круга (доля tg крена) и докручивания.
var center_flatten_max: float = 0.85
var center_steepen_max: float = 0.5
## Усреднение оценки ветра по сносу (GPS − воздушная скорость по курсу), с.
var wind_tau_s: float = 20.0
## Орбита вокруг центра подъёма: поправка курса на 1 м ошибки радиуса, °; крен на 1° курса.
var orbit_gain: float = 2.0
var orbit_bank_per_deg: float = 0.5
var orbit_bank_max_deg: float = 18.0
## Предельный крен на переходе, °.
var cruise_bank_max_deg: float = 30.0
## Запас над рельефом по курсу (плюс 10 % дальности), м.
var terrain_clear_m: float = 60.0
## Не подходить к кромке под облаком ближе, м (FR-14b).
var cloudbase_margin_m: float = 150.0
## МакКриди = доля среднего набора в термиках (консервативно).
var mc_factor: float = 0.7
var mc_min_ms: float = 0.5
var mc_max_ms: float = 2.5
## Болтанка слабее (СКО быстрых колебаний нетто на прямой, м/с) — решения по быстрым сигналам.
var calm_sigma_ms: float = 0.12
## Окно скользящего среднего нетто для решений в болтанке (вход, поиск), с.
var netto_box_s: float = 4.0
## Как быстро пилот меняет скорость, м/с².
var speed_slew_ms2: float = 0.5
## Запаздывание воздушной скорости за трапецией/креном (для учёта обмена высоты на скорость), с.
var speed_lag_s: float = 1.5
## Усреднение вариометра, с.
var vario_tau_s: float = 1.5
## «Кольцо» опускания: нетто хуже обычного на столько — рядом термик, м/с.
var ring_drop_ms: float = 0.35
## Край ядра: нетто лучше обычного на столько (но ниже порога входа), м/с.
var bump_rel_ms: float = 0.35
## Неоднородность кончилась, если столько секунд воздух обычный, с.
var anomaly_quiet_s: float = 3.5
## Не искать термики (пробы), если до кромки меньше, м — высоты хватает.
var probe_below_base_m: float = 200.0
## Дальность пробы в сторону после кольца, м (0 — не пробовать).
var probe_out_m: float = 120.0
## Облака на небе видны (флаг --clouds): выбирать цель перехода под растущим облаком.
var use_clouds: bool = false
## Сектор выбора облака от курса на цель, °.
var cloud_sector_deg: float = 30.0
## «Восьмёрка у склона» (карточка 05): направление вдоль гребня и от склона (в долину), °;
## диаметр витка, м; крен виража, °; целевая полоса высоты над склоном (AGL), м, — для отчёта
## прогона (сам бот держит скорость мин. снижения, набор/спуск решает только склоновый поток).
var ridge_active: bool = false
var ridge_along_deg: float = 0.0
var ridge_away_deg: float = 0.0
var ridge_leg_m: float = 350.0
var ridge_bank_deg: float = 30.0
var ridge_band_lo_agl: float = 50.0
var ridge_band_hi_agl: float = 100.0

# --- маршрут и знания пилота ---
var goal: Vector2 = Vector2.ZERO
## Начало прямой маршрута (по умолчанию — точка старта).
var route_start: Vector2 = Vector2.ZERO
## Упреждение при возврате на линию курса, м.
var line_lookahead_m: float = 600.0
## Кромка облаков над уровнем моря (видна глазами), м.
var cloudbase_msl: float = 1.0e9
## Рельеф (x, z) -> высота, м: пилот видит склоны впереди. Пусто — без обхода.
var ground_fn: Callable
## clouds_fn() -> Array[Dictionary] {center: Vector2, radius: float, growth: float, decay: float}.
var clouds_fn: Callable

# --- состояние (читает xc_run для статистики) ---
var mode: Mode = Mode.CRUISE
var save_mode: bool = false
## Завершённые круги: {climb_ms, center: Vector2, alt_m, t_s}.
var circles: Array[Dictionary] = []
## Завершённые термики: {circles, gain_m, time_s, climb_ms, center: Vector2, exit: Vector2, top_m}.
var thermals: Array[Dictionary] = []
var mc_ms: float = 1.0

var _stf_t: float = -1.0e9
var _stf_v: float = 10.0
var _k_alt: float = -1.0e9
var _k_cached: float = 1.0
var _fm: FlightModel  ## своя копия модели — только для поляры (пилот знает своё крыло)
var _v_trim: float = 10.0
var _v_pull: float = 26.0
var _v_push: float = 6.4
var _polar_v: PackedFloat32Array = []
var _polar_s: PackedFloat32Array = []
var _v_min_sink: float = 9.4

var _ctl := ControlInput.new()
var _t: float = 0.0
var _vario_avg: float = 0.0
var _netto_avg: float = 0.0
var _netto_fast: float = 0.0
var _netto_box: float = 0.0
var _n_dec: float = 0.0
var _n_peak: float = 0.0
var _turb_var: float = 0.04
var _calm: bool = false
var _box: PackedFloat32Array = PackedFloat32Array()
var _box_sum: float = 0.0
var _box_i: int = 0
var _netto_slow: float = -0.5
var _netto_stf: float = -0.5
var _dt: float = 1.0 / 60.0
var _own_sink: float = 1.0
var _prev_bank: float = 0.0
var _bank_rate: float = 0.0
var _v_cmd: float = 10.0
var _v_exp: float = 10.0
## Ветер по сносу (GPS минус воздушная скорость по курсу), м/с (x, z).
var _wind_est: Vector2 = Vector2.ZERO
## Центровка по первой гармонике подъёма за круг (карточка 07).
var _fit := BotCircleFit.new()
## Самый сильный недавний подъём (нетто, м/с) и где он был — для первого круга.
var _peak_val: float = -INF
var _peak_pos: Vector2 = Vector2.ZERO
## Скорость центра подъёма (знает только диагностический пилот), м/с (x, z).
var _lc_vel: Vector2 = Vector2.ZERO

var _enter_t: float = 0.0
var _enter_bank0: float = 0.0
var _enter_peak: float = 0.0
var _dir: float = 1.0
var _turned: float = 0.0
var _prev_heading: float = 0.0
var _circle_t0: float = 0.0
var _circle_alt0: float = 0.0
var _circle_pos: Vector2 = Vector2.ZERO
var _circle_n: int = 0
var _circle_best: float = -INF
var _weak_circles: int = 0
var _th_t0: float = 0.0
var _th_alt0: float = 0.0
var _th_circles: int = 0
var _th_center: Vector2 = Vector2.ZERO
var _last_climb: float = 0.0
var _no_enter_pos: Vector2 = Vector2(1.0e9, 1.0e9)
var _no_enter_r: float = 0.0

## Неоднородность на переходе: 1 — подъём лучше фона, −1 — кольцо опускания, 0 — нет.
var _anomaly: int = 0
var _roll_sum: float = 0.0
var _roll_n: int = 0
var _probe_c: Vector2 = Vector2.ZERO
var _probe_r: float = 100.0
var _probe_dir: float = 1.0
var _probe_turned: float = 0.0
var _probe_prev: Vector2 = Vector2.ZERO
var _search_on: bool = false
var _anom_ext: float = 0.0
var _anom_pos: Vector2 = Vector2.ZERO
var _anom_start: Vector2 = Vector2.ZERO
var _anom_min: float = 0.0
var _quiet_t: float = 0.0
var _quiet_pos: Vector2 = Vector2.ZERO
var _probe_cooldown: float = 30.0

var _senses_ready: bool = false
var _vario_s: float = 0.0
var _vario_long: float = 0.0
var _circle_c: Vector2 = Vector2.ZERO
var _lift_c: Vector2 = Vector2.ZERO
var _lift_w: float = 0.0
var _lift_sum: Vector2 = Vector2.ZERO
## Позиции за последние LAG_BOX_S с: отклик вариометра запаздывает за подъёмом.
var _pos_hist: PackedVector2Array = PackedVector2Array()
var _pos_i: int = 0
var _lag_fast: int = 1

var _terrain_t: float = 0.0
var _terrain_block: bool = false
var _avoid_heading: float = 0.0
var _avoid_clear: float = 0.0

var _cloud_target: Vector2 = Vector2.ZERO
var _has_cloud_target: bool = false
var _cloud_timer: float = 0.0
var _visited_clouds: Array[Vector2] = []

# --- восьмёрка у склона (карточка 05, состояние) ---
var _ridge_origin: Vector2 = Vector2.ZERO
var _ridge_dir: float = 1.0
var _ridge_turn_deg: float = 0.0
var _ridge_prev_heading: float = 0.0


## wing_cfg/pilot_cfg — как у FlightModel.setup; goal_xz — поворотная точка (x, z).
func setup(wing_cfg: Dictionary, pilot_cfg: Dictionary, goal_xz: Vector2) -> void:
	goal = goal_xz
	_fm = FlightModel.new()
	_fm.setup(wing_cfg, pilot_cfg)
	_v_trim = Units.kmh(float(wing_cfg.trim_speed_kmh))
	_v_pull = Units.kmh(float(wing_cfg.full_pull_speed_kmh))
	_v_push = Units.kmh(float(wing_cfg.full_push_speed_kmh))
	_build_polar(0.0)


## Один шаг: телеметрия → управление (FR-22: только то, что видит и чувствует пилот).
func drive(t: Telemetry, dt: float) -> ControlInput:
	_t += dt
	_dt = dt
	if t.phase != "flying":
		_ctl.pitch = 0.0
		_ctl.roll = 0.0
		return _ctl
	_update_senses(t, dt)
	save_mode = t.altitude_agl < save_agl_m
	# Низко — МакКриди меньше (лететь дальше, брать слабее), у кромки — полный.
	var frac := clampf((t.altitude_agl - save_agl_m) / maxf(_base_agl(t) * 0.6, 100.0), 0.0, 1.0)
	mc_ms = 0.0 if save_mode else _mc_setting() * lerpf(0.3, 1.0, frac)
	var pos := Vector2(t.position.x, t.position.z)
	_update_lift_map(t, pos, dt)
	# «Восьмёрка» у склона сама уходит от рельефа (разворот в конце каждого галса, всегда от
	# склона) — общий обход рельефа (для дальних переходов) тут не нужен и мешал бы развороту.
	if mode != Mode.RIDGE and _check_terrain(t, pos, dt):
		return _ctl
	if _take_over(t, pos, dt):
		return _ctl
	match mode:
		Mode.CRUISE:
			_cruise(t, pos, dt)
		Mode.ENTER:
			_enter(t, pos, dt)
		Mode.CIRCLE:
			_circle(t, pos, dt)
		Mode.PROBE:
			_probe(t, pos, dt)
		Mode.RIDGE:
			_ridge_fly(t, pos, dt)
	return _ctl


## Усреднённый нетто-вариометр, м/с (для трассировки).
func netto() -> float:
	return _netto_box


## Внутреннее состояние одной строкой (для трассировки).
func debug_state() -> String:
	var s := (
		"an=%d base=%.2f cool=%.0f srch=%d sig=%.2f"
		% [_anomaly, _netto_slow, _probe_cooldown, int(_search_on), sqrt(_turb_var)]
	)
	return s + " W=(%.1f,%.1f)" % [_wind_est.x, _wind_est.y]


func _base_agl(t: Telemetry) -> float:
	return cloudbase_msl - (t.altitude_msl - t.altitude_agl)


## Рельеф впереди (пилот видит склоны): если по курсу земля выше глиссады с запасом —
## уйти (выйти из круга) на курс к самой низкой земле, пока впереди не станет чисто.
## Возвращает true, если управление взял на себя обход.
func _check_terrain(t: Telemetry, pos: Vector2, dt: float) -> bool:
	if not ground_fn.is_valid():
		return false
	_terrain_t -= dt
	if _terrain_t <= 0.0:
		_terrain_t = 0.5
		_terrain_block = _blocked(pos, t.heading_deg, t.altitude_msl)
		if mode == Mode.CIRCLE and not _terrain_block:
			# В вираже смотрим и в сторону сноса/следующей половины круга.
			_terrain_block = _blocked(pos, t.heading_deg + 90.0 * _dir, t.altitude_msl)
		if _terrain_block and mode != Mode.AVOID:
			if mode == Mode.CIRCLE:
				_exit_thermal(t, pos)
				_search_on = false
			mode = Mode.AVOID
			_avoid_heading = _lowest_heading(pos, t.heading_deg)
			_avoid_clear = 0.0
		elif mode == Mode.AVOID and _terrain_block:
			_avoid_heading = _lowest_heading(pos, t.heading_deg)
	if mode != Mode.AVOID:
		return false
	_steer_heading(t, _avoid_heading, 40.0)
	_set_speed(_stf(0.0, t.altitude_msl), t)
	_avoid_clear = 0.0 if _terrain_block else _avoid_clear + dt
	if _avoid_clear > 5.0:
		mode = Mode.RIDGE if ridge_active else Mode.CRUISE
	return true


func _blocked(pos: Vector2, heading_deg: float, alt: float) -> bool:
	var h := deg_to_rad(heading_deg)
	var fwd := Vector2(sin(h), -cos(h))
	for d: float in [80.0, 200.0, 350.0, 500.0]:
		var p := pos + fwd * d
		if float(ground_fn.call(p.x, p.y)) > alt - terrain_clear_m - d * 0.1:
			return true
	return false


## Курс (из ±150° с шагом 30°) с самой низкой землёй в 400 м — куда уходить от склона.
func _lowest_heading(pos: Vector2, heading_deg: float) -> float:
	var best := heading_deg + 180.0
	var best_h := INF
	for k in range(-5, 6):
		var hd := heading_deg + k * 30.0
		var h := deg_to_rad(hd)
		var fwd := Vector2(sin(h), -cos(h))
		var g := -INF
		for d: float in [150.0, 400.0]:
			var p := pos + fwd * d
			g = maxf(g, float(ground_fn.call(p.x, p.y)))
		# При равной земле — ближе к цели.
		g += 0.02 * absf(wrapf(hd - _bearing_deg(pos, goal), -180.0, 180.0))
		if g < best_h:
			best_h = g
			best = hd
	return fposmod(best, 360.0)


func is_circling() -> bool:
	return mode == Mode.CIRCLE


# ================================================================ восьмёрка у склона


## Включить «восьмёрку у склона» (карточка 05): держится над рабочей точкой origin (50–100 м
## AGL перед гребнем — band_lo/band_hi, м) витками радиуса leg_m/2, раз в виток меняя сторону
## разворота — «восьмёрка» из двух смежных петель над одним местом (устойчиво к сносу ветром
## поперёк склона, в отличие от прямых галсов с разворотом на краю). along_deg/away_deg —
## направление вдоль гребня и от склона (в долину, для справки/отчёта). Бот держит скорость
## минимального снижения — набор/снижение решает только склоновый поток.
func setup_ridge(
	origin: Vector2,
	along_deg: float,
	away_deg: float,
	leg_m: float = 350.0,
	band_lo_agl: float = 50.0,
	band_hi_agl: float = 100.0
) -> void:
	ridge_active = true
	_ridge_origin = origin
	ridge_along_deg = fposmod(along_deg, 360.0)
	ridge_away_deg = fposmod(away_deg, 360.0)
	ridge_leg_m = leg_m
	ridge_band_lo_agl = band_lo_agl
	ridge_band_hi_agl = band_hi_agl
	mode = Mode.RIDGE
	_ridge_dir = 1.0
	_ridge_turn_deg = 0.0
	_ridge_prev_heading = 0.0


## Ветер поперёк — прямой галс сносит непредсказуемо (у реального рельефа рабочая полоса
## подъёма — часто просто пятно перед гребнем, не прямая линия). Вместо галсов с разворотами
## держим постоянный радиус вокруг рабочей точки origin (как в _circle/_probe — та же поправка
## курса на радиус, проверенная), но раз в круг меняем сторону виража на обратную — это и есть
## «восьмёрка»: два смежных витка в разные стороны над одним и тем же местом у склона, без
## сноса галса ветром. Разворот у витка всегда возможен в любую сторону от склона (центр — над
## рабочей точкой перед гребнем, не над самим гребнем).
func _ridge_fly(t: Telemetry, pos: Vector2, _dt: float) -> void:
	_set_speed(_v_min_sink * 1.05 * _speed_scale(t.altitude_msl), t)
	var v := maxf(t.groundspeed, 5.0)
	var r := ridge_leg_m * 0.5
	var base_bank := rad_to_deg(atan(v * v / (Units.G * r)))
	_hold_bank(t, _orbit_bank(t, pos, _ridge_origin, r, _ridge_dir, base_bank, ridge_bank_deg))
	_ridge_turn_deg += absf(wrapf(t.heading_deg - _ridge_prev_heading, -180.0, 180.0))
	_ridge_prev_heading = t.heading_deg
	if _ridge_turn_deg >= 360.0:
		_ridge_turn_deg -= 360.0
		_ridge_dir = -_ridge_dir


# ================================================================ ощущения


func _update_senses(t: Telemetry, dt: float) -> void:
	if dt > 0.0:
		_bank_rate = lerpf(_bank_rate, (t.bank_deg - _prev_bank) / dt, 0.3)
	_prev_bank = t.bank_deg
	# Собственное снижение — из поляры по заданной скорости и крену (пилот знает крыло).
	var n := 1.0 / maxf(cos(deg_to_rad(absf(t.bank_deg))), 0.3)
	_own_sink = _sink_at(_v_cmd, t.altitude_msl) * pow(n, 1.5)
	# Своя «ручка»: пилот знает, что разгоняется/тормозит или кренится (скорость при том же угле
	# атаки ∝ √n) — обмен высоты на скорость вычитаем из вариометра (как ТЭ по своим действиям).
	var v_goal := _v_cmd * sqrt(n)
	var v_prev := _v_exp
	_v_exp += (v_goal - _v_exp) * (1.0 - exp(-dt / speed_lag_s))
	var energy := _v_exp * (_v_exp - v_prev) / maxf(dt, 1.0e-4) / Units.G
	var k := 1.0 - exp(-dt / vario_tau_s)
	if not _senses_ready:
		# Первое показание: фильтры с текущего, база — обычный фон (≈ −0,5 м/с).
		_senses_ready = true
		_v_exp = _v_cmd
		_vario_avg = t.vario
		_vario_s = t.vario
		_netto_avg = t.vario + _own_sink
		_netto_fast = _netto_avg
		_netto_slow = _netto_avg
		_netto_stf = _netto_avg
		_pos_hist.resize(maxi(2, roundi(LAG_BOX_S / maxf(dt, 1.0e-3))))
		_lag_fast = clampi(roundi(LAG_FAST_S / maxf(dt, 1.0e-3)), 1, _pos_hist.size() - 1)
		_pos_hist.fill(Vector2(t.position.x, t.position.z))
	var drift := t.velocity - t.air_velocity
	_wind_est += (Vector2(drift.x, drift.z) - _wind_est) * (1.0 - exp(-dt / wind_tau_s))
	_vario_s += (t.vario - _vario_s) * (1.0 - exp(-dt / 0.3))
	_pos_i = (_pos_i + 1) % _pos_hist.size()
	_pos_hist[_pos_i] = Vector2(t.position.x, t.position.z)
	_vario_avg += (t.vario - _vario_avg) * k
	var netto := t.vario + _own_sink + energy
	_netto_avg += (netto - _netto_avg) * k
	_netto_stf += (netto - _netto_stf) * (1.0 - exp(-dt / 4.0))
	_netto_fast += (netto - _netto_fast) * (1.0 - exp(-dt / 0.7))
	# Скользящее среднее за netto_box_s: высота за окно — болтанку и обмен скорости на высоту
	# гасит лучше экспоненты; по нему решаем, входить ли и искать ли.
	if _box.is_empty():
		_box.resize(maxi(1, roundi(netto_box_s / maxf(dt, 1.0e-3))))
		_box.fill(netto)
		_box_sum = netto * _box.size()
	_box_sum += netto - _box[_box_i]
	_box[_box_i] = netto
	_box_i = (_box_i + 1) % _box.size()
	_netto_box = _box_sum / _box.size()
	# Болтанка (СКО вариометра вокруг среднего): в спокойном воздухе решаем по быстрым
	# сигналам, в болтанке — по скользящему среднему (иначе кружим в каждом порыве).
	# Оцениваем на прямой (в вираже вариометр «гуляет» от самого круга).
	# Где был самый сильный подъём недавно (позиция — с запаздыванием отклика): туда и
	# ставим первый круг (вход по усреднённому нетто в болтанке запаздывает на десятки метров).
	_peak_val -= dt * 0.25
	if mode != Mode.CIRCLE and _netto_fast > _peak_val:
		_peak_val = _netto_fast
		_peak_pos = _lagged_pos()
	if mode == Mode.CRUISE:
		var dv := _netto_fast - _netto_avg
		_turb_var += (dv * dv - _turb_var) * (1.0 - exp(-dt / 30.0))
	_calm = sqrt(_turb_var) < calm_sigma_ms
	_n_dec = _netto_avg if _calm else _netto_box
	_n_peak = _netto_fast if _calm else _netto_box


# ================================================================ переход


func _cruise(t: Telemetry, pos: Vector2, dt: float) -> void:
	var target := _cruise_target(pos, dt)
	var want := _bearing_deg(pos, target)
	_steer_heading(t, want, cruise_bank_max_deg)
	_set_speed(_stf(_netto_slow_for_stf(), t.altitude_msl), t)
	if mode != Mode.CRUISE:
		return
	# Подъём сильнее порога — входим (не в только что брошенный термик).
	var thr := save_enter_netto_ms if save_mode else enter_netto_ms
	# Низко (спасение) — тоже не возвращаться в только что брошенное место (иначе кружит в
	# порывах на одном месте до земли), но радиус запрета меньше.
	var far := pos.distance_to(_no_enter_pos) > (_no_enter_r * 0.5 if save_mode else _no_enter_r)
	var high := t.altitude_msl > cloudbase_msl - cloudbase_margin_m - 50.0
	var much_better := _n_dec > mc_ms + 1.0
	if _n_dec > thr and (far or much_better) and not high:
		_start_enter(t)
		return
	# Неоднородность воздуха рядом с термиком: край ядра (подъём слабее порога, но лучше фона)
	# или кольцо опускания. Когда кончится — проба в сторону (подсказка — крен от крыла, FR-8).
	_probe_cooldown -= dt
	var rel := _n_dec - _netto_slow
	if far and (rel > bump_rel_ms or rel < -ring_drop_ms):
		if _anomaly == 0:
			_anomaly = 1 if rel > 0.0 else -1
			_roll_sum = 0.0
			_roll_n = 0
			_anom_ext = _n_peak
			_anom_min = _n_peak
			_anom_start = _dec_pos()
		elif rel > bump_rel_ms:
			_anomaly = 1  # край ядра важнее кольца: термик ближе
		_anom_ext = maxf(_anom_ext, _n_peak)
		_anom_min = minf(_anom_min, _n_peak)
		_roll_sum += _ctl.roll
		_roll_n += 1
		_quiet_t = 0.0
	elif _anomaly != 0 and absf(rel) < ring_drop_ms * 0.6:
		# Кончилась, если спокойно несколько секунд (между двумя кольцами бывает «окно»).
		if _quiet_t == 0.0:
			_quiet_pos = _dec_pos()
		_quiet_t += dt
		if _quiet_t >= anomaly_quiet_s:
			var kind := _anomaly
			_anomaly = 0
			_quiet_t = 0.0
			# Неоднородность симметрична относительно ближайшей к оси точки: берём середину.
			_anom_pos = (_anom_start + _quiet_pos) * 0.5
			# Искать стоит, только если неоднородность заметная и высоты не с избытком.
			var strong := _anom_ext > _netto_slow + bump_rel_ms + 0.05
			strong = strong or _anom_min < _netto_slow - ring_drop_ms - 0.05
			var need := t.altitude_msl < cloudbase_msl - probe_below_base_m
			# В болтанке кольца и «края» тонут в порывах — пробы только в спокойном воздухе или
			# по явному кольцу опускания (скользящее среднее намного ниже фона; «края» подъёма
			# в болтанке неотличимы от порывов), и не низко — там пробы только тратят высоту.
			var clear := _anom_min < _netto_slow - ring_drop_ms - 0.4 and not save_mode
			if (
				probe_out_m > 0.0
				and _probe_cooldown <= 0.0
				and strong
				and need
				and (_calm or clear)
			):
				_start_probe(t, pos, kind)
				return
	# Фон переходов — медленное среднее нетто в режиме перехода (кольца короче, базу не сдвигают).
	_netto_slow += (_n_dec - _netto_slow) * (1.0 - exp(-dt / 30.0))


func _netto_slow_for_stf() -> float:
	# Разгон в опускании, притормаживание в подъёме (дельфин) — по сильно усреднённому нетто:
	# без ТЭ-компенсации быстрый нетто ловит обмен скорости на высоту и раскачивает скорость.
	return clampf(_netto_stf, -1.5, mc_ms * 0.9)


func _cruise_target(pos: Vector2, dt: float) -> Vector2:
	if not use_clouds or not clouds_fn.is_valid():
		return _line_target(pos)
	_cloud_timer -= dt
	if _has_cloud_target and pos.distance_to(_cloud_target) < 250.0:
		_visited_clouds.append(_cloud_target)
		_has_cloud_target = false
		_cloud_timer = 0.0
	if _cloud_timer <= 0.0:
		_cloud_timer = 5.0
		_pick_cloud(pos)
	return _cloud_target if _has_cloud_target else _line_target(pos)


## Прямая старт → цель: точка на линии на line_lookahead_m впереди (возврат на линию курса).
func _line_target(pos: Vector2) -> Vector2:
	var d := goal - route_start
	var len := d.length()
	if len < 1.0:
		return goal
	var u := d / len
	var s := clampf((pos - route_start).dot(u) + line_lookahead_m, 0.0, len)
	return route_start + u * s


## Цель под растущим облаком в секторе ±cloud_sector_deg от курса на цель — как пилот читает небо.
func _pick_cloud(pos: Vector2) -> void:
	var to_goal := goal - pos
	var dist_goal := to_goal.length()
	if dist_goal < 500.0:
		_has_cloud_target = false
		return
	var best := -1.0
	var best_c := Vector2.ZERO
	for c: Dictionary in clouds_fn.call():
		var cc: Vector2 = c.center
		var d := pos.distance_to(cc)
		if d < 300.0 or d > minf(8000.0, dist_goal + 500.0):
			continue
		var ang := absf(rad_to_deg((cc - pos).angle_to(to_goal)))
		if ang > cloud_sector_deg:
			continue
		if float(c.growth) < 0.3 or float(c.decay) > 0.3:
			continue
		var seen := false
		for v in _visited_clouds:
			if v.distance_to(cc) < 400.0:
				seen = true
				break
		if seen:
			continue
		var score := float(c.radius) * (1.0 - float(c.decay)) / (d + 1000.0) * cos(deg_to_rad(ang))
		if score > best:
			best = score
			best_c = cc
	_has_cloud_target = best > 0.0
	_cloud_target = best_c


# ================================================================ проба стороны


## kind: 1 — был край ядра (термик ближе), −1 — кольцо опускания (дальше). Термик — на
## перпендикуляре к курсу через точку самого сильного подъёма/опускания: облететь его
## в обе стороны (сначала — куда подсказывает крыло).
func _start_probe(_t: Telemetry, pos: Vector2, kind: int) -> void:
	mode = Mode.PROBE
	# Облёт по кругу вокруг середины неоднородности: термик где-то на расстоянии
	# ~радиуса (край ядра — ближе, кольцо — дальше). Сторона виража — куда подсказывает крыло
	# (FR-8: внутри ядра ближняя к оси консоль поднимается, рука держит крен к термику).
	var hint := _roll_sum / maxf(_roll_n, 1)
	var side := signf(hint) * float(kind)
	_probe_dir = side if side != 0.0 else 1.0
	_probe_c = _anom_pos
	_probe_r = probe_out_m * (0.55 if kind > 0 else 1.0)
	_probe_turned = 0.0
	_probe_prev = pos - _probe_c
	_probe_cooldown = 20.0
	_search_on = true


func _probe(t: Telemetry, pos: Vector2, _dt: float) -> void:
	var v := maxf(t.groundspeed, 5.0)
	var base := rad_to_deg(atan(v * v / (Units.G * _probe_r)))
	_hold_bank(t, _orbit_bank(t, pos, _probe_c, _probe_r, _probe_dir, base, 45.0))
	_set_speed(_v_min_sink * 1.15 * _speed_scale(t.altitude_msl), t)
	var rel := pos - _probe_c
	if rel.length() < _probe_r * 1.5:
		_probe_turned += absf(_probe_prev.angle_to(rel))
	_probe_prev = rel
	# Входим в явный подъём (не в угасающий край, который вызвал пробу).
	var thr := save_enter_netto_ms if save_mode else enter_netto_ms
	if _n_dec > thr and _n_peak > maxf(thr, _anom_ext) + (0.3 if _calm else 0.2):
		_start_enter(t)
		return
	if _probe_turned > TAU * 1.05:
		mode = Mode.CRUISE
		_search_on = false


## Крен для полёта по окружности радиуса r вокруг center (dir: +1 — вправо): базовый крен
## виража + поправка курса к касательной (дальше радиуса — к центру, ближе — наружу).
func _orbit_bank(
	t: Telemetry, pos: Vector2, center: Vector2, r: float, dir: float, base: float, lim: float
) -> float:
	var to_c := center - pos
	var dist := to_c.length()
	var bank := base * dir
	if dist > 1.0:
		var brg := rad_to_deg(atan2(to_c.x, -to_c.y))
		var corr := clampf((dist - r) * orbit_gain * 15.0 / maxf(r, 15.0), -60.0, 60.0)
		var want := brg - dir * (90.0 - corr)
		var err := wrapf(want - t.heading_deg, -180.0, 180.0)
		bank += clampf(err * orbit_bank_per_deg, -orbit_bank_max_deg, orbit_bank_max_deg)
	return dir * clampf(bank * dir, -lim, lim)


## Крен виража, сдвигающий круг к target (dir: +1 — вправо). Круг — в воздухе: центр виража
## (сбоку от носа на радиус по воздушной скорости) сносит ветром, поэтому желаемая скорость
## центра = (target − центр)/τ − ветер. Сдвиг — выполаживанием, когда нос смотрит туда, куда
## надо сдвинуть круг (и докручиванием, когда от него): за круг центр смещается на ≈ v·δ/2.
func _center_bank(t: Telemetry, pos: Vector2, target: Vector2, dir: float, base: float) -> float:
	var v := maxf(t.airspeed, 5.0)
	var tb := tan(deg_to_rad(base))
	var h := deg_to_rad(t.heading_deg)
	var fwd := Vector2(sin(h), -cos(h))
	var right := Vector2(cos(h), sin(h))
	var c := pos + right * (v * v / (Units.G * tb) * dir)
	var want := (target - c) / center_shift_tau_s - _wind_est + _lc_vel
	var delta := clampf(2.0 * want.dot(fwd) / v, -center_steepen_max, center_flatten_max)
	var bank := rad_to_deg(atan(tb * (1.0 - delta)))
	return dir * clampf(bank, circle_bank_min_deg, circle_bank_max_deg)


func _lagged_pos() -> Vector2:
	return _pos_hist[(_pos_i + _pos_hist.size() - _lag_fast) % _pos_hist.size()]


## Позиция середины окна скользящего среднего (≈ netto_box_s/2 + отклик крыла назад).
func _box_pos() -> Vector2:
	return _pos_hist[(_pos_i + 1) % _pos_hist.size()]


func _dec_pos() -> Vector2:
	return _lagged_pos() if _calm else _box_pos()


# ================================================================ вход и кружение


func _start_enter(t: Telemetry) -> void:
	mode = Mode.ENTER
	_enter_t = 0.0
	_enter_bank0 = t.bank_deg
	_enter_peak = _n_peak
	_anomaly = 0


func _enter(t: Telemetry, _pos: Vector2, dt: float) -> void:
	_enter_t += dt
	# Руки мягко: крен держим около нуля, чувствуем, какое крыло поднимает (FR-8).
	_ctl.roll = clampf(-t.bank_deg / 25.0 - _bank_rate / 40.0, -0.3, 0.3)
	_set_speed(_v_min_sink * _speed_scale(t.altitude_msl), t)
	_enter_peak = maxf(_enter_peak, _n_peak)
	var passed := _n_peak < _enter_peak - (0.2 if _calm else 0.15)
	if passed or _enter_t > (4.0 if _calm else 3.0):
		# Крыло подняло с той стороны, где подъём: крен в обратную сторону → туда и поворачиваем.
		var drift := t.bank_deg - _enter_bank0
		_dir = -1.0 if drift > 0.0 else 1.0
		_start_circle(t)
	var thr := save_enter_netto_ms if save_mode else enter_netto_ms
	if _n_peak < thr - 0.8:
		mode = Mode.CRUISE


func _start_circle(t: Telemetry) -> void:
	mode = Mode.CIRCLE
	_turned = 0.0
	_prev_heading = t.heading_deg
	_circle_t0 = _t
	_circle_alt0 = t.altitude_msl
	_circle_pos = Vector2.ZERO
	_circle_n = 0
	_th_t0 = _t
	_th_alt0 = t.altitude_msl
	_th_circles = 0
	_th_center = Vector2.ZERO
	_last_climb = 0.0
	_circle_best = -INF
	_weak_circles = 0
	_circle_c = _turn_center(t)
	_lc_vel = Vector2.ZERO
	# Первый круг — вокруг места самого сильного подъёма (если оно рядом).
	_fit.reset(_peak_pos, _peak_pos.distance_to(Vector2(t.position.x, t.position.z)) < 120.0)


func _circle(t: Telemetry, pos: Vector2, _dt: float) -> void:
	# Центровка: кружим, сдвигая круг к центру подъёма (_circle_target) — выполаживанием, когда
	# нос смотрит туда, куда надо сдвинуться (_center_bank).
	_hold_bank(t, _center_bank(t, pos, _circle_target(t), _dir, circle_bank_deg))
	_set_speed(_v_min_sink * 1.02 * _speed_scale(t.altitude_msl), t)
	var dh := absf(wrapf(t.heading_deg - _prev_heading, -180.0, 180.0))
	_turned += dh
	_prev_heading = t.heading_deg
	_fit.add(_lagged_pos(), _netto_fast, dh)
	_circle_pos += pos
	_circle_n += 1
	_circle_best = maxf(_circle_best, _netto_fast)
	var near_base := t.altitude_msl > cloudbase_msl - cloudbase_margin_m
	if _turned >= 360.0:
		_turned -= 360.0
		var dur := _t - _circle_t0
		_last_climb = (t.altitude_msl - _circle_alt0) / maxf(dur, 1.0e-3)
		var c := _circle_pos / maxf(_circle_n, 1)
		circles.append({"climb_ms": _last_climb, "center": c, "alt_m": t.altitude_msl, "t_s": _t})
		_th_circles += 1
		_th_center += c
		_circle_t0 = _t
		_circle_alt0 = t.altitude_msl
		_circle_pos = Vector2.ZERO
		_circle_n = 0
		if _circle_weak_exit():
			_exit_thermal(t, pos)
			return
	if _circle_lost(t) or near_base:
		_exit_thermal(t, pos)


## Взять управление вместо обычных режимов (переопределяет диагностический пилот).
func _take_over(_t: Telemetry, _pos: Vector2, _dt: float) -> bool:
	return false


## Куда сдвигать круг: центр по первой гармонике, до первой оценки — карта подъёма.
func _circle_target(_t: Telemetry) -> Vector2:
	if _fit.ok:
		return _fit.target
	return _lift_c if _lift_w > 0.05 else _circle_c


## После полного круга: бросить ли термик (слабый круг и не видно, что ядро рядом).
func _circle_weak_exit() -> bool:
	var thr_weak := 0.05 if save_mode else mc_ms * 0.6
	var weak := _last_climb < thr_weak
	# Слабый круг, но рядом был сильный подъём — круг ещё не отцентрован, не бросаем
	# (не больше двух таких кругов подряд).
	var promising := _circle_best > mc_ms + 0.7
	if _fit.ok:
		# В болтанке максимум вариометра — порыв; сильная сторона по гармонике честнее.
		promising = _fit.peak - _own_sink > thr_weak + 0.3
		# После первого круга (вход редко точный) — дать сдвинуть круг, если подъём был.
		promising = promising or (_th_circles == 1 and _fit.peak > 0.5)
		# Круг на склоне подъёма (большой перепад, сильная сторона лучше порога) — ядро рядом.
		promising = promising or (_fit.amp > 0.5 and _fit.peak - _own_sink > thr_weak)
	promising = promising and _weak_circles < 2
	_weak_circles = _weak_circles + 1 if weak else 0
	_circle_best = -INF
	return weak and not promising


## Первый круг провалился (потеряли подъём) — не ждём полного круга.
func _circle_lost(t: Telemetry) -> bool:
	var lost := _th_circles == 0 and _circle_best < mc_ms + 1.0
	return lost and _t - _th_t0 > 25.0 and t.altitude_msl < _th_alt0 - 10.0


## Карта подъёма в круге: центр круга (среднее позиций) и «центр тяжести» подъёма — позиции,
## где вариометр был выше среднего (позиция берётся с запаздыванием отклика крыла).
## Центр будущего/текущего виража: сбоку от курса на радиус разворота.
func _turn_center(t: Telemetry) -> Vector2:
	var v := maxf(t.groundspeed, 5.0)
	var r := v * v / (Units.G * tan(deg_to_rad(circle_bank_deg)))
	var h := deg_to_rad(t.heading_deg)
	var right := Vector2(cos(h), sin(h))
	return Vector2(t.position.x, t.position.z) + right * r * _dir


## Вызывается каждый шаг во всех режимах: подъём, замеченный на прямой, тоже на карте.
func _update_lift_map(t: Telemetry, pos: Vector2, dt: float) -> void:
	var kc := 1.0 - exp(-dt / centering_tau_s)
	_circle_c += (pos - _circle_c) * kc
	_vario_long += (t.vario - _vario_long) * kc
	var lagged := _lagged_pos()
	if mode != Mode.CIRCLE:
		_circle_c = pos
	var w := maxf(0.0, _vario_s - _vario_long)
	var decay := exp(-dt / centering_tau_s)
	_lift_w = _lift_w * decay + w * dt
	_lift_sum = _lift_sum * decay + lagged * w * dt
	if _lift_w > 1.0e-3:
		_lift_c = _lift_sum / _lift_w


func _exit_thermal(t: Telemetry, pos: Vector2) -> void:
	if _th_circles > 0:
		var gain := t.altitude_msl - _th_alt0
		var dur := _t - _th_t0
		(
			thermals
			. append(
				{
					"circles": _th_circles,
					"gain_m": gain,
					"time_s": dur,
					"climb_ms": gain / maxf(dur, 1.0e-3),
					"center": _th_center / _th_circles,
					"exit": pos,
					"top_m": t.altitude_msl,
				}
			)
		)
	mode = Mode.CRUISE
	_no_enter_pos = pos
	_no_enter_r = 350.0
	_anomaly = 0
	_probe_cooldown = 30.0
	# Не нашли ядро с первого круга — продолжить облёт найденной неоднородности.
	var failed := t.altitude_msl - _th_alt0 < 5.0
	if failed and _search_on and pos.distance_to(_probe_c) < _probe_r * 2.0:
		mode = Mode.PROBE
		_probe_prev = pos - _probe_c
		_no_enter_r = 0.0
	else:
		_search_on = false


# ================================================================ управление


func _mc_setting() -> float:
	if thermals.is_empty():
		return 0.8
	var s := 0.0
	var n := 0
	for i in range(maxi(0, thermals.size() - 4), thermals.size()):
		s += float(thermals[i].climb_ms)
		n += 1
	return clampf(s / n * mc_factor, mc_min_ms, mc_max_ms)


## Скорость по МакКриди: максимум v / (s(v) + MC − w), w — нетто воздуха.
## Поляра — при эталонной плотности; на высоте скорости и снижение ×k (k — масштаб скорости).
func _stf(w: float, alt: float) -> float:
	var k := _speed_scale(alt)
	# Пересчёт не чаще раза в 0,25 с (перебор поляры).
	if _t - _stf_t < 0.25:
		return _stf_v
	_stf_t = _t
	_stf_v = _stf_calc(w, k)
	return _stf_v


func _stf_calc(w: float, k: float) -> float:
	var best_v := _v_min_sink
	var best := -INF
	for i in _polar_v.size():
		var denom := _polar_s[i] * k + mc_ms - minf(w, mc_ms * 0.9)
		var q := _polar_v[i] / maxf(denom, 0.05)
		if q > best:
			best = q
			best_v = _polar_v[i]
	return best_v * k


func _set_speed(v: float, t: Telemetry) -> void:
	# Скорость меняем плавно — как пилот двигает трапецию.
	_v_cmd = move_toward(_v_cmd, v, speed_slew_ms2 * _dt)
	_ctl.pitch = _pitch_for(_v_cmd, t.altitude_msl)


## Трапеция для воздушной скорости v (м/с) на высоте alt: линейно между «на себя», тримом
## и «от себя» (как в FlightModel), скорости трапеции — при эталонной плотности.
func _pitch_for(v: float, alt: float) -> float:
	var v_ref := v / _speed_scale(alt)
	var p := 0.0
	if v_ref > _v_trim:
		p = -(v_ref - _v_trim) / (_v_pull - _v_trim)
	else:
		p = (_v_trim - v_ref) / (_v_trim - _v_push)
	return clampf(p, -1.0, 1.0)


## Трапеция, с которой бот кружит в термике на высоте alt (для эталона снижения на вираже).
func circle_pitch(alt: float) -> float:
	return _pitch_for(_v_min_sink * 1.02 * _speed_scale(alt), alt)


func _steer_heading(t: Telemetry, want_deg: float, max_bank: float) -> void:
	var err := wrapf(want_deg - t.heading_deg, -180.0, 180.0)
	_hold_bank(t, clampf(err * 0.9, -max_bank, max_bank))


func _hold_bank(t: Telemetry, want: float) -> void:
	var e := want - (t.bank_deg + _bank_rate * 0.35)
	_ctl.roll = clampf(e / 8.0, -1.0, 1.0)


func _bearing_deg(from: Vector2, to: Vector2) -> float:
	var d := to - from
	return fposmod(rad_to_deg(atan2(d.x, -d.y)), 360.0)


# ================================================================ поляра


func _speed_scale(alt: float) -> float:
	# Плотность меняется медленно — пересчёт, когда высота ушла на 5 м.
	if absf(alt - _k_alt) > 5.0:
		_k_alt = alt
		_fm.rho = _fm.air_density(alt)
		_k_cached = _fm.speed_scale()
	return _k_cached


func _build_polar(alt: float) -> void:
	_fm.rho = _fm.air_density(alt)
	_polar_v.clear()
	_polar_s.clear()
	var best_s := 1.0e9
	var v := _v_push
	while v <= _v_pull:
		var s := _fm.steady_glide(v).y
		_polar_v.append(v)
		_polar_s.append(s)
		if s < best_s:
			best_s = s
			_v_min_sink = v
		v += POLAR_STEP


## Снижение по поляре на скорости v (м/с) на высоте alt (плотность — через масштаб скорости).
func _sink_at(v: float, alt: float) -> float:
	var k := _speed_scale(alt)
	# Таблица равномерная (шаг POLAR_STEP от _polar_v[0]).
	var x := (v / k - _polar_v[0]) / POLAR_STEP
	var n := _polar_v.size()
	if x <= 0.0:
		return _polar_s[0] * k
	var i := int(x)
	if i >= n - 1:
		return _polar_s[n - 1] * k
	return lerpf(_polar_s[i], _polar_s[i + 1], x - i) * k
