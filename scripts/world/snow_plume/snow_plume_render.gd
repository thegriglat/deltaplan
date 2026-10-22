class_name SnowPlumeRender
extends Node3D
## Снежные флаги (SNW-К3, docs/contracts/snow-plume.md): пул GPUParticles3D по списку источников модели.
## Образец — OsmSmoke. Излучатель стоит в pos источника, частицы идут по path/vel (шейдер считает положение
## аналитически от возраста), оседают на settle_ms и разлетаются на spread_ms. Плотность ∝ intensity
## (amount_ratio и прозрачность). Источник переназначается по id без restart(). Умолчания — SNW-К4.

const PARTICLES_SHADER := preload("res://scripts/world/snow_plume/snow_plume_particles.gdshader")
const FLAKE_SHADER := preload("res://scripts/world/snow_plume/snow_plume_flake.gdshader")
const MAX_PATH := 8

var _cfg: Dictionary = {}
var _max := 24
var _emitters: Array[GPUParticles3D] = []
var _ids: Array[int] = []  # id источника в слоте, -1 — слот свободен
var _quad: QuadMesh
var _active := 0


func _init(cfg: Dictionary = {}) -> void:
	_cfg = cfg
	_max = maxi(int(cfg.get("max_emitters", 24)), 0)
	var mat := ShaderMaterial.new()
	mat.shader = FLAKE_SHADER
	mat.set_shader_parameter(&"alpha", float(cfg.get("alpha", 0.5)))
	_quad = QuadMesh.new()
	_quad.material = mat
	for i in _max:
		_emitters.append(_make_emitter())
		_ids.append(-1)


func active_count() -> int:
	return _active


func set_emitters(list: Array) -> void:
	var take: Array = list.slice(0, _max) if list.size() > _max else list
	var want := {}  # id → источник
	for e: Dictionary in take:
		want[int(e["id"])] = e
	# слоты, чей id пропал, освобождаются; оставшиеся — обновляются на месте
	var free_slots: Array[int] = []
	for i in _max:
		if _ids[i] >= 0 and want.has(_ids[i]):
			_assign(i, want[_ids[i]], false)
			want.erase(_ids[i])
		else:
			if _ids[i] >= 0:
				_emitters[i].emitting = false
			_ids[i] = -1
			free_slots.append(i)
	for id: int in want:
		if free_slots.is_empty():
			break
		var slot: int = free_slots.pop_back()
		_ids[slot] = id
		_assign(slot, want[id], true)
	_active = 0
	for i in _max:
		if _ids[i] >= 0:
			_active += 1


func _assign(slot: int, e: Dictionary, fresh: bool) -> void:
	var p := _emitters[slot]
	var path: PackedVector3Array = e.get("path", PackedVector3Array())
	var vel: PackedVector3Array = e.get("vel", PackedVector3Array())
	var n := mini(mini(path.size(), vel.size()), MAX_PATH)
	var pos: Vector3 = e.get("pos", Vector3.ZERO)
	var inten := clampf(float(e.get("intensity", 0.0)), 0.0, 1.0)
	if n < 2 or inten <= 0.0:
		# линии тока нет — излучатель не рисуется, но id держит слот (не ломается, не перезапускается зря)
		p.emitting = false
		return
	var dt := maxf(float(e.get("path_dt", 8.0)), 0.1)
	var width := maxf(float(e.get("width_m", 150.0)), 0.0)
	var spread := float(_cfg.get("spread_ms", 1.0))
	var settle := float(_cfg.get("settle_ms", 0.3))
	var sz: Array = _cfg.get("size_m", [2.0, 20.0])
	if p.position != pos:
		p.position = pos
	var life := dt * float(n - 1)
	if not is_equal_approx(p.lifetime, life):
		p.lifetime = life
	p.amount_ratio = inten
	var m := p.process_material as ShaderMaterial
	var pa := PackedVector3Array()
	var va := PackedVector3Array()
	pa.resize(MAX_PATH)
	va.resize(MAX_PATH)
	for i in MAX_PATH:
		pa[i] = path[mini(i, n - 1)]
		va[i] = vel[mini(i, n - 1)]
	m.set_shader_parameter(&"path", pa)
	m.set_shader_parameter(&"vel", va)
	m.set_shader_parameter(&"path_n", n)
	m.set_shader_parameter(&"path_dt", dt)
	m.set_shader_parameter(&"dir", e.get("dir", Vector3.RIGHT))
	m.set_shader_parameter(&"width_m", width)
	m.set_shader_parameter(&"intensity", inten)
	m.set_shader_parameter(&"spread_ms", spread)
	m.set_shader_parameter(&"settle_ms", settle)
	m.set_shader_parameter(&"size_start", float(sz[0]))
	m.set_shader_parameter(&"size_end", float(sz[1]))
	# AABB в локальных осях излучателя: все точки path + запас на разлёт, оседание и размер частицы
	var reach := spread * life + settle * life + float(sz[1]) + width * 0.5
	var box := AABB(path[0] - pos, Vector3.ZERO)
	for i in n:
		box = box.expand(path[i] - pos)
	p.visibility_aabb = box.grow(reach)
	if fresh or not p.emitting:
		p.emitting = true


func _make_emitter() -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = maxi(int(_cfg.get("particles_per_emitter", 64)), 1)
	p.lifetime = 40.0
	p.preprocess = 0.0
	p.local_coords = false
	p.fixed_fps = 20
	p.interpolate = true
	p.randomness = 0.2
	p.emitting = false
	p.visibility_range_end = float(_cfg.get("visibility_m", 6000.0)) + 200.0
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	var m := ShaderMaterial.new()
	m.shader = PARTICLES_SHADER
	p.process_material = m
	p.draw_pass_1 = _quad
	add_child(p)
	return p
