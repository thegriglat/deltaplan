class_name GrassField
extends MultiMeshInstance3D
## Травинки вокруг камеры (VR-17, VR-6): сетка пучков едет за камерой, пучок привязан к мировой
## клетке; всё остальное (есть ли трава, высота, цвет, качание) — в grass.gdshader.
## Видна на старте, при разбеге и посадке (выше max_agl_m — выключена).
## Параметры — configs/vegetation.json → grass.

const SHADER := preload("res://scripts/terrain/grass.gdshader")
## Скошенных мест в шейдере (размер массива mowed).
const MAX_MOWED := 4
## Посадочных площадок-прямоугольников (set_landing_sites) в шейдере.
const MAX_LANDING := 4

var camera: Camera3D
## Нода пилота (приминание травы у ног); null — не приминать.
var pilot: Node3D
var material: ShaderMaterial
## Дальний слой пучков (grass.far), дочерний GrassField; null — нет.
var far_layer: GrassField

var _spacing: float = 0.5
var _max_agl: float = 120.0
var _layer: HeightLayer
var _last_cell := Vector2(INF, INF)
## Высота скошенной травы по умолчанию (configs/vegetation.json → grass.mowed_height_k) —
## для set_landing_sites, если площадка не задала свою.
var _mowed_height_k: float = 0.3


