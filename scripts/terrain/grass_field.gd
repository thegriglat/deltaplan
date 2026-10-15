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
## Средняя дистанция в режимах shell и angle (G4): слои GrassMidShell; null — режим blades.
var mid_layer: Node3D
## Карточки-пучки средней дистанции в режиме angle (G4 v4): GrassMidCards; null — другие режимы.
var mid_cards: GrassMidCards

## Режимы средней дистанции (G4 v4): shell — слои (по умолчанию), angle — слои и карточки по углу
## взгляда к рельефу, blades — кольца травинок (для сравнения).
const MID_MODES: PackedStringArray = ["blades", "shell", "angle"]

var _spacing: float = 0.5
var _max_agl: float = 120.0
var _layer: HeightLayer
var _last_cell := Vector2(INF, INF)
## Высота скошенной травы по умолчанию (configs/vegetation.json → grass.mowed_height_k) —
## для set_landing_sites, если площадка не задала свою.
var _mowed_height_k: float = 0.3
## Для height_at (PH-К6): карта поверхности, параметры высоты по классам, скошенные места.
var _surface: SurfaceLayer
var _cfg: Dictionary = {}
var _rock_slope_deg: float = 38.0
var _mowed_spots: Array[Vector4] = []
## Посадки для height_at: {center: Vector2, axis_deg, length_m, width_m, hk}.
var _landing_rects: Array[Dictionary] = []


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
	_surface = surface
	_cfg = cfg
	_rock_slope_deg = float(look.get("rock_slope_deg", 38.0))
	_mowed_spots = mowed_spots.slice(0, MAX_MOWED)
	_spacing = float(cfg.clump_spacing_m)
	if bool(cfg.get("density_scaled", true)):
		_spacing = spacing_for_density(_spacing, density_k(cfg))
	_max_agl = float(cfg.get("max_agl_m", 120.0))
	_mowed_height_k = float(cfg.get("mowed_height_k", 0.3))
	var radius := float(cfg.radius_m)
	var inner := float(cfg.get("inner_radius_m", -1.0))
	var offs := ring_offsets(_spacing, inner, radius)
	var n := offs.size()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = clump_mesh(int(cfg.blades_per_clump), float(cfg.blade_width_m), int(cfg.segments))
	var reach := mesh_reach(mm.mesh)
	mm.instance_count = n
	# Пучки только в кольце inner..radius: смещение клетки от центральной — в INSTANCE_CUSTOM.xy.
	var buf := PackedFloat32Array()
	buf.resize(n * 16)
	for i in n:
		buf[i * 16] = 1.0
		buf[i * 16 + 5] = 1.0
		buf[i * 16 + 10] = 1.0
		buf[i * 16 + 12] = offs[i].x
		buf[i * 16 + 13] = offs[i].y
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
	material.set_shader_parameter("leaf_tilt_deg", float(cfg.get("leaf_tilt_deg", 60.0)))
	material.set_shader_parameter("leaf_tilt_gain", float(cfg.get("leaf_tilt_gain", 1.0)))
	material.set_shader_parameter("groove_deg", float(cfg.get("groove_deg", 30.0)))
	material.set_shader_parameter("blade_normal_fade_m", _v2(cfg.get("blade_normal_fade_m", [8.0, 20.0])))
	material.set_shader_parameter("across_shade", float(cfg.get("across_shade", 0.12)))
	material.set_shader_parameter("blade_variation", float(cfg.get("blade_variation", 0.1)))
	material.set_shader_parameter("tip_dry", float(cfg.get("tip_dry", 0.25)))
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
	material.set_shader_parameter("clump_reach_m", reach)
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
	# Средняя дистанция (G4): shell — свой узел, колец травинок дальше ближнего нет
	# (дальше ~40 м луг рисует шейдер рельефа).
	var mode := mid_mode(cfg)
	if mode == "shell" or mode == "angle":
		var sh := GrassMidShell.new()
		sh.name = "GrassMidShell"
		sh.camera = camera
		add_child(sh)
		sh.setup(material, layer, cfg)
		mid_layer = sh
		if mode == "angle":
			GrassMidCards.set_angle_params(sh.material, cfg.get("mid", {}))
			mid_cards = GrassMidCards.new()
			mid_cards.name = "GrassMidCards"
			mid_cards.camera = camera
			add_child(mid_cards)
			mid_cards.setup(material, layer, cfg)
		return
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


