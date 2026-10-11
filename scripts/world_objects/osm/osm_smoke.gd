class_name OsmSmoke
extends Node3D
## Дым над трубами сельских домов (OL-1, контракт L3/L4, docs/contracts/osm-look.md): ровно дым костра
## (smoke_particles.gdshader / smoke_puff.gdshader, как Campfire), но слабее и мельче (configs/world_objects.json →
## buildings.smoke). Не тысячи GPUParticles3D: пул эмиттеров `max_emitters`, который ставится у ближайших к
## камере дымящих труб в радиусе `visibility_m`; пересчёт раз в `update_s`. Ветер (L4) — на кластер
## `cluster_m`, не на дом: osm_wind(air_fn, cam) вызывает OsmLayer.update_wind; опрос — на высоте
## `sample_h_m` над трубой, не больше одного вызова air_fn на кластер на вызов и `osm_wind.max_samples` за вызов.

const SMOKE_SHADER := preload("res://scripts/world_objects/smoke_particles.gdshader")
const PUFF_SHADER := preload("res://scripts/world_objects/smoke_puff.gdshader")

## Эмиттеров в пуле (для тестов и замеров).
var emitter_count: int:
	get:
		return _emitters.size()
## Сколько эмиттеров сейчас стоит над трубой (видимых).
var active_count := 0
## Вызовов air_fn за последний osm_wind (для тестов).
var last_samples := 0

var _cfg: Dictionary = {}
var _clusters: Dictionary = {}  # Vector2i кластера → PackedVector3Array труб
var _emitters: Array[GPUParticles3D] = []
var _slot_of: Dictionary = {}  # Vector3 трубы → индекс эмиттера
var _cluster_of: Array = []  # индекс эмиттера → Vector2i кластера
var _puff: QuadMesh
var _next_update_ms := 0
var _max_samples := 64


func setup(points: PackedVector3Array, cfg: Dictionary) -> void:
	_cfg = cfg
	var cl := maxf(float(cfg.get("cluster_m", 250.0)), 10.0)
	var by: Dictionary = {}  # Vector2i → Array[Vector3] (PackedArray в словаре копируется — копим массивом)
	for p in points:
		var k := Vector2i(floori(p.x / cl), floori(p.z / cl))
		if not by.has(k):
			by[k] = []
		(by[k] as Array).append(p)
	for k: Vector2i in by:
		_clusters[k] = PackedVector3Array(by[k])
	var ow: Dictionary = Config.get_config("world_objects").get("osm_wind", {})
	_max_samples = int(ow.get("max_samples", 64))
	add_to_group(&"osm_wind")
	var mat := ShaderMaterial.new()
	mat.shader = PUFF_SHADER
	var tint: Array = cfg.get("tint", [0.8, 0.82, 0.86])
	mat.set_shader_parameter(&"tint", Color(float(tint[0]), float(tint[1]), float(tint[2])))
	mat.set_shader_parameter(&"density", float(cfg.get("density", 0.16)))
	_puff = QuadMesh.new()
	_puff.material = mat


func chimney_count() -> int:
	var n := 0
	for k: Vector2i in _clusters:
		n += (_clusters[k] as PackedVector3Array).size()
	return n


## L4: вызывает OsmLayer.update_wind. Раз в update_s — выбор труб с дымом у камеры; каждый вызов — ветер
## на кластеры занятых эмиттеров (один air_fn на кластер).
func osm_wind(air_fn: Callable, cam: Vector3) -> void:
	last_samples = 0
	if _clusters.is_empty():
		return
	var now := Time.get_ticks_msec()
	if now >= _next_update_ms:
		_next_update_ms = now + int(float(_cfg.get("update_s", 1.0)) * 1000.0)
		_reassign(cam)
	var cl := maxf(float(_cfg.get("cluster_m", 250.0)), 10.0)
	var h := float(_cfg.get("sample_h_m", 12.0))
	var up := float(_cfg.get("updraft_max_ms", 2.0))
	var wind_of := {}  # кластер → ветер; один опрос на кластер на вызов
	for i in _emitters.size():
		var e := _emitters[i]
		if not e.emitting:
			continue
		var k: Vector2i = _cluster_of[i]
		var wv: Vector3
		if wind_of.has(k):
			wv = wind_of[k]
		elif last_samples < _max_samples:
			var pts: PackedVector3Array = _clusters[k]
			var sp := pts[0] + Vector3.UP * h
			wv = air_fn.call(sp)
			last_samples += 1
			wv = Vector3(wv.x, clampf(wv.y, -up, up), wv.z)
			wind_of[k] = wv
		else:
			continue
		_apply_wind(e, wv, cl)


