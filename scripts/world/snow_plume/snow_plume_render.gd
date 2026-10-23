class_name SnowPlumeRender
extends Node3D
## Снежная позёмка (SNW-К3/К4 v3, docs/contracts/snow-plume.md): пул GPUParticles3D по списку источников модели.
## Частица — короткий полупрозрачный штрих вдоль своей скорости (snow_plume_streak.gdshader), рождается на
## рельефе в точках surf источника на высоте 0…layer_h_m, идёт по ветру из vel (snow_plume_particles.gdshader).
## Плотность и прозрачность ∝ intensity. Источник переназначается по id без restart(). Умолчания — К4 v3.

const PARTICLES_SHADER := preload("res://scripts/world/snow_plume/snow_plume_particles.gdshader")
const STREAK_SHADER := preload("res://scripts/world/snow_plume/snow_plume_streak.gdshader")
const MAX_PATH := 8
const MAX_SURF := 8
const DEFAULTS := {
	"max_emitters": 32, "particles_per_emitter": 48, "streak_len_m": 3.5, "streak_w_m": 0.25, "layer_h_m": 2.0,
	"life_s": 2.0, "settle_ms": 0.2, "spread_ms": 0.6, "alpha": 0.25, "visibility_m": 1500.0,
}

var _cfg: Dictionary = {}
var _max := 32
var _emitters: Array[GPUParticles3D] = []
var _ids: Array[int] = []  # id источника в слоте, -1 — слот свободен
var _quad: QuadMesh
var _active := 0


func _init(cfg: Dictionary = {}) -> void:
	_cfg = DEFAULTS.duplicate()
	_cfg.merge(cfg, true)
	_max = maxi(int(_cfg.max_emitters), 0)
	var mat := ShaderMaterial.new()
	mat.shader = STREAK_SHADER
	mat.set_shader_parameter(&"alpha", float(_cfg.alpha))
	_quad = QuadMesh.new()
	_quad.size = Vector2.ONE
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
	var surf: PackedVector3Array = e.get("surf", PackedVector3Array())
	var n := mini(mini(path.size(), vel.size()), MAX_PATH)
	var ns := mini(surf.size(), MAX_SURF)
	var pos: Vector3 = e.get("pos", Vector3.ZERO)
	var inten := clampf(float(e.get("intensity", 0.0)), 0.0, 1.0)
	if n < 2 or inten <= 0.0:
		# линии тока нет — излучатель не рисуется, но id держит слот (не ломается, не перезапускается зря)
		p.emitting = false
		return
	if ns < 1:
		# старый источник без surf: рождение в pos
		surf = PackedVector3Array([pos])
		ns = 1
	var dt := maxf(float(e.get("path_dt", 1.0)), 0.1)
	var spread := float(_cfg.spread_ms)
	var settle := float(_cfg.settle_ms)
	var life := maxf(float(_cfg.life_s), 0.1)
	var layer := float(_cfg.layer_h_m)
	var slen := float(_cfg.streak_len_m)
	if p.position != pos:
		p.position = pos
	if not is_equal_approx(p.lifetime, life):
		p.lifetime = life
	p.amount_ratio = inten
	var m := p.process_material as ShaderMaterial
	var pa := PackedVector3Array()
	var va := PackedVector3Array()
	var sa := PackedVector3Array()
	pa.resize(MAX_PATH)
	va.resize(MAX_PATH)
	sa.resize(MAX_SURF)
	for i in MAX_PATH:
		pa[i] = path[mini(i, n - 1)]
		va[i] = vel[mini(i, n - 1)]
	for i in MAX_SURF:
		sa[i] = surf[mini(i, ns - 1)]
	m.set_shader_parameter(&"surf", sa)
	m.set_shader_parameter(&"surf_n", ns)
	m.set_shader_parameter(&"vel", va)
	m.set_shader_parameter(&"path_n", n)
	m.set_shader_parameter(&"path_dt", dt)
	m.set_shader_parameter(&"intensity", inten)
	m.set_shader_parameter(&"spread_ms", spread)
	m.set_shader_parameter(&"settle_ms", settle)
	m.set_shader_parameter(&"layer_h_m", layer)
	m.set_shader_parameter(&"life_s", life)
	m.set_shader_parameter(&"streak_len_m", slen)
	m.set_shader_parameter(&"streak_w_m", float(_cfg.streak_w_m))
	# AABB в локальных осях излучателя: точки surf и path, плюс снос по ветру за жизнь частицы, разлёт, оседание
	var vmax := 0.0
	for i in n:
		vmax = maxf(vmax, va[i].length())
	var reach := (vmax * 1.5 + spread + settle) * life + slen + layer + 1.0
	var box := AABB(path[0] - pos, Vector3.ZERO)
	for i in n:
		box = box.expand(path[i] - pos)
	for i in ns:
		box = box.expand(surf[i] - pos)
	p.visibility_aabb = box.grow(reach)
	if fresh or not p.emitting:
		p.emitting = true


func _make_emitter() -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = maxi(int(_cfg.particles_per_emitter), 1)
	p.lifetime = float(_cfg.life_s)
	p.preprocess = 0.0
	p.local_coords = false
	p.fixed_fps = 30
	p.interpolate = true
	p.randomness = 0.2
	p.emitting = false
	p.visibility_range_end = float(_cfg.visibility_m) + 200.0
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	var m := ShaderMaterial.new()
	m.shader = PARTICLES_SHADER
	p.process_material = m
	p.draw_pass_1 = _quad
	add_child(p)
	return p
