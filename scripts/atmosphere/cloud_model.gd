class_name CloudModel
extends RefCounted
## Логика облаков без нод (тестируется headless). Две половины:
## - физическая (stage, size, center, _life_window по AtmoThermal) — только для GDScript-реализации
##   (старый GD-расчёт, Atmosphere) до RW-13; в крейте то же считает cloud_objects (W6 v4);
## - выбор для рисования (select*, merge_winners, life_fade, range_fade, far_m, step_fade) — по
##   записям cloud_objects (Obj), без AtmoThermal: ею пользуется CloudLayer.

## Принудительная стадия облака по id термика (для тестовой сцены):
## Vector3(рост, распад, активность).
var stage_override: Dictionary = {}
## Множитель размера облаков из пресета погоды (покрытие неба).
var size_factor: float = 1.0

var _cfg: Dictionary
# Коэффициенты из конфига (словарь в горячем цикле медленный).
var _delay_k: float = 0.6
var _grow_s: float = 300.0
var _linger_s: float = 240.0
var _w_per_ms: float = 300.0
var _w_min: float = 350.0
var _w_max: float = 1800.0
var _overdev_k: float = 2.4
var _overdev_spread: float = 0.7
var _hw_min: float = 0.45
var _hw_max: float = 0.9
var _cb_w_max: float = 8000.0
var _cb_range_k: float = 2.0
var _fade_in_s: float = 40.0
var _fade_out_s: float = 60.0
var _fade_band_m: float = 3000.0


func setup(clouds_cfg: Dictionary, weather_size_factor: float = 1.0) -> void:
	_cfg = clouds_cfg
	size_factor = weather_size_factor
	_delay_k = float(_cfg.delay_factor)
	_grow_s = float(_cfg.grow_s)
	_linger_s = float(_cfg.linger_s)
	_w_per_ms = float(_cfg.width_per_ms_m)
	_w_min = float(_cfg.width_min_m)
	_w_max = float(_cfg.width_max_m)
	_overdev_k = float(_cfg.overdev_depth_factor)
	_overdev_spread = float(_cfg.overdev_spread)
	_hw_min = float(_cfg.height_to_width[0])
	_hw_max = float(_cfg.height_to_width[1])
	_cb_w_max = float(_cfg.get("cb_width_max_m", 8000.0))
	_cb_range_k = float(_cfg.get("cb_range_factor", 2.0))
	_fade_in_s = float(_cfg.get("fade_in_s", 40.0))
	_fade_out_s = float(_cfg.get("fade_out_s", 60.0))
	_fade_band_m = float(_cfg.get("fade_band_m", 3000.0))


## Стадия облака над термиком в момент t: Vector3(рост 0..1, распад 0..1, активность 0..1).
## x < 0 — облака нет (слабый термик, ещё не выросло или уже растаяло).
func stage(th: AtmoThermal, t: float) -> Vector3:
	if not th.has_cloud:
		return Vector3(-1, 0, 0)
	if stage_override.has(th.id):
		return stage_override[th.id]
	if th.is_static:
		return Vector3(1, 0, 1)
	var w := _life_window(th)
	var c0 := w.x
	if t <= c0:
		return Vector3(-1, 0, 0)
	var g := smoothstep(c0, c0 + _grow_s, t)
	var d0 := w.y
	var d1 := w.z
	var dcy := clampf((t - d0) / maxf(d1 - d0, 1.0), 0.0, 1.0)
	if g <= 0.0 or dcy >= 1.0:
		return Vector3(-1, 0, 0)
	return Vector3(g, dcy, th.envelope(t))


## Окно жизни облака: Vector3(появление, начало распада облака, конец — облака нет), с.
func _life_window(th: AtmoThermal) -> Vector3:
	# Облако появляется, когда воздух дошёл до кромки, и растёт, пока термик жив.
	var span := th.top - th.src.y
	var delay := minf(span / maxf(th.strength, 0.5) * _delay_k, th.t_grow + th.t_mature * 0.5)
	var ds := th.t_birth + th.t_grow + th.t_mature
	return Vector3(th.t_birth + delay, ds + delay * 0.3, ds + th.t_decay + _linger_s)


