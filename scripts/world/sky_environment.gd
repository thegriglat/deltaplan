class_name SkyEnvironment
extends Node3D
## Небо, солнце с тенями, дымка до горизонта (FR-20) и мутный слой перемешивания под инверсией
## (VR-3, haze.gdshader). Все параметры — configs/world.json.
## Создаёт дочерние WorldEnvironment, DirectionalLight3D и Haze (полноэкранный квад).
## Сцена: scenes/world/environment.tscn.
## Интегратор: set_inversion_height_msl(atmosphere.get_cloudbase_msl()) при смене погоды —
## верх дымки = эта высота + haze.top_margin_m.

const HAZE_SHADER := preload("res://scripts/world/haze.gdshader")

var world_env: WorldEnvironment
var sun: DirectionalLight3D
## Полноэкранный квад дымки (null — дымка выключена в конфиге).
var haze: MeshInstance3D

var _haze_mat: ShaderMaterial
var _inversion_msl: float = NAN


func _ready() -> void:
	apply_config()


## Перечитать configs/world.json и применить (после Config.reload()).
func apply_config() -> void:
	var cfg: Dictionary = Config.get_config("world")
	var sun_cfg: Dictionary = cfg.get("sun", {})
	var sky_cfg: Dictionary = cfg.get("sky", {})
	var fog_cfg: Dictionary = cfg.get("fog", {})
	var rend: Dictionary = cfg.get("rendering", {})
	var fx: Dictionary = cfg.get("effects", {})

	if sun == null:
		sun = DirectionalLight3D.new()
		sun.name = "Sun"
		add_child(sun)
	var dir := TerrainGeo.sun_direction(float(sun_cfg.azimuth_deg), float(sun_cfg.elevation_deg))
	# Свет светит вдоль −Z узла: направляем −Z от солнца к земле.
	sun.basis = Basis.looking_at(-dir, Vector3.UP if absf(dir.y) < 0.999 else Vector3.FORWARD)
	sun.light_energy = float(sun_cfg.energy)
	sun.light_color = _color(sun_cfg.color)
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = float(sun_cfg.shadow_max_distance_m)
	sun.directional_shadow_split_1 = float(sun_cfg.shadow_split_1)
	sun.directional_shadow_split_2 = float(sun_cfg.shadow_split_2)
	sun.directional_shadow_split_3 = float(sun_cfg.shadow_split_3)
	sun.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_AND_SKY
	sun.light_angular_distance = float(sun_cfg.get("angular_distance_deg", 0.0))
	sun.shadow_blur = float(sun_cfg.get("shadow_blur", 1.0))

	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = _color(sky_cfg.top_color)
	sky_mat.sky_horizon_color = _color(sky_cfg.horizon_color)
	sky_mat.sky_curve = float(sky_cfg.curve)
	sky_mat.ground_horizon_color = _color(sky_cfg.ground_horizon_color)
	sky_mat.ground_bottom_color = _color(sky_cfg.ground_bottom_color)
	sky_mat.sun_angle_max = float(sky_cfg.sun_angle_max_deg)
	sky_mat.sun_curve = float(sky_cfg.sun_curve)
	sky_mat.energy_multiplier = float(sky_cfg.energy_multiplier)
	var sky := Sky.new()
	sky.sky_material = sky_mat

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = float(sky_cfg.ambient_light_energy)
	env.ambient_light_sky_contribution = float(sky_cfg.ambient_sky_contribution)
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = float(rend.tonemap_exposure)
	env.tonemap_white = float(rend.tonemap_white)
	# туман Godot — только если задан (голубая дымка чистого воздуха — в haze.gdshader)
	env.fog_enabled = float(fog_cfg.density) > 0.0
	env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	env.fog_density = float(fog_cfg.density)
	env.fog_light_color = _color(fog_cfg.color)
	env.fog_sun_scatter = float(fog_cfg.sun_scatter)
	env.fog_aerial_perspective = float(fog_cfg.aerial_perspective)
	env.fog_sky_affect = float(fog_cfg.sky_affect)
	env.fog_height = float(fog_cfg.height_m)
	env.fog_height_density = float(fog_cfg.height_density)

	env.glow_enabled = bool(fx.get("glow_enabled", false))
	env.glow_intensity = float(fx.get("glow_intensity", 0.8))
	env.glow_bloom = float(fx.get("glow_bloom", 0.0))
	env.glow_hdr_threshold = float(fx.get("glow_hdr_threshold", 1.0))
	env.ssao_enabled = bool(fx.get("ssao_enabled", false))
	env.ssao_radius = float(fx.get("ssao_radius_m", 1.0))
	env.ssao_intensity = float(fx.get("ssao_intensity", 2.0))
	env.adjustment_enabled = true
	env.adjustment_saturation = float(fx.get("saturation", 1.0))
	env.adjustment_contrast = float(fx.get("contrast", 1.0))
	env.adjustment_brightness = float(fx.get("brightness", 1.0))

	if world_env == null:
		world_env = WorldEnvironment.new()
		world_env.name = "WorldEnvironment"
		add_child(world_env)
	world_env.environment = env
	_apply_haze(cfg.get("haze", {}), dir, _color(sun_cfg.color))