## Смещения клеток (от центральной) пучков кольца inner..outer, м, при шаге spacing: пучок
## дрожит в клетке на ±0,45 клетки, камера — в пределах клетки, отсюда запас 2 клетки.
static func ring_offsets(spacing: float, inner: float, outer: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var m := int(ceil(outer / spacing)) + 2
	var lo := maxf(inner - 2.0 * spacing, 0.0)
	var hi := outer + 2.0 * spacing
	for j in range(-m, m + 1):
		for i in range(-m, m + 1):
			var d := Vector2(i, j).length() * spacing
			if d >= lo and d <= hi:
				out.append(Vector2(i, j))
	return out


## Материалы травы (ближний и дальний слой, средняя дистанция) — для ветра.
func materials() -> Array[ShaderMaterial]:
	var out: Array[ShaderMaterial] = [material]
	if far_layer != null:
		out.append_array(far_layer.materials())
	out.append_array(mid_materials())
	return out


## Материал слоёв средней дистанции (shell, angle); null — режим blades.
func mid_material() -> ShaderMaterial:
	return mid_layer.get("material") as ShaderMaterial if mid_layer != null else null


## Материалы средней дистанции: слои и (режим angle) карточки; пусто — режим blades.
func mid_materials() -> Array[ShaderMaterial]:
	var out: Array[ShaderMaterial] = []
	if mid_layer != null:
		out.append(mid_material())
	if mid_cards != null:
		out.append(mid_cards.material)
	return out


## Узлы средней дистанции (слои, карточки) — показать или скрыть все (кадры «без средней травы»).
func set_mid_visible(on: bool) -> void:
	if mid_layer != null:
		mid_layer.visible = on
	if mid_cards != null:
		mid_cards.visible = on


## Итоговый режим средней дистанции (G4): переменная окружения DP_GRASS_MID (для кадров и замеров)
## сильнее конфига grass.mid.mode; неизвестное значение — как конфиг, неизвестный или пустой конфиг — shell.
static func mid_mode(grass_cfg: Dictionary) -> String:
	var env := OS.get_environment("DP_GRASS_MID").strip_edges().to_lower()
	if env in MID_MODES:
		return env
	var mid: Variant = grass_cfg.get("mid", {})
	var m := String(mid.get("mode", "shell")).to_lower() if mid is Dictionary else "shell"
	return m if m in MID_MODES else "shell"


## scene-look (SL-К1/К2): параметры scene_look и рантайм (широта, день года) — материалам травы
## (сезон луга и полей, SL-6), тем же путём, что у рельефа.
func apply_scene_look(sl: Dictionary) -> void:
	for m in materials():
		TerrainRenderer.apply_scene_look_params(m, sl)


func _process(_delta: float) -> void:
	if far_layer != null:
		far_layer.camera = camera
	if mid_layer != null:
		mid_layer.set("camera", camera)
	if mid_cards != null:
		mid_cards.camera = camera
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
		for m in mid_materials():
			m.set_shader_parameter("press_pos", pilot.global_position)


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


## PH-К6: высота верхушек травы над землёй в точке мира, м; 0 — травы нет. Та же классификация,
## что у отрисовки (grass.gdshader): класс поверхности × class_share, склон круче
## terrain_look.rock_slope_deg, скошенные места и посадки-прямоугольники (hk). Высота — середина
## диапазона класса (у отрисовки она случайна по пучку), у кустарника/леса умножена на долю
## пучков. От камеры и max_agl_m не зависит. Детерминирована, без аллокаций кроме мелких.
func height_at(x: float, z: float) -> float:
	if _layer == null or _surface == null or not is_enabled(_cfg):
		return 0.0
	var c := _surface.class_at(x, z)
	if _surface.mask_contains(x, z):
		if _surface.mask_g(x, z) >= 0.5:
			return 0.0  # вода
		if _surface.mask_r(x, z) >= 0.5:
			c = SurfaceLayer.FOREST
		elif c == SurfaceLayer.FOREST:
			c = _surface.open_class_near(x, z)
	var shrub := float(_cfg.get("shrub_density", 0.5))
	var forest := float(_cfg.get("forest_density", 0.0))
	var share := class_share(c, shrub, forest)
	if share <= 0.0:
		return 0.0
	var range_v: Vector2
	match c:
		SurfaceLayer.CROP:
			range_v = _v2(_cfg.get("crop_height_m", [0.6, 0.9]))
		SurfaceLayer.FOREST:
			range_v = _v2(_cfg.get("forest_height_m", [0.12, 0.3]))
			share = forest
		_:
			range_v = _v2(_cfg.get("blade_height_m", [0.25, 0.55]))
	var h := (range_v.x + range_v.y) * 0.5 * share * float(_cfg.get("height_k", 1.0))
	var slope := slope_deg_at(_layer, x, z)
	h *= 1.0 - smoothstep(_rock_slope_deg - 4.0, _rock_slope_deg + 2.0, slope)
	var xz := Vector2(x, z)
	for m in _mowed_spots:
		if xz.distance_to(Vector2(m.x, m.y)) < m.z:
			h *= m.w
	for r in _landing_rects:
		if in_landing_rect(xz, r.center, r.axis_deg, r.length_m, r.width_m):
			h *= float(r.hk)
	return h


## Уклон рельефа в точке, градусы: уклон билинейной клетки слоя (четыре узла вокруг точки) — как
## h_grad в grass.gdshader (GR-6).
static func slope_deg_at(layer: HeightLayer, x: float, z: float) -> float:
	var fx := (x - layer.origin_x) / layer.spacing
	var fz := (z - layer.origin_z) / layer.spacing
	var i := floori(fx)
	var j := floori(fz)
	var tx := fx - i
	var tz := fz - j
	var h00 := layer.node(i, j)
	var h10 := layer.node(i + 1, j)
	var h01 := layer.node(i, j + 1)
	var h11 := layer.node(i + 1, j + 1)
	var gx := lerpf(h10 - h00, h11 - h01, tz) / layer.spacing
	var gz := lerpf(h01 - h00, h11 - h10, tx) / layer.spacing
	return rad_to_deg(atan(Vector2(gx, gz).length()))


static func _v2(a: Variant) -> Vector2:
	return Vector2(float(a[0]), float(a[1]))


## Поля рельефа (влажность, северность) → цвет травинок как у земли под ними; все слои.
func set_relief(relief: TerrainRelief) -> void:
	TerrainRenderer.set_relief(material, relief)
	for m in mid_materials():
		TerrainRenderer.set_relief(m, relief)
	if far_layer != null:
		far_layer.set_relief(relief)


## Посадки — прямоугольником, не кругом (рекомендация 4): sites — как
## WorldObjects.get_landing_sites(), [{position: Vector3, axis_deg, length_m, width_m}].
## Вызывает группа «Сцена игры»; до вызова действует круговое скашивание по
## Terrain.get_landing_sites (configs/vegetation.json → grass.landing_mow_radius_m).
func set_landing_sites(sites: Array[Dictionary]) -> void:
	_landing_rects.clear()
	for s in sites.slice(0, MAX_LANDING):
		var p: Vector3 = s.position
		_landing_rects.append(
			{
				"center": Vector2(p.x, p.z),
				"axis_deg": float(s.get("axis_deg", 0.0)),
				"length_m": float(s.length_m),
				"width_m": float(s.width_m),
				"hk": float(s.get("mowed_height_k", _mowed_height_k)),
			}
		)
	_mowed_spots.clear()
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
	var mats: Array[ShaderMaterial] = [material]
	mats.append_array(mid_materials())
	for m in mats:
		m.set_shader_parameter("landing_pos", pos)
		m.set_shader_parameter("landing_dir", dir)
		m.set_shader_parameter("landing_hk", hk)
		m.set_shader_parameter("landing_count", mini(sites.size(), MAX_LANDING))
		# Прямоугольник заменяет круговое скашивание (было до подключения группой «Сцена игры»).
		m.set_shader_parameter("mowed_count", 0)


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


## Радиус пучка в плане, м (GR-3, clump_reach_m): наибольшее |VERTEX.xz| сетки — корни, изгиб и
## полуширина травинок; шейдер умножает на ширину вдали и добавляет наклон.
static func mesh_reach(mesh: Mesh) -> float:
	var r := 0.0
	for v in mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]:
		r = maxf(r, Vector2(v.x, v.z).length())
	return r