## Объект-облако — одна запись `cloud_objects` на момент `t_rec` (поля — W6 v4, OBJ_*).
class Obj:
	extends RefCounted
	var id: int = 0
	var is_static: bool = false
	var is_cb: bool = false
	## Центр основания (x, z) на t_rec, м.
	var c: Vector2 = Vector2.ZERO
	var t_rec: float = 0.0
	var base_msl: float = 0.0
	## Стадия на t_rec: Vector3(рост, распад, активность).
	var stage: Vector3 = Vector3.ZERO
	## Размеры: Vector4(полуось по ветру, поперёк, мощность, растекание верха), м.
	var size: Vector4 = Vector4.ZERO
	var vis_seed: int = 0
	var life_t0: float = 0.0
	var life_t1: float = 0.0
	var src: Vector2 = Vector2.ZERO
	var drift_v: Vector2 = Vector2.ZERO
	var drift_t0: float = 0.0
	var storm_t0: float = 0.0
	var storm_k: float = 0.0

	## Центр в момент t: снос линейный от drift_t0 (W6 v4), вызова в крейт не нужно.
	func center_at(t: float) -> Vector2:
		return c + drift_v * (maxf(0.0, t - drift_t0) - maxf(0.0, t_rec - drift_t0))

	## Смещение источника термика к моменту t (снос после начала распада).
	func drift_at(t: float) -> Vector2:
		return drift_v * maxf(0.0, t - drift_t0)

	## Облако существует в момент t (стадия x ≥ 0 в терминах прежней модели).
	func alive(t: float) -> bool:
		return is_static or (t > life_t0 and t < life_t1)


## Записи cloud_objects -> {id: Obj}, порядок по возрастанию id (как в записи). t — момент запроса.
static func parse(rec: PackedFloat32Array, t: float) -> Dictionary:
	var out: Dictionary = {}
	var stride := Atmosphere.OBJ_STRIDE
	@warning_ignore("integer_division")
	var n := rec.size() / stride
	for i in n:
		var o := i * stride
		var ob := Obj.new()
		ob.id = int(rec[o + Atmosphere.OBJ_ID])
		var flags := int(rec[o + Atmosphere.OBJ_FLAGS])
		ob.is_static = (flags & 1) != 0
		ob.is_cb = (flags & 4) != 0
		ob.c = Vector2(rec[o + Atmosphere.OBJ_CX], rec[o + Atmosphere.OBJ_CZ])
		ob.t_rec = t
		ob.base_msl = rec[o + Atmosphere.OBJ_BASE]
		ob.stage = Vector3(
			rec[o + Atmosphere.OBJ_GROWTH],
			rec[o + Atmosphere.OBJ_DECAY],
			rec[o + Atmosphere.OBJ_ACTIVITY]
		)
		ob.size = Vector4(
			rec[o + Atmosphere.OBJ_RX],
			rec[o + Atmosphere.OBJ_RZ],
			rec[o + Atmosphere.OBJ_DEPTH],
			rec[o + Atmosphere.OBJ_SPREAD]
		)
		ob.vis_seed = int(rec[o + Atmosphere.OBJ_VIS_SEED])
		ob.life_t0 = rec[o + Atmosphere.OBJ_LIFE_T0]
		ob.life_t1 = rec[o + Atmosphere.OBJ_LIFE_T1]
		ob.src = Vector2(rec[o + Atmosphere.OBJ_SRC_X], rec[o + Atmosphere.OBJ_SRC_Z])
		ob.drift_v = Vector2(rec[o + Atmosphere.OBJ_DRIFT_VX], rec[o + Atmosphere.OBJ_DRIFT_VZ])
		ob.drift_t0 = rec[o + Atmosphere.OBJ_DRIFT_T0]
		ob.storm_t0 = rec[o + Atmosphere.OBJ_STORM_T0]
		ob.storm_k = rec[o + Atmosphere.OBJ_STORM_K]
		out[ob.id] = ob
	return out


## Видимость облака по жизненному циклу 0..1: в начале проявляется, в конце linger тает до нуля
## (без этого на распаде оставалось ~20 % плотности, и облако выключалось целиком за кадр).
## Физика (подсос, стадия) от неё не зависит.
func life_fade(ob: Obj, t: float) -> float:
	if ob.is_static:
		return 1.0
	var fin := smoothstep(ob.life_t0, ob.life_t0 + _fade_in_s, t)
	var fout := 1.0 - smoothstep(ob.life_t1 - _fade_out_s, ob.life_t1, t)
	return fin * fout


## Видимость по дальности 0..1: к границе far облако тает в полосе fade_band_m, а не срезается.
func range_fade(d: float, far: float) -> float:
	return 1.0 - smoothstep(far - _fade_band_m, far, d)


## Дальность, до которой рисуется облако, м (у Cb — больше).
func far_m(ob: Obj) -> float:
	var max_d := float(_cfg.max_distance_m)
	return max_d * float(_cfg.get("cb_range_factor", 2.0)) if ob.is_cb else max_d


