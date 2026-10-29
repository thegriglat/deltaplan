class_name GustDust
extends Node3D
## Клубы пыли от порывов у земли (отрисовка). Модель — GustDustModel: событие (клетка, слот) —
## функция мира. Здесь: просмотр клеток вокруг камеры на слот вперёд (порыв во всех клетках слота —
## одним вызовом surface_gust_many), пул событий (кольцо) и один MultiMesh с billboard'ами;
## анимация клуба — в шейдере по времени атмосферы.

var atmo: Atmosphere
var cfg: Dictionary
var model: GustDustModel = GustDustModel.new()
## Высота рельефа (x, z) -> м MSL (NAN — нет земли) и класс поверхности (x, z) -> int: даёт
## Atmosphere при создании слоя. Положение наблюдателя — по умолчанию активная камера.
var ground_fn: Callable = Callable()
var surface_fn: Callable = Callable()
var eye_fn: Callable = Callable()
var mm: MultiMesh
var mmi: MultiMeshInstance3D
var mat: ShaderMaterial
var events: Array[Dictionary] = []  ## пул (кольцо), ячейка — событие или {}

var _cursor: int = 0
var _keys: Dictionary = {}
var _queue: Array[int] = []
var _next_slot: int = 0


## gust_cfg — раздел gust_dust конфига атмосферы (пусто — configs/atmosphere.json); порыв берётся
## из фасада (surface_gust_many), поэтому источника ветра слою не нужно.
func setup(
	atmosphere: Atmosphere,
	ground: Callable = Callable(),
	surface: Callable = Callable(),
	gust_cfg: Dictionary = {}
) -> void:
	atmo = atmosphere
	ground_fn = ground
	surface_fn = surface
	cfg = (
		gust_cfg if not gust_cfg.is_empty() else Config.get_config("atmosphere").gust_dust
	).duplicate()
	model.setup(cfg, atmo.weather())
	atmo.weather_changed.connect(func() -> void: _reset_weather())
	atmo.weather_updated.connect(func() -> void: model.update_weather(cfg, atmo.weather()))
	var n := int(cfg.events_max)
	events.resize(n)
	for i in n:
		events[i] = {}
	var per := int(cfg.puffs_max)
	mat = ShaderMaterial.new()
	mat.shader = load("res://scripts/atmosphere/gust_dust.gdshader")
	var ta: Array = cfg.tint_crop
	var tb: Array = cfg.tint_bare
	mat.set_shader_parameter("tint_a", Color(float(ta[0]), float(ta[1]), float(ta[2])))
	mat.set_shader_parameter("tint_b", Color(float(tb[0]), float(tb[1]), float(tb[2])))
	mat.set_shader_parameter("density", float(cfg.density))
	mm = MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = QuadMesh.new()
	mm.instance_count = n * per
	var reach := float(cfg.radius_m) + 500.0
	mm.custom_aabb = AABB(Vector3(-reach, -2000.0, -reach), Vector3(reach * 2.0, 6000.0, reach * 2.0))
	for i in mm.instance_count:
		_hide(i)
	mmi = MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
	_next_slot = model.slot_of(float(atmo.status().time_s)) - model.lookback_slots()


func _reset_weather() -> void:
	model.update_weather(cfg, atmo.weather())


func _hide(i: int) -> void:
	mm.set_instance_transform(i, Transform3D(Basis(), Vector3.ZERO))
	mm.set_instance_custom_data(i, Color(0, 1.0e9, 1, 0))


func _process(_delta: float) -> void:
	if atmo == null or not model.enabled:
		return
	var t := float(atmo.status().time_s)
	mat.set_shader_parameter("now", t)
	step_scan(_eye(), t)


func _eye() -> Vector3:
	if eye_fn.is_valid():
		return eye_fn.call()
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	return cam.global_position if cam != null else Vector3.ZERO


func _ground(x: float, z: float) -> float:
	var h := float(ground_fn.call(x, z)) if ground_fn.is_valid() else 0.0
	return h if is_finite(h) else 0.0


