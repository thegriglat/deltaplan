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

## Фаза дымки по умолчанию (world.json → haze, см. haze.gdshader).
const HAZE_PHASE_DEFAULTS := {
	"haze_g": 0.7, "forward_gain": 3.0, "forward_knee": 6.0, "back_dim": 0.3, "clear_phase_k": 0.5
}
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
## Густота дымки относительно world.json → haze.visibility_km (ход дня: к вечеру гуще).
var _haze_density: float = 1.0
var _sky_mat: ShaderMaterial
var _env: Environment
## Высота долины места над морем, м (NAN — нет данных: свет рельефа считается на высоте камеры).
var valley_msl_m: float = NAN
var _to_sun := Vector3.UP
var _tint_cam_y := 0.0
var _last_tint: Array[Color] = [Color.WHITE, Color.WHITE]
var _haze_base_color := Color.WHITE
var _clear_air_color := Color.WHITE
## Экспозиция заката (HH4 v3): множитель E к tonemap_exposure — установившееся значение по высоте солнца и
## текущее (сглаживается во времени, tau_s); базовая экспозиция — world.json → rendering.tonemap_exposure.
var exposure_target := 1.0
var exposure_current := 1.0
var _base_exposure := 1.0
var _expo_ready := false
var _disk_dir := Vector3.UP
var _sun_color_now := Color.WHITE
## Яркость солнца к дневной (по Y), сила засвета глаза.
var _glare_lum := 1.0
## Диск, корона и ореол неба — яркость «на кадре» (после экспозиции): в шейдер — делённая на E (_apply_exposure).
var _disk_e := 0.0
var _corona_e := 0.0
var _halo_e := 0.0
## Свет прямого солнца в дымке (ореол рассеяния вперёд) — тоже яркость на кадре, делится на E.
var _haze_sun_lin := Color.WHITE


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
		clock.sun_disk_changed.connect(func() -> void: _apply_sun(clock.to_sun()))
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
		"corona_width",
		deg_to_rad(float(disk.get("corona_width_disks", 3.0)) * float(disk.get("radius_deg", 0.3)))
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
	env.tonemap_mode = (
		Environment.TONE_MAPPER_AGX
		if String(rend.get("tonemap_mode", "filmic")) == "agx"
		else Environment.TONE_MAPPER_FILMIC
	)
	_base_exposure = float(rend.tonemap_exposure)
	_expo_ready = false
	env.tonemap_exposure = _base_exposure
	env.tonemap_white = float(rend.tonemap_white)
	# туман Godot — только если задан (голубая дымка чистого воздуха — в haze.gdshader)
	env.fog_enabled = float(fog_cfg.density) > 0.0
	env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	env.fog_density = float(fog_cfg.density)
	env.fog_light_color = _color(fog_cfg.color)
	env.fog_sun_scatter = fog_sun_scatter()
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
	_to_sun = to_sun
	# цвет — из пропускания атмосферы (HH4 v2): рельеф — на высоте долины, небо/диск/дымка/засвет — камеры
	var el_true := clock.angles().y if clock != null else rad_to_deg(asin(clampf(to_sun.y, -1.0, 1.0)))
	_tint_cam_y = _camera_y()
	var base: Color = _color(sun_cfg.color)
	var light_y := valley_msl_m if not is_nan(valley_msl_m) else _tint_cam_y
	# sun_tint — линейное отношение пропусканий; в слоты sRGB (light_color, source_color) — через линейное
	var base_lin := base.srgb_to_linear()
	var lt_tint := _tint(el_true, light_y, 0)
	var lg := maxf(lt_tint.g, 1.0e-4)
	var lt_rel := Color(lt_tint.r / lg, 1.0, lt_tint.b / lg)  # на G: энергия = T_G-доля, цвет — остальные каналы
	sun.light_color = (base_lin * lt_rel).linear_to_srgb()
	var sun_color: Color = (base_lin * _tint(el_true, _tint_cam_y, 1)).linear_to_srgb()
	if OS.has_environment("DP_SUN_TINT_LOG"):  # кадры tools/shots: ожидаемая цветность диска
		var tc := sun_color.srgb_to_linear() / maxf(base_lin.r, 1.0e-6)
		print("sun_tint: el=%.2f y=%.0f g_r=%.3f b_r=%.3f" % [el_true, _tint_cam_y, tc.g / maxf(tc.r, 1e-6), tc.b / maxf(tc.r, 1e-6)])
	# свет рельефа — из пропускания (HH4 v3): sun.energy × T_G(el, долина) / T_G(35°, долина); цвет — отношения
	# каналов sun_tint, нормированные на G (энергия × цвет = T_c/T_c_ref по каналам); небо — sky_k(el)
	var p := SunTransmission.params()
	var hzx := _haze_extinction()
	var top := get_haze_top_msl()
	var light_k := SunTransmission.light_ratio(el_true, light_y, hzx[0], hzx[1], top, p)
	sun.light_energy = float(sun_cfg.energy) * light_k
	var tint: Color = lt.horizon_tint
	var sky_k := SunTransmission.sky_k(el_true, p)
	_sky_mat.set_shader_parameter("sky_horizon_color", _color(sky_cfg.horizon_color) * tint)
	_sky_mat.set_shader_parameter(
		"ground_horizon_color", _color(sky_cfg.ground_horizon_color) * tint
	)
	_sky_mat.set_shader_parameter("exposure", float(sky_cfg.energy_multiplier) * sky_k)
	# диск, ореол, засвет и дымка к солнцу — по истинной высоте (свет рельефа зажат min_light_elevation_deg)
	var disk_dir := clock.to_sun_true() if clock != null else to_sun
	var lum := sun_luminance_ratio(el_true, _tint_cam_y)
	_sky_mat.set_shader_parameter("sun_dir", disk_dir)
	_sky_mat.set_shader_parameter("sun_color", sun_color)
	var disk: Dictionary = sky_cfg.get("sun_disk", {})
	var lum_p := pow(lum, float(disk.get("energy_exponent", 0.5)))
	# ореол неба вокруг диска — свет прямого солнца со сжатием яркости, как у диска (не освещённость рельефа)
	_halo_e = float(sun_cfg.energy) * lum_p
	# квад дымки рисуется поверх неба и гасит диск по лучу в небо — компенсируем, чтобы после дымки диск был
	# ровно energy × lum^показатель (пропускание дымки уже входит в lum: не учитывать дважды)
	var dk := lum_p / haze_sky_transmission(el_true, _tint_cam_y)
	_disk_e = float(disk.get("energy", 40.0)) * dk
	_corona_e = float(disk.get("corona_energy", 3.0)) * dk
	_env.ambient_light_energy = float(sky_cfg.ambient_light_energy) * sky_k
	# экспозиция заката: E по яркости сцены (SunTransmission.scene_luminance), сглаживается в _process
	var ec: Dictionary = cfg.get("rendering", {}).get("sunset_exposure", {})
	exposure_target = 1.0
	if bool(ec.get("enabled", true)):
		var l := SunTransmission.scene_luminance(
			el_true, light_k, sky_k, float(ec.get("albedo", 0.2)), float(sun_cfg.energy), float(p.ref_el_deg)
		)
		exposure_target = SunTransmission.exposure_factor(
			l, float(ec.get("a", 0.8)), float(ec.get("e_max", 10.0))
		)
	if not _expo_ready:
		exposure_current = exposure_target
		_expo_ready = true
	_disk_dir = disk_dir
	_sun_color_now = sun_color
	_glare_lum = lum
	if OS.has_environment("DP_SUN_TINT_LOG"):  # кадры tools/shots: числа сцены
		print("scene_light: el=%.2f light_energy=%.5f sky_k=%.4f E=%.3f" % [
			el_true, sun.light_energy, sky_k, exposure_target])
	if _haze_mat != null:
		_haze_mat.set_shader_parameter("sun_dir", disk_dir)
		# ореол дымки (рассеяние вперёд) — свет прямого солнца в дымке: яркость ∝ освещённости (lum), не постоянна
		_haze_sun_lin = sun_color.srgb_to_linear() * lum
		_haze_mat.set_shader_parameter("sun_color", _haze_sun_lin.linear_to_srgb())
		_haze_mat.set_shader_parameter("haze_color", _haze_base_color * tint * sky_k)
		# чистый воздух — тот же свет, что небо у горизонта (одна sky_k): утром и вечером в тон неба,
		# иначе у горизонта небо и дальний рельеф расходятся по цвету
		_haze_mat.set_shader_parameter(
			"clear_color", _clear_air_color * tint * sky_k
		)
	_apply_exposure()


