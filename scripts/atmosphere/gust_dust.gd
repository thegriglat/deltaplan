class_name GustDust
extends Node3D
## Клубы пыли от порывов у земли (отрисовка). Модель — GustDustModel: событие (клетка, слот) —
## функция мира. Здесь: порционный просмотр клеток вокруг камеры на слот вперёд, пул событий
## (кольцо) и один MultiMesh с billboard'ами; анимация клуба — в шейдере по времени атмосферы.
## Командный аргумент --gust-dust-wind=N форсирует средний ветер N м/с на 10 м.

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
var _scan_pos: int = -1  ## индекс в offsets(), −1 — слот не начат
var _scan_new: int = 0
var _scan_cell: Vector2i = Vector2i.ZERO


## wind_source — источник приземного ветра и шума порывов (мировая функция слота времени, которую
## отдаёт реализация при создании слоя; в фасаде W2 такой функции нет — перейдёт в крейт с RW-8).
func setup(
	atmosphere: Atmosphere,
	ground: Callable = Callable(),
	surface: Callable = Callable(),
	wind_source: Variant = null
) -> void:
	atmo = atmosphere
	ground_fn = ground
	surface_fn = surface
	cfg = atmo.cfg.gust_dust.duplicate()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--gust-dust-wind="):
			cfg.force_wind_ms = float(a.get_slice("=", 1))
	model.setup(cfg, atmo.get_weather(), wind_source)
	atmo.weather_changed.connect(func() -> void: _reset_weather())
	atmo.weather_updated.connect(func() -> void: model.update_weather(cfg, atmo.get_weather()))
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
	model.update_weather(cfg, atmo.get_weather())


func _hide(i: int) -> void:
	mm.set_instance_transform(i, Transform3D(Basis(), Vector3.ZERO))
	mm.set_instance_custom_data(i, Color(0, 1.0e9, 1, 0))


func _process(_delta: float) -> void:
	if atmo == null or not model.enabled:
		return
	var t := float(atmo.status().time_s)
	mat.set_shader_parameter("now", t)
	step_scan(_eye(), t, int(cfg.cells_per_frame))


func _eye() -> Vector3:
	if eye_fn.is_valid():
		return eye_fn.call()
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	return cam.global_position if cam != null else Vector3.ZERO


func _ground(x: float, z: float) -> float:
	var h := float(ground_fn.call(x, z)) if ground_fn.is_valid() else 0.0
	return h if is_finite(h) else 0.0


## Продвинуть просмотр на budget клеток. Тестам — вызывать напрямую.
func step_scan(eye: Vector3, t: float, budget: int) -> void:
	var cur := model.slot_of(t)
	# Слоты, которые надо просмотреть: от самого старого живого до следующего.
	while _next_slot <= cur + 1:
		_queue.append(_next_slot)
		_next_slot += 1
	if _queue.is_empty():
		return
	var slot: int = _queue[0]
	if slot < cur - model.lookback_slots():
		_queue.pop_front()
		_scan_pos = -1
		return
	var offs := model.offsets()
	if _scan_pos < 0:
		_scan_pos = 0
		_scan_new = 0
		_scan_cell = Vector2i(int(floor(eye.x / model.cell_m)), int(floor(eye.z / model.cell_m)))
	var end := mini(_scan_pos + budget, offs.size())
	while _scan_pos < end:
		var c := _scan_cell + offs[_scan_pos]
		_scan_pos += 1
		var key := Vector3i(c.x, c.y, slot)
		if _keys.has(key) or _scan_new >= int(cfg.new_per_slot_max):
			continue
		var ev := model.event(c.x, c.y, slot, surface_fn)
		if ev.is_empty():
			continue
		_keys[key] = slot
		_scan_new += 1
		_add_event(ev)
	if _scan_pos >= offs.size() or _scan_new >= int(cfg.new_per_slot_max):
		_queue.pop_front()
		_scan_pos = -1
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
	var w := _wind_dir() * model.mean_wind10() * float(cfg.drift_k)
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
		var b := Basis(Vector3(size, w.x, w.y), Vector3(float(cfg.rise_ms) * (0.4 + float(ev.k)), 0, 0), Vector3(0, 0, 1))
		mm.set_instance_transform(i, Transform3D(b, pos))
		var delay := float(ev.life) * 0.18 * float(j) / float(maxi(per - 1, 1))
		mm.set_instance_custom_data(
			i, Color(r1 * TAU, float(ev.t0) + delay, float(ev.life) * (1.0 - 0.18), tint + base_seed * 0.99)
		)


## Направление ветра у земли (единичный, x, z) — из фонового ветра W2 на 10 м над долиной; штиль — 0.
func _wind_dir() -> Vector2:
	var h := float(atmo.get_weather().get("_derived", {}).get("valley_msl_m", 0.0)) + 10.0
	var bw := atmo.background_wind(PackedFloat32Array([h]))
	var v := Vector2(bw[0], bw[1])
	return v.normalized() if v.length() > 1.0e-6 else Vector2.ZERO


## Сколько событий сейчас живо в пуле (для тестов).
func live_count(t: float) -> int:
	var n := 0
	for ev in events:
		if not ev.is_empty() and t >= float(ev.t0) and t <= float(ev.t0) + float(ev.life):
			n += 1
	return n