## Шаг видимости облака к цели (1 — выбрано для отрисовки, 0 — выбыло) за dt: плавно,
## проявление за fade_in_s, таяние за fade_out_s.
func step_fade(cur: float, target: float, dt: float) -> float:
	if target > cur:
		return minf(cur + dt / maxf(_fade_in_s, 0.001), target)
	return maxf(cur - dt / maxf(_fade_out_s, 0.001), target)


## Центр основания облака (x, z): верх наклонённого столба + снос на распаде.
func center(th: AtmoThermal, t: float) -> Vector2:
	return th.cloud_center(t)


## Размеры: Vector4(полуось по ветру, полуось поперёк, мощность, растекание верха), м.
func size(th: AtmoThermal, st: Vector3) -> Vector4:
	var g := st.x
	var dcy := st.y
	var width := clampf(_w_per_ms * th.strength * size_factor, _w_min, _w_max)
	if th.is_cb:
		width = clampf(width * 3.0, _w_max, _cb_w_max)
	# Растёт вширь, на распаде расползается.
	var rz := width * 0.5 * (0.55 + 0.45 * g) * (1.0 + 0.3 * dcy)
	var rx := rz * th.cloud_stretch
	var od := th.overdevelop * g
	# Кучевые хорошей погоды шире, чем выше: мощность в пределах доли ширины.
	var depth := clampf(th.cloud_depth, width * _hw_min, width * _hw_max)
	if th.is_cb:
		# Верх Cb — тропопауза: мощность задана, переразвитие её не умножает.
		depth = th.cloud_depth
		od = 0.0
	var h := (
		depth
		* (1.0 + od * (_overdev_k - 1.0))
		* (0.3 + 0.7 * g)
		* (1.0 - 0.35 * dcy)
	)
	var spread := od * _overdev_spread * smoothstep(0.3, 1.0, g)
	return Vector4(rx, rz, h, spread)


## Видимые облака вокруг eye: [расстояние, объект, стадия, центр, полуось] — ближние первыми,
## не больше max_clouds; наложившиеся сливаются в одно (остаётся зрелое и крупное).
## shown — id уже нарисованных облаков: при наложении они в приоритете (select_hysteresis),
## иначе при равных очках (у зрелых полуось упирается в максимум) из пары наложившихся
## каждый выбор брал случайное — облака мерцали, подменяя друг друга. При обрезке по
## max_clouds нарисованные тоже в приоритете (их дальность делится на select_hysteresis).
## Выбывшее облако CloudLayer не выключает, а растворяет (step_fade).
## objs — {id: Obj} на момент t (parse).
func select(objs: Dictionary, t: float, eye: Vector3, shown: Dictionary = {}) -> Array:
	var cand: Array = []
	for id in objs:
		var e := select_entry(objs[id], t, eye, shown)
		if not e.is_empty():
			cand.append(e)
	return select_finish(cand, shown)


## Кандидат выбора (PF-8: CloudLayer набирает их порциями по кадрам): [расстояние, объект, стадия,
## центр, полуось, очки] или [], если облако не годится.
func select_entry(ob: Obj, t: float, eye: Vector3, shown: Dictionary) -> Array:
	if not ob.alive(t):
		return []
	var st := ob.stage
	var c := ob.center_at(t)
	var d := Vector2(eye.x, eye.z).distance_to(c)
	# Cb видно издалека (башня до тропопаузы) — у них дальность больше.
	if d > far_m(ob):
		return []
	var r := ob.size.x
	var score := r * st.x * (1.0 - st.y)
	if shown.has(ob.id):
		score *= float(_cfg.get("select_hysteresis", 1.25))
	return [d, ob, st, c, r, score]


## Остаток выбора по набранным кандидатам: слияние наложившихся, обрезка по лимиту, порядок
## по дальности.
func select_finish(cand: Array, shown: Dictionary = {}) -> Array:
	var st := drop_begin(sort_by_score(cand))
	drop_step(st, 1 << 60)
	return select_tail(st.out, shown)


## Кандидаты по очкам убыванию, при равных — по id (родная сортировка по ключу, без вызовов).
static func sort_by_score(cand: Array) -> Array:
	var keys: Array = []
	for i in cand.size():
		var e: Array = cand[i]
		keys.append([-float(e[5]), (e[1] as Obj).id, i])
	keys.sort()
	var out: Array = []
	out.resize(cand.size())
	for j in keys.size():
		out[j] = cand[keys[j][2]]
	return out