## Цветность прямого солнца SunTransmission.sun_tint на высоте y_msl; slot — 0 свет, 1 камера.
## Ниже горизонта точки (T = 0) — цветность на ближайшей высоте выше, где T > 0 (контракт HH4 v2:
## «цвет последней ненулевой цветности»; при заходе это та же, а при старте с солнцем под горизонтом
## нет прошлой — не белая). Нет и такой (глубже −5°) — прошлая цветность слота.
func _tint(el_deg: float, y_msl: float, slot: int) -> Color:
	var haze := _haze_extinction()
	var top := get_haze_top_msl()
	var c := SunTransmission.sun_tint(el_deg, y_msl, haze[0], haze[1], top)
	var e := el_deg
	while c.r < 0.0 and e < 5.0:
		e += 0.1
		c = SunTransmission.sun_tint(e, y_msl, haze[0], haze[1], top)
	if c.r < 0.0:
		return _last_tint[slot]
	_last_tint[slot] = c
	return c


## Ослабление дымки места: [extinction 1/м на 550 нм, спектр Vector3] (нет дымки — нули).
func _haze_extinction() -> Array:
	var ext := 0.0
	var rgb := Vector3.ONE
	if _haze_mat != null:
		var e: Variant = _haze_mat.get_shader_parameter("extinction")
		var r: Variant = _haze_mat.get_shader_parameter("extinction_rgb")
		ext = float(e) if e != null else 0.0
		rgb = r if r is Vector3 else Vector3.ONE
	return [ext, rgb]