func setup(
	layer: HeightLayer,
	height_tex: Texture2D,
	surface: SurfaceLayer,
	surface_tex: Texture2D,
	look: Dictionary,
	cfg: Dictionary,
	mowed_spots: Array[Vector4]
) -> void:
	_layer = layer
	_spacing = float(cfg.clump_spacing_m)
	if bool(cfg.get("density_scaled", true)):
		_spacing = spacing_for_density(_spacing, density_k(cfg))
	_max_agl = float(cfg.get("max_agl_m", 120.0))
	_mowed_height_k = float(cfg.get("mowed_height_k", 0.3))
	var radius := float(cfg.radius_m)
	var n := int(ceil(2.0 * radius / _spacing)) + 1
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = clump_mesh(int(cfg.blades_per_clump), float(cfg.blade_width_m), int(cfg.segments))
	mm.instance_count = n * n
	var buf := PackedFloat32Array()
	buf.resize(n * n * 12)
	for i in n * n:
		buf[i * 12] = 1.0
		buf[i * 12 + 5] = 1.0
		buf[i * 12 + 10] = 1.0
	mm.buffer = buf
	multimesh = mm
	material = ShaderMaterial.new()
	material.shader = SHADER
	material.set_shader_parameter("height_tex", height_tex)
	material.set_shader_parameter("layer_origin", Vector2(layer.origin_x, layer.origin_z))
	material.set_shader_parameter("layer_spacing", layer.spacing)
	material.set_shader_parameter("layer_texels", Vector2(layer.width, layer.height))
	TerrainRenderer.apply_look_params(material, look)
	TerrainRenderer.set_surface(material, surface, surface_tex)
	material.set_shader_parameter("grid_n", n)
	material.set_shader_parameter("clump_spacing_m", _spacing)
	material.set_shader_parameter("area_radius_m", radius)
	material.set_shader_parameter("blade_height_m", _v2(cfg.blade_height_m))
	material.set_shader_parameter("crop_height_m", _v2(cfg.crop_height_m))
	material.set_shader_parameter("shrub_density", float(cfg.shrub_density))
	material.set_shader_parameter("forest_density", float(cfg.get("forest_density", 0.0)))
	material.set_shader_parameter("forest_height_m", _v2(cfg.get("forest_height_m", [0.12, 0.3])))
	material.set_shader_parameter("forest_shade", float(cfg.get("forest_shade", 1.0)))
	material.set_shader_parameter("color_variation", float(cfg.color_variation))
	var tint: Array = cfg.get("blade_tint", [1.08, 1.0, 0.85])
	material.set_shader_parameter("blade_tint", Vector3(tint[0], tint[1], tint[2]))
	material.set_shader_parameter("blade_shade", _v2(cfg.get("blade_shade", [1.25, 1.75])))
	material.set_shader_parameter("macro_noise_tex", TerrainRenderer.macro_noise_texture())
	material.set_shader_parameter("dry_clump_share", float(cfg.get("dry_clump_share", 0.0)))
	material.set_shader_parameter("sway_hz", float(cfg.sway_hz))
	material.set_shader_parameter("sway_hz_var", float(cfg.get("sway_hz_var", 0.0)))
	material.set_shader_parameter("sway_amp", float(cfg.sway_amp))
	material.set_shader_parameter("bend_amp", float(cfg.bend_amp))
	material.set_shader_parameter("press_radius_m", float(cfg.press_radius_m))
	material.set_shader_parameter("press_agl_full_m", float(cfg.get("press_agl_full_m", 0.4)))
	material.set_shader_parameter("press_agl_zero_m", float(cfg.get("press_agl_zero_m", 1.2)))
	material.set_shader_parameter("far_density_min", float(cfg.get("far_density_min", 0.12)))
	material.set_shader_parameter("thin_start_k", float(cfg.get("thin_start_k", 0.1)))
	material.set_shader_parameter("thin_end_k", float(cfg.get("thin_end_k", 0.85)))
	material.set_shader_parameter("far_width_k", float(cfg.get("far_width_k", 1.7)))
	material.set_shader_parameter("inner_radius_m", float(cfg.get("inner_radius_m", -1.0)))
	material.set_shader_parameter("inner_fade_m", maxf(float(cfg.get("inner_fade_m", 0.0)), 0.001))
	material.set_shader_parameter("xfade_k", float(cfg.get("xfade_k", 1.0)))
	material.set_shader_parameter("height_fade_k", float(cfg.get("height_fade_k", 0.6)))
	material.set_shader_parameter("height_k", float(cfg.get("height_k", 1.0)))
	material.set_shader_parameter("landing_count", 0)
	var spots := mowed_spots.slice(0, MAX_MOWED)
	while spots.size() < MAX_MOWED:
		spots.append(Vector4(1e9, 1e9, 0.0, 1.0))
	material.set_shader_parameter("mowed", spots)
	material.set_shader_parameter("mowed_count", mini(mowed_spots.size(), MAX_MOWED))
	material_override = material
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	custom_aabb = AABB(
		Vector3(layer.origin_x, layer.min_h - 10.0, layer.origin_z),
		Vector3(layer.size_x(), layer.max_h - layer.min_h + 20.0, layer.size_z())
	)
	# Дальний слой (configs/vegetation.json → grass.far): крупные редкие пучки кольцом за
	# ближними травинками — те же параметры, переопределённые ключами far.
	var far_cfg: Variant = cfg.get("far", null)
	if far_cfg is Dictionary and bool(far_cfg.get("enabled", true)):
		var fc := cfg.duplicate(true)
		fc.erase("far")
		fc.merge(far_cfg, true)
		far_layer = GrassField.new()
		far_layer.name = "GrassFar"
		far_layer.camera = camera
		add_child(far_layer)
		far_layer.setup(layer, height_tex, surface, surface_tex, look, fc, mowed_spots)


## Материалы травы (ближний и дальний слой) — для ветра.
func materials() -> Array[ShaderMaterial]:
	var out: Array[ShaderMaterial] = [material]
	if far_layer != null:
		out.append_array(far_layer.materials())
	return out


func _process(_delta: float) -> void:
	if far_layer != null:
		far_layer.camera = camera
	var cam := camera if camera != null else get_viewport().get_camera_3d()
	if cam == null or material == null:
		return
	var p := cam.global_position
	visible = p.y - _layer.sample(p.x, p.z) < _max_agl
	if not visible:
		return
	var cell := Vector2(floor(p.x / _spacing), floor(p.z / _spacing))
	if cell != _last_cell:
		_last_cell = cell
		material.set_shader_parameter("grid_center_cell", cell)
	if pilot != null and pilot.is_inside_tree():
		material.set_shader_parameter("press_pos", pilot.global_position)


## Густота травы (grass.density_pct: слайдер «Густота травы» в настройках, пресеты графики),
## доля: 1.0 — как задано clump_spacing_m; 0 — трава выключена.
static func density_k(grass_cfg: Dictionary) -> float:
	return maxf(float(grass_cfg.get("density_pct", 100.0)), 0.0) / 100.0


