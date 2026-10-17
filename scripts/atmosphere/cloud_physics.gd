class_name CloudPhysics
extends RefCounted
## Облака в физике (FR-14b): облачный подсос и поток внутри облака, «в облаке ли точка».
##
## Кучевые облака — поле облачности CloudField (CLF-К1): оно живёт здесь, в симуляции (облака нужны
## физике и без CloudLayer: headless, боты, сеть). Шаг поля — в рабочем потоке (WorkerThreadPool, по
## образцу AirJob, PF-К4): refresh собирает снимок входов и запускает задачу, физика читает
## `field` — прежнее состояние, подменяемое целиком по готовности задачи. Кучево-дождевые (Cb) —
## по-прежнему облака-объекты (CloudModel): их подсос и купол считаются старой формой.
##
## Под крупным растущим/зрелым кучевым подъём у основания УСИЛИВАЕТСЯ: выше уровня конденсации
## воздух получает скрытое тепло, его плавучесть растёт, и сходимость потока под облаком тянет
## воздух к основанию («cloud suck»). В облаке восходящий поток сохраняется почти до верхушки.
## Под мелкими, молодыми и распадающимися облаками подсоса нет — подъём у кромки слабеет.
## Сила подсоса — от размера, зрелости и активности облака (поле: покрытие, мощность, стадия,
## активность над термиком), параметры — thermal.suck_* в конфиге.

## Меньше этого подсоса нет (иначе крошечный подсос отменяет спад подъёма у кромки).
const _MIN_K := 0.02

## Модель облаков (общая с CloudLayer): стадии и размеры облаков-объектов (Cb).
var model: CloudModel = CloudModel.new()

## Поле облачности, которое читает физика (подменяется целиком по готовности задачи).
var field: CloudField
## Шаг поля — в рабочем потоке (false — синхронно, как AirJob при air_async = false).
var async_field: bool = true
## Ждать задачу к следующему refresh (детерминизм: результат подменяется в момент refresh, а не
## когда успел поток) — в headless (тесты, ведущий без экрана) всегда; с экраном не стоять.
var deterministic: bool = DisplayServer.get_name() == "headless"
## Входы поля (ставит ThermalField): Callable(t) -> {air, wind_field, weather, cloudbase_msl,
## ground_ref, wind_at, seed} или пусто (поле выключено).
var inputs_fn: Callable
## Облачность поля над термиком не меньше этого — «над термиком есть облако» (thermal.cloud_cover_min).
var cover_min: float = 0.1

var _boost: float = 0.6
var _size_min: float = 700.0
var _size_full: float = 1600.0
var _in_cloud_frac: float = 0.8
var _hw: float = 0.65
var _cell: float = 2000.0
## Облака-объекты (Cb) рядом: [cx, cz, кромка, мощность, rx, rz, плотность, ax.x, ax.z] по сетке.
var _grid: Dictionary = {}
var _count: int = 0
## Ниже самой низкой кромки и выше самой высокой верхушки облаков нет — быстрый отсев.
var _y_min: float = 1.0e9
var _y_max: float = -1.0e9

## Поле: рабочая копия (её шагает поток), идущая задача, число столбцов с облаком у фокуса.
var _work: CloudField
var _job: FieldJob
var _field_count: int = 0
var _field_top: float = 0.0
var _inputs_key: String = ""
var _cf_cfg: Dictionary = {}
var _depth_max: float = 2500.0


