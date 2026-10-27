class_name DustDevils
extends Node3D
## Пылевые вихри рядом с камерой (VR-18) — видимый признак молодого термика над сухим полем.
## Вихрь выводится из ядра подъёма фасада (cores, W6: возраст, жизнь, стадия, сила) и поверхности;
## здесь же отрисовка: пул из max_visible конусов с шейдером закрученной пыли.

var atmo: Atmosphere
var cfg: Dictionary
var model: DustModel = DustModel.new()
## Высота рельефа (x, z) -> м MSL и класс поверхности (x, z) -> int: даёт Atmosphere при создании
## слоя; пустые — земля на нуле и сухо везде.
var ground_fn: Callable = Callable()
var surface_fn: Callable = Callable()
## Положение наблюдателя — по умолчанию активная камера; тестам и превью можно задать.
var eye_fn: Callable = Callable()
var _chance: float = 0.0
var _dusty: Array = []
## Доля роста в жизни термика по конфигу (длительности роста в описании ядра нет).
var _grow_share: float = 0.2
var _pool: Array[MeshInstance3D] = []
var _skirts: Array[MeshInstance3D] = []
var _acc: float = 1.0e9
var _surface_w: Vector2 = Vector2.ZERO
var _active: Array[Dictionary] = []


func setup(atmosphere: Atmosphere, ground: Callable = Callable(), surface: Callable = Callable()) -> void:
	atmo = atmosphere
	ground_fn = ground
	surface_fn = surface
	cfg = atmo.cfg.dust
	var tc: Dictionary = atmo.cfg.thermal
	var g := (float(tc.grow_s[0]) + float(tc.grow_s[1])) * 0.5
	var m := (float(tc.mature_s[0]) + float(tc.mature_s[1])) * 0.5
	var d := (float(tc.decay_s[0]) + float(tc.decay_s[1])) * 0.5
	_grow_share = g / maxf(g + m + d, 1.0e-6)
	_dusty.clear()
	for c in cfg.dusty_surface_classes:
		_dusty.append(int(c))
	_reload_weather()
	atmo.weather_changed.connect(_reload_weather)
	atmo.weather_updated.connect(_reload_weather)
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
	# Юбка — пологий конус: широкий у земли, сходит на нет кверху.
	var cone := CylinderMesh.new()
	cone.top_radius = 0.35
	cone.bottom_radius = 1.0
	cone.height = 1.0
	cone.cap_top = false
	cone.cap_bottom = false
	cone.radial_segments = 24
	for i in int(cfg.max_visible):
		var mi := MeshInstance3D.new()
		mi.mesh = cyl
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		add_child(mi)
		_pool.append(mi)
		var sk := MeshInstance3D.new()
		sk.mesh = cone
		sk.material_override = mat
		sk.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		sk.visible = false
		sk.set_instance_shader_parameter("skirt", 1.0)
		add_child(sk)
		_skirts.append(sk)


func _reload_weather() -> void:
	_chance = float(atmo.get_weather().get("dust_devil_chance", 0.0))
	model.setup(cfg, atmo.get_weather())


func _eye() -> Vector3:
	if eye_fn.is_valid():
		return eye_fn.call()
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	return cam.global_position if cam != null else Vector3.ZERO


func _ground(x: float, z: float) -> float:
	var h := float(ground_fn.call(x, z)) if ground_fn.is_valid() else 0.0
	return h if is_finite(h) else 0.0