## Шаг пучков при густоте k: число пучков на площадь ∝ k, шаг — как 1/√k.
static func spacing_for_density(spacing: float, k: float) -> float:
	return spacing / sqrt(maxf(k, 0.05))


## Трава включена: enabled и густота больше нуля.
static func is_enabled(grass_cfg: Dictionary) -> bool:
	return bool(grass_cfg.get("enabled", false)) and density_k(grass_cfg) > 0.0


## Доля пучков на классе поверхности (та же ветка, что в grass.gdshader: луг/пашня/класс 0 — все,
## кустарник — shrub_density, лес — forest_density (трава под пологом, К2 v2), прочие — нет).
static func class_share(c: int, shrub_density: float, forest_density: float) -> float:
	match c:
		SurfaceLayer.NONE, SurfaceLayer.GRASS, SurfaceLayer.CROP:
			return 1.0
		SurfaceLayer.SHRUB:
			return shrub_density
		SurfaceLayer.FOREST:
			return forest_density
	return 0.0


static func _v2(a: Variant) -> Vector2:
	return Vector2(float(a[0]), float(a[1]))


## Поля рельефа (влажность, северность) → цвет травинок как у земли под ними; все слои.
func set_relief(relief: TerrainRelief) -> void:
	TerrainRenderer.set_relief(material, relief)
	if far_layer != null:
		far_layer.set_relief(relief)


## Посадки — прямоугольником, не кругом (рекомендация 4): sites — как
## WorldObjects.get_landing_sites(), [{position: Vector3, axis_deg, length_m, width_m}].
## Вызывает группа «Сцена игры»; до вызова действует круговое скашивание по
## Terrain.get_landing_sites (configs/vegetation.json → grass.landing_mow_radius_m).
func set_landing_sites(sites: Array[Dictionary]) -> void:
	if material == null:
		return
	if far_layer != null:
		far_layer.set_landing_sites(sites)
	var pos: Array[Vector4] = []
	var dir: Array[Vector4] = []
	var hk := PackedFloat32Array()
	for s in sites.slice(0, MAX_LANDING):
		var p: Vector3 = s.position
		var axis3 := TerrainGeo.heading_vector(float(s.get("axis_deg", 0.0)))
		var right3 := axis3.cross(Vector3.UP)
		pos.append(Vector4(p.x, p.z, float(s.length_m) * 0.5, float(s.width_m) * 0.5))
		dir.append(Vector4(axis3.x, axis3.z, right3.x, right3.z))
		hk.append(float(s.get("mowed_height_k", _mowed_height_k)))
	while pos.size() < MAX_LANDING:
		pos.append(Vector4(1e9, 1e9, 0.0, 0.0))
		dir.append(Vector4(1.0, 0.0, 0.0, 1.0))
		hk.append(1.0)
	material.set_shader_parameter("landing_pos", pos)
	material.set_shader_parameter("landing_dir", dir)
	material.set_shader_parameter("landing_hk", hk)
	material.set_shader_parameter("landing_count", mini(sites.size(), MAX_LANDING))
	# Прямоугольник заменяет круговое скашивание (было до подключения группой «Сцена игры»).
	material.set_shader_parameter("mowed_count", 0)


## Точка (x, z) в прямоугольнике посадки (та же формула, что в grass.gdshader):
## center — центр площадки, axis_deg — курс длинной оси, length_m/width_m — размеры.
static func in_landing_rect(
	xz: Vector2, center: Vector2, axis_deg: float, length_m: float, width_m: float
) -> bool:
	var axis3 := TerrainGeo.heading_vector(axis_deg)
	var right3 := axis3.cross(Vector3.UP)
	var d := xz - center
	var along := d.dot(Vector2(axis3.x, axis3.z))
	var across := d.dot(Vector2(right3.x, right3.z))
	return absf(along) <= length_m * 0.5 and absf(across) <= width_m * 0.5