## Задача шага поля: вход — снимок, выход — рабочее поле на момент t (поток только считает).
class FieldJob:
	extends RefCounted
	var work: CloudField
	var inp: Dictionary = {}
	var set_inp := false
	## Живые термики (ссылки): поток сам снимает с них копии на момент t — аналитический путь.
	var thermals: Array = []
	var t := 0.0
	var focus := Vector2.ZERO
	var radius := 0.0
	var task := -1
	var count := 0
	## Копии выходов на момент t (PackedArray в GDScript — по ссылке, поток дальше пишет в свои).
	var cover := PackedFloat32Array()
	var depth := PackedFloat32Array()
	var stage := PackedFloat32Array()
	var activity := PackedFloat32Array()
	var hc := PackedFloat32Array()

	func run() -> void:
		if set_inp:
			if not thermals.is_empty() or inp.get("air") == null:
				inp = inp.duplicate()
				inp["thermals"] = CloudPhysics.snapshot_thermals(thermals, t)
			work.set_inputs(inp)
		work.step_to(t)
		var cov := work.cover
		var r2 := radius * radius
		var n := 0
		for j in work.ny:
			var z := -(work.y0 + (j + 0.5) * work.dx)
			var dz := z - focus.y
			for i in work.nx:
				if cov[j * work.nx + i] >= 0.05:
					var dxx := work.x0 + (i + 0.5) * work.dx - focus.x
					if dxx * dxx + dz * dz <= r2:
						n += 1
		count = n
		cover = work.cover.duplicate()
		depth = work.depth.duplicate()
		stage = work.stage.duplicate()
		activity = work.activity.duplicate()
		hc = work._hc.duplicate()


func setup(clouds_cfg: Dictionary, thermal_cfg: Dictionary, size_factor: float) -> void:
	model.setup(clouds_cfg, size_factor)
	_boost = float(thermal_cfg.suck_boost)
	_size_min = float(thermal_cfg.suck_size_m[0])
	_size_full = float(thermal_cfg.suck_size_m[1])
	_in_cloud_frac = float(thermal_cfg.in_cloud_frac)
	cover_min = float(thermal_cfg.get("cloud_cover_min", cover_min))
	var hw: Array = clouds_cfg.height_to_width
	_hw = maxf(0.5 * (float(hw[0]) + float(hw[1])), 0.1)
	_cell = float(clouds_cfg.width_max_m)
	_cf_cfg = Config.get_config("atmosphere").get("cloud_field", {}).duplicate()
	_depth_max = float(_cf_cfg.get("depth_max_m", 2500.0))
	field = CloudField.new(_cf_cfg)
	_work = CloudField.new(_cf_cfg)


## Поле включено в конфиге.
func field_enabled() -> bool:
	return bool(_cf_cfg.get("enabled", true))


## Подсос термика в момент t: Vector2(усиление подъёма у основания 0.., высота потока в облаке, м).
func suck(th: AtmoThermal, t: float) -> Vector2:
	if th.has_cloud:
		return _suck_object(th, t)
	return _suck_field(th, t)


## Облако-объект (Cb): размер и стадия — CloudModel.
func _suck_object(th: AtmoThermal, t: float) -> Vector2:
	var st := model.stage(th, t)
	if st.x < 0.0:
		return Vector2(th.suck, 0.0)
	var sz := model.size(th, st)
	var diam := 2.0 * minf(sz.x, sz.y)
	# Растущее и зрелое, пока термик жив; не молодое, не распадающееся, не мелкое.
	var k := smoothstep(_size_min, _size_full, diam) * smoothstep(0.3, 0.8, st.x)
	k *= 1.0 - smoothstep(0.0, 0.35, st.y)
	k *= st.z
	if k < _MIN_K:
		return Vector2(th.suck, 0.0)
	return Vector2(_boost * k + th.suck, sz.z * _in_cloud_frac * k)


## Кучевое облако поля над термиком: есть ли оно и в какой стадии — из поля (покрытие, мощность,
## стадия, активность в столбце над термиком); размер — по силе термика, как у облака-объекта
## (CloudModel.size: покрытие столбца 400 м размера не даёт — это мерило площади подъёма). Молодое
## (стадия «растёт») и тающее (стадия «тает») не подсасывают, активность — доля облака под
## работающим подъёмом (то же, что огибающая термика у облака-объекта).
func _suck_field(th: AtmoThermal, _t: float) -> Vector2:
	var f := field
	if f == null or f.nx == 0 or th.top < f.base_msl - 50.0:
		return Vector2(th.suck, 0.0)
	var c := th.axis_at(f.base_msl)
	var s := f.sample(Vector3(c.x, f.base_msl, c.y))
	if s.x <= 0.0:
		return Vector2(th.suck, 0.0)
	var sz := model.size(th, Vector3(1.0, 0.0, 1.0))
	var diam := 2.0 * minf(sz.x, sz.y)
	var k := smoothstep(_size_min, _size_full, diam) * smoothstep(0.0, 0.1, s.x)
	k *= smoothstep(0.3, 0.8, 1.0 - maxf(s.w, 0.0))
	k *= 1.0 - smoothstep(0.0, 0.35, maxf(-s.w, 0.0))
	k *= _activity_at(f, c.x, c.y)
	if k < _MIN_K:
		return Vector2(th.suck, 0.0)
	return Vector2(_boost * k + th.suck, (s.z - s.y) * _in_cloud_frac * k)