## Слияние наложившихся порциями (drop_begin / drop_step): состояние — словарь.
func drop_begin(sorted_cand: Array) -> Dictionary:
	return {"cand": sorted_cand, "i": 0, "grid": {}, "out": []}


## true — просмотрены все кандидаты; работает до момента dl (мкс, Time.get_ticks_usec).
func drop_step(st: Dictionary, dl: int) -> bool:
	var k := float(_cfg.merge_overlap)
	var cell := float(_cfg.width_max_m)
	var cand: Array = st.cand
	var grid: Dictionary = st.grid
	var out: Array = st.out
	var i: int = st.i
	var n := cand.size()
	while i < n:
		var e: Array = cand[i]
		i += 1
		var c: Vector2 = e[3]
		var gx := floori(c.x / cell)
		var gz := floori(c.y / cell)
		if not _overlaps(grid, gx, gz, e, k):
			out.append(e)
			var key := Vector2i(gx, gz)
			if not grid.has(key):
				grid[key] = []
			grid[key].append(e)
		if (i & 15) == 0 and Time.get_ticks_usec() >= dl:
			break
	st.i = i
	return i >= n


## Обрезка по лимиту и порядок по дальности.
func select_tail(list: Array, shown: Dictionary) -> Array:
	var hyst := float(_cfg.get("select_hysteresis", 1.25))
	var cap := int(_cfg.max_clouds)
	if list.size() > cap:
		# Обрезка по лимиту: нарисованные «ближе» в hyst раз — облако у границы не мигает.
		list = list.duplicate()
		list.sort_custom(
			func(a: Array, b: Array) -> bool:
				return _cap_key(a, shown, hyst) < _cap_key(b, shown, hyst)
		)
		list.resize(cap)
	list.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	return list


## Облака, которые рисуются из наложившихся (NET-00): id -> true. Чистая функция записей на t —
## не зависит ни от камеры, ни от того, что рисовалось раньше, поэтому два клиента в одно время
## зоны получают одно и то же (и только что вошедший — тоже).
## Из наложившихся остаётся более крупное и зрелое, при равных очках — меньший id.
## horizon_s: облако, которое кончится раньше t + horizon_s, в слиянии уже не участвует —
## его термик к концу окна проявления уйдёт из поля, и клиент, считающий это окно позже
## (вошёл в зону), его уже не знает; уступает соседу заранее и плавно.
## objs — записи cloud_objects на тот же момент t.
func merge_winners(objs: Dictionary, t: float, horizon_s: float = 0.0) -> Dictionary:
	var cand: Array = []
	for id in objs:
		var ob: Obj = objs[id]
		if horizon_s > 0.0 and not ob.is_static and ob.life_t1 <= t + horizon_s:
			continue
		if not ob.alive(t):
			continue
		var r := ob.size.x
		cand.append([0.0, ob, ob.stage, ob.center_at(t), r, r * ob.stage.x * (1.0 - ob.stage.y)])
	cand.sort_custom(_by_score)
	var out: Dictionary = {}
	for e: Array in _drop_overlaps(cand):
		out[(e[1] as Obj).id] = true
	return out


static func _cap_key(e: Array, shown: Dictionary, hyst: float) -> float:
	var d := float(e[0])
	return d / hyst if shown.has((e[1] as Obj).id) else d


## Очки по убыванию, при равных — по id (порядок не зависит от словаря и сортировки).
static func _by_score(a: Array, b: Array) -> bool:
	if a[5] != b[5]:
		return a[5] > b[5]
	return (a[1] as Obj).id < (b[1] as Obj).id


## Два объёма в одном месте смешиваются в неверном порядке — рисуем одно, крупное.
## Физика термиков от этого не меняется.
func _drop_overlaps(cand: Array) -> Array:
	var k := float(_cfg.merge_overlap)
	var cell := float(_cfg.width_max_m)
	var grid: Dictionary = {}
	var out: Array = []
	for e: Array in cand:
		var c: Vector2 = e[3]
		var gx := floori(c.x / cell)
		var gz := floori(c.y / cell)
		if _overlaps(grid, gx, gz, e, k):
			continue
		out.append(e)
		var key := Vector2i(gx, gz)
		if not grid.has(key):
			grid[key] = []
		grid[key].append(e)
	return out


func _overlaps(grid: Dictionary, gx: int, gz: int, e: Array, k: float) -> bool:
	var c: Vector2 = e[3]
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			for o: Array in grid.get(Vector2i(gx + dx, gz + dz), []):
				if c.distance_to(o[3]) < (float(e[4]) + float(o[4])) * k:
					return true
	return false
