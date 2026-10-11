class_name OsmChimneyPlumes
extends OsmSmoke
## Шлейфы пара промышленных труб OSM (OL-6, контракт L9/L4, docs/contracts/osm-look.md): у части труб класса
## chimney (доля `chimney_plume.fraction`, выбор детерминированный по координатам) из устья на высоте трубы
## идёт бело-серый шлейф — ровно дым костра (smoke_particles/smoke_puff, как OsmSmoke и Campfire), но крупнее
## и долгоживущий. Воздух модели спрашивается на высоте устья, один вызов air_fn на трубу (кластер = труба),
## поэтому шлейф сносится и вытягивается по ветру и служит пилоту указателем ветра. Виден за `visibility_m`
## (несколько км): труб мало, эмиттер на каждую видимую трубу. Настройки — world_objects.json →
## osm_pilot.chimney_plume.


## Устья дымящих труб (мир, м): класс chimney, доля fraction по хэшу координат, высота h с тега или default_h_m.
static func pick_mouths(data: OsmData, cfg: Dictionary, height_fn: Callable) -> PackedVector3Array:
	var out := PackedVector3Array()
	var pc: Dictionary = cfg.get("osm_pilot", {})
	var cp: Dictionary = pc.get("chimney_plume", {})
	if data == null or not bool(cp.get("enabled", true)):
		return out
	var frac := float(cp.get("fraction", 0.5))
	var dh := float(pc.get("verticals", {}).get("default_h_m", {}).get("chimney", 50.0))
	for v: Dictionary in data.verticals:
		if String(v.t) != "chimney":
			continue
		var x := float(v.x)
		var z := float(v.z)
		if not is_plume(x, z, frac):
			continue
		var h_tag := float(v.get("h", 0.0))
		var h := h_tag if h_tag > 0.0 else dh
		out.append(Vector3(x, float(height_fn.call(x, z)) + h, z))
	return out


## Труба с шлейфом? Детерминированно по координатам (округление до 0,5 м).
static func is_plume(x: float, z: float, frac: float) -> bool:
	return WorldTiles.hash01(roundi(x * 2.0) * 7919 + roundi(z * 2.0) * 104729 + 31) < frac


static func build(data: OsmData, cfg: Dictionary, height_fn: Callable) -> Node3D:
	var cp: Dictionary = cfg.get("osm_pilot", {}).get("chimney_plume", {})
	var pts := pick_mouths(data, cfg, height_fn)
	if pts.is_empty():
		return null
	var n := OsmChimneyPlumes.new()
	n.setup_plumes(pts, cp)
	return n


## Каждая труба — свой «кластер» (ключ — её номер): один опрос air_fn на трубу.
func setup_plumes(points: PackedVector3Array, cfg: Dictionary) -> void:
	setup(PackedVector3Array(), cfg)
	for i in points.size():
		_clusters[Vector2i(i, 0)] = PackedVector3Array([points[i]])


## Все дымящие трубы в visibility_m от камеры (их мало) — на эмиттеры; уже занятые остаются на месте.
func _reassign(cam: Vector3) -> void:
	var vis := float(_cfg.get("visibility_m", 5000.0))
	var cap := int(_cfg.get("max_emitters", 24))
	var cand: Array = []  # [d2, Vector3, Vector2i]
	for k: Vector2i in _clusters:
		var p: Vector3 = (_clusters[k] as PackedVector3Array)[0]
		var d2 := Vector2(p.x - cam.x, p.z - cam.z).length_squared()
		if d2 <= vis * vis:
			cand.append([d2, p, k])
	cand.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	if cand.size() > cap:
		cand.resize(cap)
	var want := {}
	for c: Array in cand:
		want[c[1]] = c[2]
	var free_slots: Array[int] = []
	for i in _emitters.size():
		if _emitters[i].emitting and want.has(_emitters[i].position):
			want.erase(_emitters[i].position)
		else:
			_emitters[i].emitting = false
			free_slots.append(i)
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


## Границы видимости эмиттера: шлейф сносится ветром за время жизни до max_drift_m.
func _apply_wind(e: GPUParticles3D, wv: Vector3, _cl: float) -> void:
	var m := e.process_material as ShaderMaterial
	m.set_shader_parameter(&"wind_low", wv)
	m.set_shader_parameter(&"wind_high", wv)
	var drift := Vector3(wv.x, 0.0, wv.z) * e.lifetime
	var cap := float(_cfg.get("max_drift_m", 700.0))
	if drift.length() > cap:
		drift = drift.normalized() * cap
	var size := float(_cfg.get("size_end_m", 40.0))
	var top := float(_cfg.get("rise_speed", 3.0)) * float(_cfg.get("rise_decay_s", 12.0)) + 40.0
	var box := AABB(Vector3(-size, -size, -size), Vector3(size * 2.0, top + size, size * 2.0))
	e.visibility_aabb = box.merge(AABB(box.position + drift, box.size))