## Активность поля (0..1) в столбце над точкой (x, z).
static func _activity_at(f: CloudField, x: float, z: float) -> float:
	var i := floori((x - f.x0) / f.dx)
	var j := floori((-z - f.y0) / f.dx)
	if i < 0 or i >= f.nx or j < 0 or j >= f.ny:
		return 0.0
	return f.activity[j * f.nx + i]


## Пересобрать облака рядом с фокусом и шагнуть поле до t (раз в refresh).
func refresh(thermals: Dictionary, t: float, focus: Vector3, radius: float) -> void:
	_refresh_objects(thermals, t, focus, radius)
	_refresh_field(thermals, t, focus, radius)


func _refresh_objects(thermals: Dictionary, t: float, focus: Vector3, radius: float) -> void:
	_grid.clear()
	_count = 0
	_y_min = 1.0e9
	_y_max = -1.0e9
	var r2 := radius * radius
	for id in thermals:
		var th: AtmoThermal = thermals[id]
		if not th.has_cloud:
			continue
		var st := model.stage(th, t)
		if st.x < 0.0:
			continue
		var c := model.center(th, t)
		if Vector2(focus.x, focus.z).distance_squared_to(c) > r2:
			continue
		var sz := model.size(th, st)
		var dens := st.x * (1.0 - st.y * st.y)
		var ax := th.drift_vel.normalized() if th.drift_vel.length_squared() > 1.0e-6 else Vector2(1, 0)
		var rec := PackedFloat32Array([c.x, c.y, th.top, sz.z, sz.x, sz.y, dens, ax.x, ax.y])
		var rmax := maxf(sz.x, sz.y)
		_y_min = minf(_y_min, th.top)
		_y_max = maxf(_y_max, th.top + sz.z)
		for gz in range(floori((c.y - rmax) / _cell), floori((c.y + rmax) / _cell) + 1):
			for gx in range(floori((c.x - rmax) / _cell), floori((c.x + rmax) / _cell) + 1):
				var key := Vector2i(gx, gz)
				if not _grid.has(key):
					_grid[key] = []
				_grid[key].append(rec)
		_count += 1


## Поле: принять готовую задачу (подмена целиком), запустить следующую, если пора.
func _refresh_field(thermals: Dictionary, t: float, focus: Vector3, radius: float) -> void:
	if not field_enabled() or not inputs_fn.is_valid():
		return
	if _job != null:
		if not deterministic and _job.task >= 0 and not WorkerThreadPool.is_task_completed(_job.task):
			return
		_finish_job()
	# Время поля — на сетке шагов (step_s): входы и шаг не зависят от того, в какой момент между
	# шагами игры пришёл refresh (два клиента с разным шагом кадра считают то же поле).
	var step := maxf(float(_cf_cfg.get("step_s", 20.0)), 0.1)
	t = floorf(t / step + 1.0e-9) * step
	var inp: Dictionary = inputs_fn.call(t)
	if inp.is_empty():
		return
	var key := _key_of(inp)
	var changed := key != _inputs_key
	var due := t < _work.time or t - _work.time >= step - 1.0e-6
	if not changed and not due and _work.nx != 0 and field.nx != 0:
		return
	var job := FieldJob.new()
	job.work = _work
	job.t = t
	job.focus = Vector2(focus.x, focus.z)
	job.radius = radius
	job.inp = inp
	# Аналитика: живые термики — ссылки, копии на момент t снимает поток (на главном — только список).
	if inp.get("air") == null:
		job.thermals = thermals.values()
	# Входы: при смене ключа, а в аналитике — на каждый шаг (термики живые).
	job.set_inp = changed or inp.get("air") == null or _work.nx == 0
	_inputs_key = key
	_ensure_grid(inp)
	_job = job
	if async_field:
		job.task = WorkerThreadPool.add_task(job.run, false, "CloudField.step")
	else:
		job.run()
		_finish_job()