## Высота инверсии (верх слоя перемешивания), м над уровнем моря. Обычно — основание облаков
## Atmosphere.get_cloudbase_msl(); верх дымки = h + haze.top_margin_m.
func set_inversion_height_msl(h: float) -> void:
	_inversion_msl = h
	if _haze_mat != null:
		_haze_mat.set_shader_parameter("top_msl", get_haze_top_msl())


## Верх дымки над уровнем моря, м.
func get_haze_top_msl() -> float:
	var hz: Dictionary = Config.get_config("world").get("haze", {})
	if is_nan(_inversion_msl):
		return float(hz.get("default_top_msl_m", 2000.0))
	return _inversion_msl + float(hz.get("top_margin_m", 0.0))


## Материал дымки (для тестов и отладки), null — выключена.
func haze_material() -> ShaderMaterial:
	return _haze_mat


func _apply_haze(hz: Dictionary, to_sun: Vector3, sun_color: Color) -> void:
	if not bool(hz.get("enabled", false)):
		if haze != null:
			haze.queue_free()
			haze = null
			_haze_mat = null
		return
	if haze == null:
		haze = MeshInstance3D.new()
		haze.name = "Haze"
		var quad := QuadMesh.new()
		haze.mesh = quad
		haze.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# квад рисуется на весь экран из вершинного шейдера — не отсекать
		haze.extra_cull_margin = 16384.0
		haze.custom_aabb = AABB(Vector3(-1e6, -1e6, -1e6), Vector3(2e6, 2e6, 2e6))
		_haze_mat = ShaderMaterial.new()
		_haze_mat.shader = HAZE_SHADER
		_haze_mat.render_priority = Material.RENDER_PRIORITY_MAX
		haze.material_override = _haze_mat
		add_child(haze)
	var vis_m := maxf(float(hz.get("visibility_km", 30.0)), 0.1) * 1000.0
	# Формула Кошмидера: видимость = 3.912 / коэффициент ослабления (контраст 2 %).
	_haze_mat.set_shader_parameter("extinction", 3.912 / vis_m)
	_haze_mat.set_shader_parameter("top_msl", get_haze_top_msl())
	_haze_mat.set_shader_parameter("top_transition_m", float(hz.get("top_transition_m", 50.0)))
	_haze_mat.set_shader_parameter(
		"max_distance_m", float(hz.get("max_distance_km", 150.0)) * 1000.0
	)
	# Хорошая видимость — голубая воздушная перспектива, сильная дымка — серо-белёсая.
	var tv: Array = hz.get("turbid_visibility_km", [40.0, 10.0])
	var grey := clampf(
		(float(tv[0]) - vis_m / 1000.0) / maxf(float(tv[0]) - float(tv[1]), 0.1), 0.0, 1.0
	)
	var c_clear := _color(hz.get("clear_color", [0.56, 0.67, 0.84]))
	var c_turbid := _color(hz.get("turbid_color", [0.66, 0.67, 0.68]))
	_haze_mat.set_shader_parameter("haze_color", c_clear.lerp(c_turbid, grey))
	_haze_mat.set_shader_parameter("sun_color", sun_color)
	_haze_mat.set_shader_parameter("sun_dir", to_sun)
	_haze_mat.set_shader_parameter("sun_scatter", float(hz.get("sun_scatter", 0.3)))
	_haze_mat.set_shader_parameter("sun_scatter_power", float(hz.get("sun_scatter_power", 6.0)))
	_haze_mat.set_shader_parameter("max_opacity", float(hz.get("max_opacity", 0.97)))
	_haze_mat.set_shader_parameter("inscatter_power", float(hz.get("inscatter_power", 1.0)))
	_haze_mat.set_shader_parameter("extinction_rgb", _vec3(hz.get("extinction_rgb", [1, 1, 1])))
	_haze_mat.set_shader_parameter(
		"clear_extinction", 3.912 / (maxf(float(hz.get("clear_visibility_km", 1e6)), 0.1) * 1000.0)
	)
	_haze_mat.set_shader_parameter("clear_rgb", _vec3(hz.get("clear_rgb", [1, 1, 1])))
	_haze_mat.set_shader_parameter(
		"clear_color", _color(hz.get("clear_air_color", [0.66, 0.76, 0.88]))
	)