## Пучок травинок: blades штук в круге ~0,15 м, каждая — полоска из segments отрезков,
## VERTEX.y = t 0..1 (высоту и наклон задаёт шейдер), VERTEX.xz — смещение в метрах.
## Лист злака сужается к острому кончику выпукло: полуширина width/2·(1 − t^1,5) (GR-6; было линейно
## до 0,2 и обрыв на кончик — площадь листа и цена закраски почти те же, +4 %).
## NORMAL — лицо травинки (горизонталь в плане пучка); UV.x — поперёк −1…+1 (кончик 0),
## UV.y — случайное число травинки 0..1 (яркость, сухость кончика) — для grass.gdshader.
static func clump_mesh(blades: int, width: float, segments: int) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	for b in blades:
		var base := Vector2.from_angle(rng.randf() * TAU) * sqrt(rng.randf()) * 0.15
		var face := Vector2.from_angle(rng.randf() * TAU)
		var side := Vector2(-face.y, face.x)
		var curl := face * rng.randf_range(0.02, 0.08)
		var br := rng.randf()
		var fn := Vector3(face.x, 0.0, face.y)
		var start := verts.size()
		for s in segments:
			var t := float(s) / segments
			var w := width * (1.0 - t * sqrt(t)) * 0.5
			var c := base + curl * t * t
			verts.append(Vector3(c.x - side.x * w, t, c.y - side.y * w))
			verts.append(Vector3(c.x + side.x * w, t, c.y + side.y * w))
			normals.append_array(PackedVector3Array([fn, fn]))
			uvs.append_array(PackedVector2Array([Vector2(-1.0, br), Vector2(1.0, br)]))
		var tip := base + curl
		verts.append(Vector3(tip.x, 1.0, tip.y))
		normals.append(fn)
		uvs.append(Vector2(0.0, br))
		for s in segments - 1:
			var a := start + s * 2
			idx.append_array(PackedInt32Array([a, a + 2, a + 1, a + 1, a + 2, a + 3]))
		var last := start + (segments - 1) * 2
		idx.append_array(PackedInt32Array([last, last + 2, last + 1]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


# --- Примятая трава у старта (SC-K6, SC-3): маска R8 вокруг старта игрока ---

## Маска приминания: байты R8 (строка — z, столбец — x), размер в текселях, начало мира и шаг клетки.
var _trample_bytes := PackedByteArray()
var _trample_size := Vector2i.ZERO
var _trample_origin := Vector2.ZERO
var _trample_cell: float = 0.5


## Маска примятой травы (SC-K6): img — FORMAT_R8 (0 — нетронута, 255 — примята до земли), тексель
## (i, j) покрывает мир x ∈ [origin.x + i·cell, +cell), z ∈ [origin.y + j·cell, +cell); null — снять.
## Применяется ко всем материалам поля (ближний и дальний слой). Шейдер: ниже, наклонена, желтее.
func set_trample_mask(img: Image, origin: Vector2, cell_m: float) -> void:
	if img == null or img.get_format() != Image.FORMAT_R8 or cell_m <= 0.0:
		_trample_bytes = PackedByteArray()
		_trample_size = Vector2i.ZERO
	else:
		_trample_bytes = img.get_data()
		_trample_size = Vector2i(img.get_width(), img.get_height())
		_trample_origin = origin
		_trample_cell = cell_m
	for m in materials():
		if m == null:
			continue
		if _trample_bytes.is_empty():
			m.set_shader_parameter("trample_on", 0.0)
			m.set_shader_parameter("trample_tex", null)
			continue
		var size_m := Vector2(_trample_size) * cell_m
		m.set_shader_parameter("trample_tex", ImageTexture.create_from_image(img))
		m.set_shader_parameter(
			"trample_rect", Vector4(origin.x, origin.y, 1.0 / size_m.x, 1.0 / size_m.y)
		)
		m.set_shader_parameter("trample_on", 1.0)
		var look := _trample_look()
		for k in look:
			m.set_shader_parameter(k, look[k])


## Приминание в точке (x, z), 0..1: билинейно по центрам текселей (как фильтр текстуры в шейдере),
## у края маски — значение крайнего текселя, вне маски и без маски — 0. CPU, для звука шагов.
func trample_at(x: float, z: float) -> float:
	if _trample_bytes.is_empty():
		return 0.0
	var u := (x - _trample_origin.x) / _trample_cell
	var v := (z - _trample_origin.y) / _trample_cell
	if u < 0.0 or v < 0.0 or u >= _trample_size.x or v >= _trample_size.y:
		return 0.0
	u -= 0.5
	v -= 0.5
	var i0 := int(floor(u))
	var j0 := int(floor(v))
	var fu := u - i0
	var fv := v - j0
	var a := _trample_texel(i0, j0)
	var b := _trample_texel(i0 + 1, j0)
	var c := _trample_texel(i0, j0 + 1)
	var d := _trample_texel(i0 + 1, j0 + 1)
	return lerpf(lerpf(a, b, fu), lerpf(c, d, fu), fv)


func _trample_texel(i: int, j: int) -> float:
	i = clampi(i, 0, _trample_size.x - 1)
	j = clampi(j, 0, _trample_size.y - 1)
	return float(_trample_bytes[j * _trample_size.x + i]) / 255.0


## Вид примятой травы: configs/vegetation.json → grass.trample (trample_height_k, trample_lean,
## trample_tint); нет конфига — значения по умолчанию из шейдера.
func _trample_look() -> Dictionary:
	var out := {}
	if not FileAccess.file_exists("res://configs/vegetation.json"):
		return out
	var t: Dictionary = Config.get_config("vegetation").get("grass", {}).get("trample", {})
	if t.has("height_k"):
		out["trample_height_k"] = float(t.height_k)
	if t.has("lean"):
		out["trample_lean"] = float(t.lean)
	if t.has("tint") and t.tint is Array and t.tint.size() == 3:
		out["trample_tint"] = Vector3(float(t.tint[0]), float(t.tint[1]), float(t.tint[2]))
	return out