func _finish_job() -> void:
	var job := _job
	_job = null
	if job == null:
		return
	if job.task >= 0:
		WorkerThreadPool.wait_for_task_completion(job.task)
	var w := job.work
	var f := field
	if f.signature() != w.signature():
		f.setup_grid(w.nx, w.ny, w.dx, w.x0, w.y0)
	# массивы подменяются целиком (копии, снятые потоком в конце задачи)
	f.cover = job.cover
	f.depth = job.depth
	f.stage = job.stage
	f.activity = job.activity
	f._hc = job.hc
	f.base_msl = w.base_msl
	f.bg_cover = w.bg_cover
	f.bg_depth = w.bg_depth
	f.time = w.time
	_field_count = job.count


func _key_of(inp: Dictionary) -> String:
	var air: Object = inp.get("air")
	var wf: Object = inp.get("wind_field")
	return "%d|%d|%s|%d" % [
		air.get_instance_id() if air != null else 0,
		wf.get_instance_id() if wf != null else 0,
		str(inp.get("cloudbase_msl", 0.0)),
		hash(inp.get("weather", {})),
	]


## Сетка поля: уровень региона поля воздуха, иначе область места (AirPlace.DOMAIN_L, AirRuntime.DX).
func _ensure_grid(inp: Dictionary) -> void:
	var wf: WindField = inp.get("wind_field")
	if wf == null and inp.get("air") != null:
		wf = (inp.air as AirThermals).level
	var nx := roundi(AirPlace.DOMAIN_L / AirRuntime.DX)
	var ny := nx
	var dx := AirRuntime.DX
	var x0 := -AirPlace.DOMAIN_L * 0.5
	var y0 := x0
	if wf != null:
		nx = wf.nx
		ny = wf.ny
		dx = wf.dx
		x0 = wf.x0
		y0 = wf.y0
	if _work.nx != nx or _work.ny != ny or _work.dx != dx or _work.x0 != x0 or _work.y0 != y0:
		_work.setup_grid(nx, ny, dx, x0, y0)


## Копии живых термиков на момент t (рабочий поток): читает только неизменные после рождения
## параметры, а огибающую и снос считает на копии — состояние, что обновляет главный, не трогает.
static func snapshot_thermals(thermals: Array, t: float) -> Array:
	var out: Array = []
	for th: AtmoThermal in thermals:
		if th.is_cb:
			continue
		var c := AtmoThermal.new()
		c.id = th.id
		c.is_static = th.is_static
		c.src = th.src
		c.strength = th.strength
		c.radius = th.radius
		c.lean = th.lean
		c.drift_vel = th.drift_vel
		c.drift_delay = th.drift_delay
		c.t_birth = th.t_birth
		c.t_grow = th.t_grow
		c.t_mature = th.t_mature
		c.t_decay = th.t_decay
		c.cloud_depth = th.cloud_depth
		c.overdevelop = th.overdevelop
		c.update_time(t)
		if c.strength <= 0.0 or c.env <= 0.0:
			continue
		# аналитический столб упирается в кромку; поток идёт в облако (подсос) до его верха —
		# иначе подъём у основания (профиль по высоте) равен нулю
		c.top = th.top + th.cloud_depth
		out.append(c)
	out.sort_custom(func(a: AtmoThermal, b: AtmoThermal) -> bool: return a.id < b.id)
	return out


## Дождаться идущей задачи поля и принять её (тесты, выход из места).
func wait_field() -> void:
	if _job != null:
		_finish_job()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _job != null and _job.task >= 0:
		# выход из места/игры: дождаться задачу, не бросать её без владельца
		WorkerThreadPool.wait_for_task_completion(_job.task)
		_job = null


## Облачность в точке для физики и ботов: Vector4(покрытие 0..1, основание MSL, верх MSL, стадия).
func field_cover_at(p: Vector3) -> Vector4:
	if field == null or field.nx == 0:
		return Vector4(0.0, 0.0, 0.0, 0.0)
	return field.sample(p)