## Яркость прямого солнца на высоте el_deg (градусы над горизонтом точки) в точке y_msl относительно
## дневной (при ref_el_deg): пропускание атмосферы по яркости Y (Рэлей + дымка места, сферическая
## Земля, SunTransmission) к пропусканию при ref_el_deg. 0..1; 0 — луч упирается в Землю.
## Днём (выше ref_el_deg) — 1. Множитель яркости диска (степень sky.sun_disk.energy_exponent)
## и силы засвета (sun_glare, ∝ освещённости от солнца).
func sun_luminance_ratio(el_deg: float, y_msl: float) -> float:
	var haze := _haze_extinction()
	var p := SunTransmission.params()
	var top := get_haze_top_msl()
	var t := SunTransmission.transmission(minf(el_deg, float(p.ref_el_deg)), y_msl, haze[0], haze[1], top, p)
	if t.x <= 0.0:
		return 0.0
	var r := SunTransmission.transmission(float(p.ref_el_deg), y_msl, haze[0], haze[1], top, p)
	var w := Vector3(0.2126, 0.7152, 0.0722)
	return clampf(t.dot(w) / maxf(r.dot(w), 1.0e-9), 0.0, 1.0)


## Доля света, проходящая сквозь квад дымки по лучу в небо на высоте el_deg (диск солнца), 0..1: зелёный канал
## (по нему квад гасит сцену), мутный слой + чистый воздух у горизонта, как в haze.gdshader. 1 — дымки нет.
## Зеркало формул haze.gdshader (путь в слое haze_path_m, чистый воздух clear_sky_height_m, max_opacity): менять вместе
## (тест test_haze_sky_transmission_matches_shader_formula).
func haze_sky_transmission(el_deg: float, y_msl: float) -> float:
	var m := _haze_mat
	if m == null or el_deg <= 0.0:
		return 1.0
	var sin_e := sin(deg_to_rad(el_deg))
	var length := float(m.get_shader_parameter("max_distance_m"))
	var rgb: Vector3 = m.get_shader_parameter("extinction_rgb")
	var crgb: Vector3 = m.get_shader_parameter("clear_rgb")
	var path := haze_path_m(
		y_msl, sin_e, length, float(m.get_shader_parameter("top_msl")),
		float(m.get_shader_parameter("top_transition_m"))
	)
	var tau := float(m.get_shader_parameter("extinction")) * rgb.y * maxf(path, 0.0)
	var clear_len := minf(length, float(m.get_shader_parameter("clear_sky_height_m")) / maxf(sin_e, 1.0e-4))
	tau += float(m.get_shader_parameter("clear_extinction")) * crgb.y * clear_len
	var opacity := minf(1.0 - exp(-tau), float(m.get_shader_parameter("max_opacity")))
	return maxf(1.0 - opacity, 1.0e-3)