## Просмотреть один слот из очереди: клетки вокруг eye, порыв в них — одним вызовом
## surface_gust_many, новые события (ближние первыми, не больше new_per_slot_max) — в пул.
## Тестам — вызывать напрямую.
func step_scan(eye: Vector3, t: float) -> void:
	var cur := model.slot_of(t)
	# Слоты, которые надо просмотреть: от самого старого живого до следующего.
	while _next_slot <= cur + 1:
		_queue.append(_next_slot)
		_next_slot += 1
	if _queue.is_empty():
		return
	var slot: int = _queue.pop_front()
	if slot < cur - model.lookback_slots():
		return
	var base := Vector2i(int(floor(eye.x / model.cell_m)), int(floor(eye.z / model.cell_m)))
	var cells: Array[Vector2i] = []
	for off in model.offsets():
		var c := base + off
		if not _keys.has(Vector3i(c.x, c.y, slot)):
			cells.append(c)
	var evs := model.events(cells, slot, surface_fn, Callable(atmo, "surface_gust_many"))
	var added := 0
	for i in cells.size():
		if evs[i].is_empty():
			continue
		if added >= int(cfg.new_per_slot_max):
			break
		_keys[Vector3i(cells[i].x, cells[i].y, slot)] = slot
		added += 1
		_add_event(evs[i])
	_prune_keys(cur)


func _prune_keys(cur: int) -> void:
	var old := cur - model.lookback_slots() - 1
	for k in _keys.keys():
		if int(_keys[k]) < old:
			_keys.erase(k)


func _add_event(ev: Dictionary) -> void:
	var idx := _cursor
	_cursor = (_cursor + 1) % events.size()
	events[idx] = ev
	var per := int(cfg.puffs_max)
	var x: float = ev.x
	var z: float = ev.z
	var y: float = _ground(x, z)
	var w := _wind10() * float(cfg.drift_k)
	var h: float = ev.h
	var base_seed: float = ev.seed
	var tint := 1.0 if int(ev.cls) == 5 else 0.0
	for j in per:
		var i := idx * per + j
		if j >= int(ev.n):
			_hide(i)
			continue
		var r1 := fposmod(base_seed * 91.7 + float(j) * 0.618, 1.0)
		var r2 := fposmod(base_seed * 57.3 + float(j) * 0.382 + 0.17, 1.0)
		var r3 := fposmod(base_seed * 33.1 + float(j) * 0.771 + 0.5, 1.0)
		var spread := h * 0.5
		var pos := Vector3(x + (r1 - 0.5) * spread, y + 0.3, z + (r2 - 0.5) * spread)
		var size := h * (0.7 + 0.6 * r3) * (0.6 + 0.4 * float(ev.k))
		# Столбцы: [0] = (размер, снос x, снос z), [1].x = подъём (шейдер читает так).
		var rise := float(cfg.rise_ms) * (0.4 + float(ev.k))
		var b := Basis(Vector3(size, w.x, w.y), Vector3(rise, 0, 0), Vector3(0, 0, 1))
		mm.set_instance_transform(i, Transform3D(b, pos))
		var delay := float(ev.life) * 0.18 * float(j) / float(maxi(per - 1, 1))
		mm.set_instance_custom_data(
			i, Color(r1 * TAU, float(ev.t0) + delay, float(ev.life) * (1.0 - 0.18), tint + base_seed * 0.99)
		)


## Ветер у земли (x, z), м/с — фоновый ветер W2 на 10 м над долиной (только снос облачка пыли;
## порог события — порыв surface_gust_many). Штиль — 0.
func _wind10() -> Vector2:
	var h := float(atmo.weather().get("_derived", {}).get("valley_msl_m", 0.0)) + 10.0
	var bw := atmo.background_wind(PackedFloat32Array([h]))
	return Vector2(bw[0], bw[1])


## Направление ветра у земли (единичный, x, z); штиль — 0.
func _wind_dir() -> Vector2:
	var v := _wind10()
	return v.normalized() if v.length() > 1.0e-6 else Vector2.ZERO


## Сколько событий сейчас живо в пуле (для тестов).
func live_count(t: float) -> int:
	var n := 0
	for ev in events:
		if not ev.is_empty() and t >= float(ev.t0) and t <= float(ev.t0) + float(ev.life):
			n += 1
	return n