## Облака поля, которые видит пилот (боты): над термиками рядом — центр, радиус, рост, распад.
## По одному на столбец поля (под одним облаком несколько термиков).
func visible_clouds(thermals: Dictionary, t: float, focus: Vector3) -> Array:
	var out: Array = []
	var f := field
	if f == null or f.nx == 0:
		return out
	var seen: Dictionary = {}
	var far := float(model._cfg.get("max_distance_m", 20000.0))
	var ids: Array = thermals.keys()
	ids.sort()
	for id: int in ids:
		var th: AtmoThermal = thermals[id]
		if th.is_cb or th.top < f.base_msl - 50.0:
			continue
		var c := th.axis_at(f.base_msl)
		if Vector2(focus.x, focus.z).distance_to(c) > far:
			continue
		var s := f.sample(Vector3(c.x, f.base_msl, c.y))
		if s.x < cover_min:
			continue
		var key := Vector2i(floori((c.x - f.x0) / f.dx), floori((-c.y - f.y0) / f.dx))
		if seen.has(key):
			continue
		seen[key] = true
		var depth := s.z - s.y
		out.append(
			{
				"center": c,
				"radius": maxf(0.5 * depth / _hw, 0.5 * f.dx * sqrt(s.x)),
				"growth": smoothstep(cover_min, 0.6, s.x),
				"decay": maxf(-s.w, 0.0),
			}
		)
	return out


func cloud_count() -> int:
	return _count + _field_count


## Плотность облака в точке 0..1 (0 — ясно). Для «белой мглы» у камеры и оценки «пилот в облаке».
## Cb — упрощённый купол (только облака своей клетки сетки), кучевые — плотность поля.
func density_at(pos: Vector3) -> float:
	var d := _sample_objects(pos).x
	var f := field
	if f != null and f.nx != 0 and pos.y >= f.base_msl and pos.y <= f.base_msl + _depth_max:
		d = maxf(d, f.density_at(pos))
	return d


## Vector3(плотность 0..1, направление к краю облака x, z) — в облаке поток «выкидывает» к краю.
func sample(pos: Vector3) -> Vector3:
	var best := _sample_objects(pos)
	var f := field
	if f != null and f.nx != 0 and pos.y >= f.base_msl and pos.y <= f.base_msl + _depth_max:
		var d := f.density_at(pos)
		if d > best.x:
			# к краю облака — вниз по градиенту покрытия на масштабе ±1,5 клетки
			var e := 1.5 * f.dx
			var gx := f.sample(pos + Vector3(e, 0.0, 0.0)).x - f.sample(pos - Vector3(e, 0.0, 0.0)).x
			var gz := f.sample(pos + Vector3(0.0, 0.0, e)).x - f.sample(pos - Vector3(0.0, 0.0, e)).x
			var g := sqrt(gx * gx + gz * gz)
			best = Vector3(d, -gx / g, -gz / g) if g > 1.0e-5 else Vector3(d, 0.0, 0.0)
	return best


func _sample_objects(pos: Vector3) -> Vector3:
	if pos.y < _y_min or pos.y > _y_max:
		return Vector3.ZERO
	var arr: Variant = _grid.get(Vector2i(floori(pos.x / _cell), floori(pos.z / _cell)))
	if arr == null:
		return Vector3.ZERO
	var best := Vector3.ZERO
	for rec: PackedFloat32Array in arr:
		var hn := (pos.y - rec[2]) / rec[3]
		if hn < 0.0 or hn > 1.0:
			continue
		var dx := pos.x - rec[0]
		var dz := pos.z - rec[1]
		var u := (dx * rec[7] + dz * rec[8]) / rec[4]
		var v := (-dx * rec[8] + dz * rec[7]) / rec[5]
		var q := 1.0 - Vector2(sqrt(u * u + v * v) / 0.85, hn).length()
		if q > 0.0:
			var d := smoothstep(0.0, 0.15, q) * rec[6]
			if d > best.x:
				var r := sqrt(dx * dx + dz * dz)
				best = Vector3(d, dx / r, dz / r) if r > 1.0 else Vector3(d, 1.0, 0.0)
	return best
