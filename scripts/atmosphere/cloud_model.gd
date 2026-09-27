class_name CloudModel
extends RefCounted
## Логика облаков без нод (тестируется headless): стадия облака из жизненного цикла термика,
## положение, размеры, выбор видимых облаков и слияние наложившихся.
## Рисует CloudLayer.

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


## Стадия облака над термиком в момент t: Vector3(рост 0..1, распад 0..1, активность 0..1).
## x < 0 — облака нет (слабый термик, ещё не выросло или уже растаяло).
func stage(th: AtmoThermal, t: float) -> Vector3:
	if not th.has_cloud:
		return Vector3(-1, 0, 0)
	if stage_override.has(th.id):
		return stage_override[th.id]
	if th.is_static:
		return Vector3(1, 0, 1)
	# Облако появляется, когда воздух дошёл до кромки, и растёт, пока термик жив.
	var span := th.top - th.src.y
	var delay := minf(span / maxf(th.strength, 0.5) * _delay_k, th.t_grow + th.t_mature * 0.5)
	var c0 := th.t_birth + delay
	if t <= c0:
		return Vector3(-1, 0, 0)
	var g := smoothstep(c0, c0 + _grow_s, t)
	var ds := th.t_birth + th.t_grow + th.t_mature
	var d0 := ds + delay * 0.3
	var d1 := ds + th.t_decay + _linger_s
	var dcy := clampf((t - d0) / maxf(d1 - d0, 1.0), 0.0, 1.0)
	if g <= 0.0 or dcy >= 1.0:
		return Vector3(-1, 0, 0)
	return Vector3(g, dcy, th.envelope(t))


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


## Видимые облака вокруг eye: [расстояние, термик, стадия, центр, полуось] — ближние первыми,
## не больше max_clouds; наложившиеся сливаются в одно (остаётся зрелое и крупное).
## shown — id уже нарисованных облаков: при наложении они в приоритете (select_hysteresis),
## иначе при равных очках (у зрелых полуось упирается в максимум) из пары наложившихся
## каждый выбор брал случайное — облака мерцали, подменяя друг друга.
func select(thermals: Dictionary, t: float, eye: Vector3, shown: Dictionary = {}) -> Array:
	var max_d := float(_cfg.max_distance_m)
	var cand: Array = []
	for id in thermals:
		var th: AtmoThermal = thermals[id]
		if not th.has_cloud:
			continue
		var st := stage(th, t)
		if st.x < 0.0:
			continue
		var c := center(th, t)
		var d := Vector2(eye.x, eye.z).distance_to(c)
		# Cb видно издалека (башня до тропопаузы) — у них дальность больше.
		if d > (max_d * _cb_range_k if th.is_cb else max_d):
			continue
		var r := size(th, st).x
		var score := r * st.x * (1.0 - st.y)
		if shown.has(th.id):
			score *= float(_cfg.get("select_hysteresis", 1.25))
		cand.append([d, th, st, c, r, score])
	cand.sort_custom(_by_score)
	var list := _drop_overlaps(cand)
	list.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	if list.size() > int(_cfg.max_clouds):
		list.resize(int(_cfg.max_clouds))
	return list


## Очки по убыванию, при равных — по id (порядок не зависит от словаря и сортировки).
static func _by_score(a: Array, b: Array) -> bool:
	if a[5] != b[5]:
		return a[5] > b[5]
	return (a[1] as AtmoThermal).id < (b[1] as AtmoThermal).id


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