func _process(delta: float) -> void:
	if atmo == null:
		return
	var eye := _eye()
	var t := float(atmo.status().time_s)
	_acc += delta
	if _acc > 0.5:
		_acc = 0.0
		_active = find(eye)
	for i in _pool.size():
		var mi := _pool[i]
		var sk := _skirts[i]
		if i >= _active.size():
			mi.visible = false
			sk.visible = false
			continue
		# Положение пересчитываем каждый кадр — вихрь дрейфует.
		var d: Dictionary = _active[i]
		var cur := devil_of(d.th, t, _surface_w)
		if cur.is_empty():
			mi.visible = false
			sk.visible = false
			continue
		mi.visible = true
		var h: float = cur.height
		var r: float = cur.radius
		var p: Vector3 = cur.pos
		p.y = _ground(p.x, p.z)
		mi.transform = Transform3D(Basis.from_scale(Vector3(r, h, r)), p + Vector3(0, h * 0.5, 0))
		mi.set_instance_shader_parameter("age", float(cur.age))
		mi.set_instance_shader_parameter("spin", float(cur.spin))
		mi.set_instance_shader_parameter("seed", float(cur.seed))
		# Юбка: низкий широкий конус у земли.
		var rb := r * float(cfg.base_radius_frac)
		var skr := rb * float(cfg.skirt_radius_frac)
		var skh := h * float(cfg.skirt_height_frac)
		sk.visible = true
		sk.transform = Transform3D(
			Basis.from_scale(Vector3(skr, skh, skr)), p + Vector3(0, skh * 0.5, 0)
		)
		sk.set_instance_shader_parameter("age", float(cur.age))
		sk.set_instance_shader_parameter("spin", float(cur.spin))
		sk.set_instance_shader_parameter("seed", float(cur.seed) + 7.0)


## Приземный ветер для дрейфа вихрей (W2 background_wind на drift_height_m над долиной).
func _surface_wind() -> Vector2:
	var h := float(atmo.get_weather().get("_derived", {}).get("valley_msl_m", 0.0))
	var bw := atmo.background_wind(PackedFloat32Array([h + float(cfg.drift_height_m)]))
	return Vector2(bw[0], bw[1])


## Вихрь у ядра подъёма th (запись BirdFlock.parse_cores, снимок на момент th.t) в момент t:
## {pos: Vector3 (на земле), height, radius, age 0..1, spin, seed} или {}. Правила — как DustModel.devil:
## молодой (стадия роста) достаточно сильный нестатический термик, вероятность дня, срок жизни,
## сухая поверхность; детерминированно от id ядра. Рост (t_grow) — по доле роста в жизни.
func devil_of(th: Dictionary, t: float, wind: Vector2) -> Dictionary:
	var min_strength := float(cfg.min_strength_ms)
	if _chance <= 0.0 or bool(th.static) or float(th.strength) < min_strength:
		return {}
	var rng := RandomNumberGenerator.new()
	rng.seed = int(th.id) * 7919 + 13
	if rng.randf() >= _chance:
		return {}
	var life_r: Array = cfg.life_s
	var life := rng.randf_range(float(life_r[0]), float(life_r[1]))
	var t_grow := float(th.life) * _grow_share
	var start_age := rng.randf() * t_grow * float(cfg.start_grow_frac)
	var age_now := float(th.age) + (t - float(th.t))
	var age := (age_now - start_age) / life
	if age < 0.0 or age > 1.0:
		return {}
	if surface_fn.is_valid() and not _dusty.has(int(surface_fn.call(th.x, th.z))):
		return {}
	var smax := 5.0
	var k := clampf((float(th.strength) - min_strength) / maxf(smax - min_strength, 0.1), 0.0, 1.0)
	var hr: Array = cfg.height_m
	var h := lerpf(float(hr[0]), float(hr[1]), k) * rng.randf_range(0.7, 1.0)
	var drift := wind * (age_now - start_age)
	return {
		"pos": Vector3(float(th.x) + drift.x, float(th.y_src), float(th.z) + drift.y),
		"height": h,
		"radius": h * float(cfg.top_radius_frac) + 8.0,
		"age": age,
		"spin": 1.0 if rng.randf() < 0.5 else -1.0,
		"seed": float(int(th.id) % 997),
	}


## Вихри рядом с точкой: [{th, ...}] — ближние первыми, не больше max_visible.
func find(eye: Vector3) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var r := float(cfg.radius_m)
	var r2 := r * r
	var t := float(atmo.status().time_s)
	var w := _surface_wind()
	_surface_w = w
	for th in BirdFlock.parse_cores(atmo.cores(eye, r)):
		th["t"] = t
		var dx := float(th.x) - eye.x
		var dz := float(th.z) - eye.z
		if dx * dx + dz * dz > r2:
			continue
		var d := devil_of(th, t, w)
		if not d.is_empty():
			d["th"] = th
			d["dist2"] = dx * dx + dz * dz
			out.append(d)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.dist2 < b.dist2)
	if out.size() > int(cfg.max_visible):
		out.resize(int(cfg.max_visible))
	return out