func _camera_y() -> float:
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam != null:
		return cam.global_position.y
	return 0.0 if is_nan(valley_msl_m) else valley_msl_m


## Экспозиция заката плавно идёт к установившемуся значению (tau_s, реальное время); камера ушла по высоте
## больше чем на tint_update_dy_m — цвет солнца пересчитать.
func _process(dt: float) -> void:
	if sun == null or _env == null or not is_inside_tree():
		return
	if absf(exposure_current - exposure_target) > 1.0e-4 * exposure_target:
		var tau := float(Config.value("world", "rendering.sunset_exposure.tau_s", 3.0))
		var k := 1.0 - exp(-dt / maxf(tau, 1.0e-3))
		exposure_current = exp(lerpf(log(exposure_current), log(exposure_target), k))
		_apply_exposure()
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var dy := float(Config.value("world", "time.light.tint_update_dy_m", 100.0))
	if absf(cam.global_position.y - _tint_cam_y) > dy:
		_apply_sun(_to_sun)


## E сразу к установившемуся значению (тесты, кадры, перемотка времени).
func snap_exposure() -> void:
	exposure_current = exposure_target
	_apply_exposure()


## Множитель E → tonemap_exposure. Диск, корона и ореол неба заданы яркостью на кадре (уже сжаты energy_exponent
## до отображаемого диапазона), поэтому в шейдер идут делённые на E: экспозиция заката их не раздувает.
## Сила засвета глаза (после тонмаппинга, в долях белого кадра) от E не зависит: Хоулдей–Стайлс при экспозиции
## дал бы lum^p·E — ореол вырос бы в 2–3 раза (HH-11: размер ореола утверждён), см. отчёт HH-15.
func _apply_exposure() -> void:
	if _env == null:
		return
	_env.tonemap_exposure = _base_exposure * exposure_current
	var e := maxf(exposure_current, 1.0e-3)
	_sky_mat.set_shader_parameter("disk_energy", _disk_e / e)
	_sky_mat.set_shader_parameter("corona_energy", _corona_e / e)
	_sky_mat.set_shader_parameter("halo_energy", _halo_e / e)
	if _haze_mat != null:
		_haze_mat.set_shader_parameter("sun_color", (_haze_sun_lin / e).linear_to_srgb())
	if glare != null:
		glare.set_sun(_disk_dir, _sun_color_now, _glare_lum)


## Высота инверсии (верх слоя перемешивания), м над уровнем моря. Обычно — основание облаков
## Atmosphere.get_cloudbase_msl(); верх дымки = h + haze.top_margin_m.
func set_inversion_height_msl(h: float) -> void:
	_inversion_msl = h
	if _haze_mat != null:
		_haze_mat.set_shader_parameter("top_msl", get_haze_top_msl())


