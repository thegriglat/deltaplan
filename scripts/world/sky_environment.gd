class_name SkyEnvironment
extends Node3D
## Небо, солнце с тенями, дымка до горизонта (FR-20). Все параметры — configs/world.json.
## Создаёт дочерние WorldEnvironment и DirectionalLight3D. Сцена: scenes/world/environment.tscn.

var world_env: WorldEnvironment
var sun: DirectionalLight3D


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
	env.fog_enabled = true
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


## Рекомендуемые near/far для камер (configs/world.json → rendering).
static func setup_camera(cam: Camera3D) -> void:
	var rend: Dictionary = Config.get_config("world").get("rendering", {})
	cam.near = float(rend.get("camera_near_m", 0.3))
	cam.far = float(rend.get("camera_far_m", 100000.0))


static func _color(a: Variant) -> Color:
	var arr: Array = a
	return Color(float(arr[0]), float(arr[1]), float(arr[2]))
