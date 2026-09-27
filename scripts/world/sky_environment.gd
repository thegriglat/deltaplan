class_name SkyEnvironment
extends Node3D
## Небо, солнце с тенями, дымка до горизонта (FR-20) и мутный слой перемешивания под инверсией
## (VR-3, haze.gdshader). Все параметры — configs/world.json.
## Создаёт дочерние WorldEnvironment, DirectionalLight3D и Haze (полноэкранный квад).
## Сцена: scenes/world/environment.tscn.
## Интегратор: set_inversion_height_msl(atmosphere.get_cloudbase_msl()) при смене погоды —
## верх дымки = эта высота + haze.top_margin_m.
## Солнце — по часам clock (SunClock, VR-5): направление, цвет и яркость солнца, неба и дымки
## меняются по сигналу clock.sun_changed. Другие потребители подписываются на тот же сигнал.

const HAZE_SHADER := preload("res://scripts/world/haze.gdshader")
const SKY_SHADER := preload("res://scripts/world/sky.gdshader")

var world_env: WorldEnvironment
var sun: DirectionalLight3D
## Полноэкранный квад дымки (null — дымка выключена в конфиге).
var haze: MeshInstance3D
## Часы и положение солнца — единый источник направления на солнце.
var clock: SunClock
## Ослепление солнцем и каска поверх кадра (world.json → sun_glare, helmet.json);
## null — выключено в конфиге.
var glare: SunGlare

var _haze_mat: ShaderMaterial
var _inversion_msl: float = NAN
var _sky_mat: ShaderMaterial
var _env: Environment
var _haze_base_color := Color.WHITE
var _clear_air_color := Color.WHITE


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

	if clock == null:
		clock = SunClock.new()
		clock.name = "SunClock"
		add_child(clock)
		clock.sun_changed.connect(_apply_sun)
	if sun == null:
		sun = DirectionalLight3D.new()
		sun.name = "Sun"
		add_child(sun)
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = float(sun_cfg.shadow_max_distance_m)
	sun.directional_shadow_split_1 = float(sun_cfg.shadow_split_1)
	sun.directional_shadow_split_2 = float(sun_cfg.shadow_split_2)
	sun.directional_shadow_split_3 = float(sun_cfg.shadow_split_3)
	sun.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_AND_SKY
	sun.light_angular_distance = float(sun_cfg.get("angular_distance_deg", 0.0))
	sun.shadow_blur = float(sun_cfg.get("shadow_blur", 1.0))

	# Градиент — как у ProceduralSkyMaterial; диск солнца и корона — свои (sky.gdshader).
	var sky_mat := ShaderMaterial.new()
	sky_mat.shader = SKY_SHADER
	sky_mat.set_shader_parameter("sky_top_color", _color(sky_cfg.top_color))
	sky_mat.set_shader_parameter("sky_horizon_color", _color(sky_cfg.horizon_color))
	sky_mat.set_shader_parameter("sky_curve", float(sky_cfg.curve))
	sky_mat.set_shader_parameter("ground_horizon_color", _color(sky_cfg.ground_horizon_color))
	sky_mat.set_shader_parameter("ground_bottom_color", _color(sky_cfg.ground_bottom_color))
	sky_mat.set_shader_parameter("sun_angle_max", deg_to_rad(float(sky_cfg.sun_angle_max_deg)))
	sky_mat.set_shader_parameter("sun_curve", float(sky_cfg.sun_curve))
	sky_mat.set_shader_parameter("exposure", float(sky_cfg.energy_multiplier))
	var disk: Dictionary = sky_cfg.get("sun_disk", {})
	sky_mat.set_shader_parameter("disk_radius", deg_to_rad(float(disk.get("radius_deg", 0.3))))
	sky_mat.set_shader_parameter("disk_edge", float(disk.get("edge", 0.3)))
	sky_mat.set_shader_parameter("limb_darkening", float(disk.get("limb_darkening", 0.4)))
	sky_mat.set_shader_parameter(
		"corona_width", deg_to_rad(float(disk.get("corona_width_deg", 1.0)))
	)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	_sky_mat = sky_mat

	var env := Environment.new()
	_env = env
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
	_apply_haze(cfg.get("haze", {}))
	_apply_glare(cfg.get("sun_glare", {}))
	_apply_sun(clock.to_sun())


