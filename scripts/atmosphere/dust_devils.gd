class_name DustDevils
extends Node3D
## Пылевые вихри рядом с камерой (VR-18) — видимый признак молодого термика над сухим полем.
## Модель — DustModel (из стадии термика и поверхности), здесь только отрисовка: пул из
## max_visible конусов с шейдером закрученной пыли.

var atmo: Atmosphere
var cfg: Dictionary
var model: DustModel = DustModel.new()
var _pool: Array[MeshInstance3D] = []
var _acc: float = 1.0e9
var _active: Array[Dictionary] = []


func setup(atmosphere: Atmosphere) -> void:
	atmo = atmosphere
	cfg = atmo.cfg.dust
	model.setup(cfg, atmo.weather)
	atmo.weather_changed.connect(func() -> void: model.setup(cfg, atmo.weather))
	var mat := ShaderMaterial.new()
	mat.shader = load("res://scripts/atmosphere/dust_devil.gdshader")
	var n := FastNoiseLite.new()
	n.seed = int(atmo.cfg.seed) + 31
	n.fractal_octaves = 3
	n.frequency = 8.0 / 256.0
	var tex := NoiseTexture2D.new()
	tex.width = 256
	tex.height = 256
	tex.seamless = true
	tex.generate_mipmaps = true
	tex.noise = n
	mat.set_shader_parameter("noise", tex)
	var c: Array = cfg.color
	mat.set_shader_parameter("dust_color", Color(float(c[0]), float(c[1]), float(c[2])))
	mat.set_shader_parameter("opacity", float(cfg.opacity))
	var cyl := CylinderMesh.new()
	cyl.top_radius = 1.0
	cyl.bottom_radius = float(cfg.base_radius_frac)
	cyl.height = 1.0
	cyl.cap_top = false
	cyl.cap_bottom = false
	cyl.radial_segments = 24
	cyl.rings = 8
	for i in int(cfg.max_visible):
		var mi := MeshInstance3D.new()
		mi.mesh = cyl
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		add_child(mi)
		_pool.append(mi)


func _process(delta: float) -> void:
	if atmo == null:
		return
	var cam := get_viewport().get_camera_3d()
	var eye := cam.global_position if cam != null else atmo.get_focus()
	_acc += delta
	if _acc > 0.5:
		_acc = 0.0
		_active = find(eye)
	for i in _pool.size():
		var mi := _pool[i]
		if i >= _active.size():
			mi.visible = false
			continue
		# Положение пересчитываем каждый кадр — вихрь дрейфует.
		var d: Dictionary = _active[i]
		var th: AtmoThermal = d.th
		var cur := model.devil(th, atmo.time_s, atmo.ground.surface_fn, _surface_wind())
		if cur.is_empty():
			mi.visible = false
			continue
		mi.visible = true
		var h: float = cur.height
		var r: float = cur.radius
		var p: Vector3 = cur.pos
		p.y = atmo.ground.height(p.x, p.z)
		mi.transform = Transform3D(Basis.from_scale(Vector3(r, h, r)), p + Vector3(0, h * 0.5, 0))
		mi.set_instance_shader_parameter("age", float(cur.age))
		mi.set_instance_shader_parameter("spin", float(cur.spin))
		mi.set_instance_shader_parameter("seed", float(cur.seed))


func _surface_wind() -> Vector2:
	return atmo.wind.vec2_at(float(cfg.drift_height_m))


## Вихри рядом с точкой: [{th, ...}] — ближние первыми, не больше max_visible.
func find(eye: Vector3) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var r2 := float(cfg.radius_m) * float(cfg.radius_m)
	var w := _surface_wind()
	for id in atmo.field.thermals:
		var th: AtmoThermal = atmo.field.thermals[id]
		var dx := th.src.x - eye.x
		var dz := th.src.z - eye.z
		if dx * dx + dz * dz > r2:
			continue
		var d := model.devil(th, atmo.time_s, atmo.ground.surface_fn, w)
		if not d.is_empty():
			d["th"] = th
			d["dist2"] = dx * dx + dz * dz
			out.append(d)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.dist2 < b.dist2)
	if out.size() > int(cfg.max_visible):
		out.resize(int(cfg.max_visible))
	return out