## Прореживание пучков вдали (рекомендация 1): доля видимых пучков на расстоянии d
## от камеры, 1.0 у камеры → far_density_min у границы area_radius_m (та же формула,
## что uniform'ы far_density_min/thin_start_k/thin_end_k в grass.gdshader).
static func far_density(
	d: float, area_radius_m: float, far_density_min: float, thin_start_k: float, thin_end_k: float
) -> float:
	if area_radius_m <= 0.0:
		return far_density_min
	var t := clampf(d / area_radius_m, 0.0, 1.0)
	return lerpf(1.0, far_density_min, smoothstep(thin_start_k, thin_end_k, t))


## Ширина пучка вдали относительно ближней (та же смесь, что far_density, но к far_width_k).
static func far_width_scale(
	d: float, area_radius_m: float, far_width_k: float, thin_start_k: float, thin_end_k: float
) -> float:
	if area_radius_m <= 0.0:
		return 1.0
	var t := clampf(d / area_radius_m, 0.0, 1.0)
	return lerpf(1.0, far_width_k, smoothstep(thin_start_k, thin_end_k, t))


## Хеш пучка → rank 0..1 (совпадает с hash12 в terrain_common.gdshaderinc + offset 20.5
## в grass.gdshader): пучок виден, если rank < far_density(d, ...).
static func clump_rank(cell: Vector2) -> float:
	return _hash12(cell + Vector2(20.5, 0.0))


static func _hash12(p_in: Vector2) -> float:
	var p := Vector2(fmod(p_in.x, 4096.0), fmod(p_in.y, 4096.0))
	var fx := fposmod(p.x * 0.1031, 1.0)
	var fy := fposmod(p.y * 0.1031, 1.0)
	var p3 := Vector3(fx, fy, fx)  # vec3(p.xyx) в grass.gdshader/hash12
	var dot_v := p3.dot(Vector3(p3.y + 33.33, p3.z + 33.33, p3.x + 33.33))
	p3 += Vector3(dot_v, dot_v, dot_v)
	return fposmod((p3.x + p3.y) * p3.z, 1.0)


## Приминание по высоте ног пилота над землёй (рекомендация 3): 1.0 — полное (agl ≤ full_m),
## 0.0 — нет (agl ≥ zero_m). Та же формула, что near_ground в grass.gdshader.
static func near_ground_factor(agl_m: float, full_m: float, zero_m: float) -> float:
	return 1.0 - smoothstep(full_m, zero_m, agl_m)


## Приминание по расстоянию от пилота в плоскости XZ (доля press_radius_m), умноженное
## на near_ground_factor — итоговый коэффициент 0..1, как press в grass.gdshader.
static func press_factor(
	dist_xz: float, press_radius_m: float, agl_m: float, full_m: float, zero_m: float
) -> float:
	var near_ground := near_ground_factor(agl_m, full_m, zero_m)
	var radial := 1.0 - smoothstep(press_radius_m * 0.4, press_radius_m, dist_xz)
	return near_ground * radial


## Пучок травинок: blades штук в круге ~0,15 м, каждая — полоска из segments отрезков,
## VERTEX.y = t 0..1 (высоту и наклон задаёт шейдер), VERTEX.xz — смещение в метрах.
static func clump_mesh(blades: int, width: float, segments: int) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var verts := PackedVector3Array()
	var idx := PackedInt32Array()
	for b in blades:
		var base := Vector2.from_angle(rng.randf() * TAU) * sqrt(rng.randf()) * 0.15
		var face := Vector2.from_angle(rng.randf() * TAU)
		var side := Vector2(-face.y, face.x)
		var curl := face * rng.randf_range(0.02, 0.08)
		var start := verts.size()
		for s in segments:
			var t := float(s) / segments
			var w := width * (1.0 - t * 0.8) * 0.5
			var c := base + curl * t * t
			verts.append(Vector3(c.x - side.x * w, t, c.y - side.y * w))
			verts.append(Vector3(c.x + side.x * w, t, c.y + side.y * w))
		var tip := base + curl
		verts.append(Vector3(tip.x, 1.0, tip.y))
		for s in segments - 1:
			var a := start + s * 2
			idx.append_array(PackedInt32Array([a, a + 2, a + 1, a + 1, a + 2, a + 3]))
		var last := start + (segments - 1) * 2
		idx.append_array(PackedInt32Array([last, last + 2, last + 1]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