## Солнце на направлении to_sun (единичный вектор на солнце): поворот света, цвет и яркость
## солнца, неба и дымки по высоте (world.json → time.light: утро и вечер теплее и мягче).
func _apply_sun(to_sun: Vector3) -> void:
	if sun == null or _env == null:
		return
	var cfg: Dictionary = Config.get_config("world")
	var sun_cfg: Dictionary = cfg.get("sun", {})
	var sky_cfg: Dictionary = cfg.get("sky", {})
	var up := Vector3.UP if absf(to_sun.y) < 0.999 else Vector3.FORWARD
	# Свет светит вдоль −Z узла: направляем −Z от солнца к земле.
	sun.basis = Basis.looking_at(-to_sun, up)
	var lt := SunClock.light_at(rad_to_deg(asin(clampf(to_sun.y, -1.0, 1.0))))
	var sun_color: Color = _color(sun_cfg.color) * (lt.sun_color as Color)
	sun.light_color = sun_color
	sun.light_energy = float(sun_cfg.energy) * float(lt.sun_energy)
	var tint: Color = lt.horizon_tint
	var sky_k := float(lt.sky_energy)
	_sky_mat.set_shader_parameter("sky_horizon_color", _color(sky_cfg.horizon_color) * tint)
	_sky_mat.set_shader_parameter(
		"ground_horizon_color", _color(sky_cfg.ground_horizon_color) * tint
	)
	# небо у горизонта на закате светлое — гасим его слабее, чем окружение
	_sky_mat.set_shader_parameter(
		"exposure", float(sky_cfg.energy_multiplier) * lerpf(1.0, sky_k, 0.4)
	)
	_sky_mat.set_shader_parameter("sun_dir", to_sun)
	_sky_mat.set_shader_parameter("sun_color", sun_color)
	_sky_mat.set_shader_parameter("halo_energy", sun.light_energy)
	var disk: Dictionary = sky_cfg.get("sun_disk", {})
	var dk := float(lt.get("disk_energy", 1.0))
	_sky_mat.set_shader_parameter("disk_energy", float(disk.get("energy", 40.0)) * dk)
	_sky_mat.set_shader_parameter("corona_energy", float(disk.get("corona_energy", 3.0)) * dk)
	if glare != null:
		glare.set_sun(to_sun, sun_color, float(lt.get("glare", 1.0)))
	_env.ambient_light_energy = float(sky_cfg.ambient_light_energy) * sky_k
	if _haze_mat != null:
		_haze_mat.set_shader_parameter("sun_dir", to_sun)
		_haze_mat.set_shader_parameter("sun_color", sun_color)
		_haze_mat.set_shader_parameter("haze_color", _haze_base_color * tint * sky_k)
		# чистый воздух — тот же свет, что небо у горизонта: утром и вечером в тон неба,
		# иначе у горизонта небо и дальний рельеф расходятся по цвету
		_haze_mat.set_shader_parameter(
			"clear_color", _clear_air_color * tint * lerpf(1.0, sky_k, 0.4)
		)


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


## Материал неба (sky.gdshader) — для тестов и отладки.
func sky_material() -> ShaderMaterial:
	return _sky_mat


func _apply_glare(gc: Dictionary) -> void:
	if not bool(gc.get("enabled", true)):
		if glare != null:
			glare.queue_free()
			glare = null
		return
	if glare == null:
		glare = SunGlare.new()
		glare.name = "SunGlare"
		add_child(glare)
	glare.apply_config()


func _apply_haze(hz: Dictionary) -> void:
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
	# haze_color, sun_color, sun_dir — в _apply_sun (зависят от высоты солнца)
	_haze_base_color = c_clear.lerp(c_turbid, grey)
	_haze_mat.set_shader_parameter("sun_scatter", float(hz.get("sun_scatter", 0.3)))
	_haze_mat.set_shader_parameter("sun_scatter_power", float(hz.get("sun_scatter_power", 6.0)))
	_haze_mat.set_shader_parameter("max_opacity", float(hz.get("max_opacity", 0.97)))
	_haze_mat.set_shader_parameter("inscatter_power", float(hz.get("inscatter_power", 1.0)))
	_haze_mat.set_shader_parameter("extinction_rgb", _vec3(hz.get("extinction_rgb", [1, 1, 1])))
	_haze_mat.set_shader_parameter(
		"clear_extinction", 3.912 / (maxf(float(hz.get("clear_visibility_km", 1e6)), 0.1) * 1000.0)
	)
	_haze_mat.set_shader_parameter(
		"clear_sky_height_m", float(hz.get("clear_sky_height_m", 1500.0))
	)
	_haze_mat.set_shader_parameter("clear_rgb", _vec3(hz.get("clear_rgb", [1, 1, 1])))
	# clear_color — в _apply_sun (тон по высоте солнца)
	_clear_air_color = _color(hz.get("clear_air_color", [0.66, 0.76, 0.88]))


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