## Густота дымки (1 — как в конфиге, 2 — видимость вдвое меньше): погода по ходу дня
## по влажности воздуха (WeatherModel.haze_k_rh).
func set_haze_density(k: float) -> void:
	_haze_density = maxf(k, 0.1)
	if _haze_mat != null:
		var hz: Dictionary = Config.get_config("world").get("haze", {})
		var vis_m := maxf(float(hz.get("visibility_km", 30.0)), 0.1) * 1000.0
		_haze_mat.set_shader_parameter("extinction", 3.912 / vis_m * _haze_density)


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


## «Дымка к солнцу» (world.json → fog.sun_scatter, ползунок настроек): одно значение для
## окружения Годо, наземной дымки и облаков (cloud_layer читает его же).
static func fog_sun_scatter() -> float:
	return clampf(float(Config.value("world", "fog.sun_scatter", 0.35)), 0.0, 1.0)


## Применить значение сразу, без пересборки окружения (после Config.reload()).
func apply_fog_sun_scatter() -> void:
	var v := fog_sun_scatter()
	if _env != null:
		_env.fog_sun_scatter = v
	if _haze_mat != null:
		_haze_mat.set_shader_parameter("sun_scatter", v)


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
		# Квад дымки — на своём слое: тени облаков (декали) на него не ложатся. Иначе декаль
		# затемняла дымку во всех плитках кластеров, где она есть, — серые прямоугольники
		# со ступенчатыми краями над дальним рельефом и небом.
		var no_decal := int(Config.value("atmosphere", "clouds.shadow_exclude_layer", 19))
		haze.layers = 1 << (no_decal - 1)
		haze.custom_aabb = AABB(Vector3(-1e6, -1e6, -1e6), Vector3(2e6, 2e6, 2e6))
		_haze_mat = ShaderMaterial.new()
		_haze_mat.shader = HAZE_SHADER
		_haze_mat.render_priority = Material.RENDER_PRIORITY_MAX
		haze.material_override = _haze_mat
		add_child(haze)
	var vis_m := maxf(float(hz.get("visibility_km", 30.0)), 0.1) * 1000.0
	# Формула Кошмидера: видимость = 3.912 / коэффициент ослабления (контраст 2 %).
	_haze_mat.set_shader_parameter("extinction", 3.912 / vis_m * _haze_density)
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
	_haze_mat.set_shader_parameter("sun_scatter", fog_sun_scatter())
	for k in ["haze_g", "forward_gain", "forward_knee", "back_dim", "clear_phase_k"]:
		_haze_mat.set_shader_parameter(k, float(hz.get(k, HAZE_PHASE_DEFAULTS[k])))
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
## Фаза Хеньи–Гринстейна относительно 90° от солнца (mu = cos угла к солнцу); зеркало haze.gdshader.
static func haze_hg_ratio(mu: float, g: float) -> float:
	var g2 := g * g
	return pow(1.0 + g2, 1.5) / pow(1.0 + g2 - 2.0 * g * mu, 1.5)


## Яркость in-scatter мутного слоя на оптической толщине tau (зелёный канал; col_h в шейдере).
## Возвращает [фон дымки, вклад солнца] — второй множитель на sun_color·sun_scatter.
static func haze_phase_terms(mu: float, hz: Dictionary) -> Array:
	var d := HAZE_PHASE_DEFAULTS
	var r := haze_hg_ratio(mu, float(hz.get("haze_g", d.haze_g)))
	var fwd := maxf(r - 1.0, 0.0)
	var halo := fwd / (fwd + float(hz.get("forward_knee", d.forward_knee)))
	var amb := lerpf(1.0, minf(r, 1.0), float(hz.get("back_dim", d.back_dim)))
	return [amb, float(hz.get("forward_gain", d.forward_gain)) * halo]


## Рэлеевский множитель чистого воздуха (1 на 90°).
static func clear_rayleigh(mu: float, hz: Dictionary) -> float:
	return lerpf(1.0, 1.0 + mu * mu, float(hz.get("clear_phase_k", HAZE_PHASE_DEFAULTS.clear_phase_k)))


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