## Путь в дымке по лучу, приведённый к полной плотности, м — та же аналитика, что в haze.gdshader:
## плотность 1 до top_msl − w/2, линейно до 0 к top_msl + w/2. y0 — высота начала луча (MSL),
## dir_y — вертикальная составляющая единичного направления, length_m — длина луча.
static func haze_path_m(
	y0: float, dir_y: float, length_m: float, top_msl: float, transition_m: float
) -> float:
	var y1 := y0 + dir_y * length_m
	if absf(y1 - y0) > 0.01:
		return (
			length_m
			* (
				(
					_haze_integral(y1, top_msl, transition_m)
					- _haze_integral(y0, top_msl, transition_m)
				)
				/ (y1 - y0)
			)
		)
	return (
		length_m * clampf((top_msl + 0.5 * transition_m - y0) / maxf(transition_m, 1e-3), 0.0, 1.0)
	)


static func _haze_integral(y: float, top_msl: float, w: float) -> float:
	var a := top_msl - 0.5 * w
	var b := top_msl + 0.5 * w
	if y <= a:
		return y
	if y >= b:
		return top_msl
	w = maxf(w, 1e-3)
	return a + (w * w - (b - y) * (b - y)) / (2.0 * w)


## Пропускание воздуха (туман Godot + чистый воздух + мутный слой, зелёный канал) на дальности
## d_m по горизонтали внутри слоя — по configs/world.json. FR-20: на 20 км ≥ 20 %.
static func transmission_in_layer(d_m: float) -> float:
	var cfg: Dictionary = Config.get_config("world")
	var hz: Dictionary = cfg.get("haze", {})
	var k := float(cfg.get("fog", {}).get("density", 0.0))
	if bool(hz.get("enabled", false)):
		k += 3.912 / (maxf(float(hz.get("visibility_km", 30.0)), 0.1) * 1000.0)
		k += 3.912 / (maxf(float(hz.get("clear_visibility_km", 1e6)), 0.1) * 1000.0)
	return exp(-k * d_m)


## Рекомендуемые near/far для камер (configs/world.json → rendering).
static func setup_camera(cam: Camera3D) -> void:
	var rend: Dictionary = Config.get_config("world").get("rendering", {})
	cam.near = float(rend.get("camera_near_m", 0.3))
	cam.far = float(rend.get("camera_far_m", 100000.0))


static func _vec3(a: Variant) -> Vector3:
	var arr: Array = a
	return Vector3(float(arr[0]), float(arr[1]), float(arr[2]))


static func _color(a: Variant) -> Color:
	var arr: Array = a
	return Color(float(arr[0]), float(arr[1]), float(arr[2]))