## Ближайшие к камере дымящие трубы в радиусе visibility_m — на эмиттеры пула; занятые, но всё ещё подходящие,
## остаются на месте (шлейф не обрывается и не начинается заново).
func _reassign(cam: Vector3) -> void:
	var vis := float(_cfg.get("visibility_m", 1200.0))
	var cl := maxf(float(_cfg.get("cluster_m", 250.0)), 10.0)
	var cap := int(_cfg.get("max_emitters", 48))
	var r := int(ceil(vis / cl)) + 1
	var c0 := Vector2i(floori(cam.x / cl), floori(cam.z / cl))
	var cand: Array = []  # [d2, Vector3, Vector2i]
	for dz in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var k := Vector2i(c0.x + dx, c0.y + dz)
			if not _clusters.has(k):
				continue
			for p: Vector3 in _clusters[k]:
				var d2 := Vector2(p.x - cam.x, p.z - cam.z).length_squared()
				if d2 <= vis * vis:
					cand.append([d2, p, k])
	cand.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	if cand.size() > cap:
		cand.resize(cap)
	var want := {}
	for c: Array in cand:
		want[c[1]] = c[2]
	# освободить эмиттеры над трубами, которых больше нет в выборке
	var free_slots: Array[int] = []
	for i in _emitters.size():
		var pos: Vector3 = _emitters[i].position
		if _emitters[i].emitting and want.has(pos):
			want.erase(pos)  # уже стоит
		else:
			_emitters[i].emitting = false
			free_slots.append(i)
	# новые трубы — в свободные слоты, при нехватке — новые эмиттеры до cap
	for p: Vector3 in want:
		var slot := -1
		if not free_slots.is_empty():
			slot = free_slots.pop_back()
		elif _emitters.size() < cap:
			slot = _emitters.size()
			_emitters.append(_make_emitter())
			_cluster_of.append(Vector2i.ZERO)
		else:
			break
		var e := _emitters[slot]
		e.position = p
		(e.process_material as ShaderMaterial).set_shader_parameter(&"fire_y", p.y)
		_cluster_of[slot] = want[p]
		e.emitting = true
	active_count = 0
	for e in _emitters:
		if e.emitting:
			active_count += 1


func _apply_wind(e: GPUParticles3D, wv: Vector3, _cl: float) -> void:
	var m := e.process_material as ShaderMaterial
	m.set_shader_parameter(&"wind_low", wv)
	m.set_shader_parameter(&"wind_high", wv)
	var life := e.lifetime
	var drift := Vector3(wv.x, 0.0, wv.z) * life
	if drift.length() > 150.0:
		drift = drift.normalized() * 150.0
	var size := float(_cfg.get("size_end_m", 3.5))
	var top := float(_cfg.get("rise_speed", 1.6)) * float(_cfg.get("rise_decay_s", 5.0)) + 20.0
	var box := AABB(Vector3(-size, -1.0, -size), Vector3(size * 2.0, top, size * 2.0))
	e.visibility_aabb = box.merge(AABB(box.position + drift, box.size))


func _make_emitter() -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = int(_cfg.get("amount", 12))
	p.lifetime = float(_cfg.get("lifetime_s", 12.0))
	p.preprocess = p.lifetime * 0.5
	p.local_coords = false
	p.fixed_fps = 20
	p.interpolate = true
	p.randomness = 0.2
	p.emitting = false
	p.visibility_range_end = float(_cfg.get("visibility_m", 1200.0)) + 100.0
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	var m := ShaderMaterial.new()
	m.shader = SMOKE_SHADER
	for k: String in ["rise_speed", "rise_decay_s", "rise_min", "wind_damp", "follow_s", "turbulence"]:
		if _cfg.has(k):
			m.set_shader_parameter(k, float(_cfg[k]))
	m.set_shader_parameter(&"size_start", float(_cfg.get("size_start_m", 0.25)))
	m.set_shader_parameter(&"size_end", float(_cfg.get("size_end_m", 3.5)))
	m.set_shader_parameter(&"emit_radius", 0.15)
	m.set_shader_parameter(&"wind_high_m", 20.0)
	p.process_material = m
	p.draw_pass_1 = _puff
	add_child(p)
	return p
