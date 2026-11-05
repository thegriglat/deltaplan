# gdlint: disable=max-file-lines, class-definitions-order
class_name CloudLayer
extends Node3D
## Облака и их тени на земле (CloudShadowMap). Всё видимое — строго из физической модели (VR-0):
## - кучевые над термиками: рост → зрелость (плотное, чёткие клубы, тёмное плоское основание) →
##   распад (рваное, тает, уплывает); Cb — башня до тропопаузы, наковальня, вирга (VR-26);
## - лентикулярные в гребнях подветренных волн, шапка на гребне хребта, роторные клочья (VR-27).
## Кучевые региона — слой поля облачности (растр atmo.cloud_raster(), текстура CLF-К2, CLF-5):
## в compute-проходе и в карте теней; записи — только линзы, шапка, роторные клочья, Cb.
## Облака над термиками (Cb) — объекты atmo.cloud_objects() (W2 v4, W6 v4): стадия, размеры, центр
## и гроза приходят в записи, здесь только выбор, слияние, видимость и рисование.
## Два способа рисовать (общий код — cloud_common.gdshaderinc):
## - compute (Forward+/Mobile): все облака одним raymarch-проходом в буфере пониженного
##   разрешения с апскейлом (CloudCompositorEffect на активной камере);
## - boxes (Compatibility): одна MultiMesh, бокс на облако, параметры — в float-текстуре.
## Никаких других визуальных признаков термиков (FR-22).

const FLOATS_PER_CLOUD := 24

var atmo: Atmosphere
var cfg: Dictionary
## Конфиг атмосферы (configs/atmosphere.json): рисование читает его само, не через фасад.
var acfg: Dictionary
## Высота рельефа (x, z) -> м MSL (NAN — нет земли): даёт Atmosphere при создании слоя; рельеф
## места — не воздух, слой не ходит в ground сам (W10). Положение наблюдателя — по умолчанию камера.
var ground_fn: Callable = Callable()
var surface_fn: Callable = Callable()
var eye_fn: Callable = Callable()
## Время последнего выбора облаков (CPU), мкс — для замеров.
var last_rebuild_us: int = 0
## > 0 — одиночный выбор облаков порциями по этому бюджету за кадр, мкс (PF-8); 0 — сразу.
var select_budget_us: int = 0
var _sj := false
var _sj_ph := 0
var _sj_i := 0
var _sj_t := 0.0
var _sj_eye := Vector3.ZERO
var _sj_us := 0
var _sj_shown: Dictionary = {}
var _sj_keys: Array = []
var _sj_objs: Dictionary = {}
var _sj_cand: Array = []
var _sj_drop: Dictionary = {}
var _sj_crests: Array = []
## Логика: выбор видимых облаков, слияние, видимость по жизни и дальности (по записям).
var model: CloudModel
## Выбор без памяти о кадрах (только сетевая игра, ставит NetFlight): набор облаков и их
## видимость — функция времени атмосферы, одинаковая у всех клиентов зоны (NET-00). В одиночной
## игре — выбор с гистерезисом и накопленным проявлением/таянием: облако, чей термик ушёл из
## поля, тает, а не пропадает за кадр (в режиме без памяти такие облака исчезали за кадр).
var history_free := false

var _material: ShaderMaterial
var _box: BoxMesh
var _shadow_map: CloudShadowMap
## Слоты облаков над термиками: объект в слоте (null — свободен), id -> слот, свободные слоты.
var _slot_obj: Array = []
var _slot_of: Dictionary = {}
var _free: Array[int] = []
## Записи облаков по слотам (по FLOATS_PER_CLOUD чисел) и облаков волны (неподвижные).
var _rec: Array[PackedFloat32Array] = []
var _wave_rec: Array[PackedFloat32Array] = []
## Распадающиеся облака (слот -> объект) — их снос обновляется каждый кадр.
var _drifting: Dictionary = {}
## Видимость по слотам (облако никогда не выключается за кадр, а тает):
## _sel — доля выбора 0..1. Одиночная игра: идёт к _want за fade_in_s / fade_out_s (_want — 1,
## если облако выбрано, 0 — выбыло). history_free: доля последних _win_n интервалов выбора,
## в которые облако победило при слиянии (CloudModel.merge_winners), × таяние у лимита
## max_clouds — функция времени атмосферы (и камеры — только дальность и лимит): клиент,
## только что вошедший в зону (Atmosphere.start_at), видит то же, что летающий давно.
## _base_vis — видимость по жизни и дальности (CloudModel.life_fade, range_fade).
var _sel: PackedFloat32Array = []
var _want: PackedByteArray = []
## Одиночная игра: первый выбор (старт, смена погоды) — облака сразу видны, без проявления.
var _instant: bool = true
var _last_t: float = -1.0e18
var _base_vis: PackedFloat32Array = []
## Победители слияния по интервалам выбора: k -> {id: true}, k = floor(t / _interval).
var _hist: Dictionary = {}
## Сколько интервалов окна облако побеждало: id -> число (сумма по _hist).
var _cnt: Dictionary = {}
var _last_k: int = -(1 << 62)
var _interval: float = 1.0
var _win_n: int = 60
## Термики живут в этом радиусе вокруг пилота — к нему облако тает.
var _gen_r: float = 20000.0
var _next_slot: int = 0
var _basis_axes: Array = [Vector3.RIGHT, Vector3.UP, Vector3.BACK]

## Compute-путь.
var _effect: CloudCompositorEffect
var _cam_with_effect: Camera3D
## Boxes-путь: MultiMesh и текстура с записями облаков.
var _mm: MultiMesh
var _mmi: MultiMeshInstance3D
var _data_tex: ImageTexture
var _data_rows: int = 0

var _acc: float = 1.0e9
var _light_acc: float = 1.0e9
var _sun: DirectionalLight3D
var _sun_dir: Vector3 = Vector3.UP
var _sun_energy: float = 1.3
## Множитель яркости света окружения облаков по высоте солнца (sky_k сцены; 1 — день), для тестов.
var ambient_sky_k: float = 1.0

## Пропускание атмосферы для света солнца на облаках (HH4, SunTransmission): таблица, ключ сборки
## (extinction дымки, верх дымки, спектр), фоновая пересборка, узел неба (дымка и часы).
var sun_tab_tex: ImageTexture
## Сколько раз таблица собиралась и сколько мс заняла последняя сборка (для проверок и замеров).
var sun_tab_builds: int = 0
var sun_tab_build_ms: float = -1.0
var _tab_key: Array = []
var _tab_params: Dictionary = {}
var _tab_task: int = -1
var _tab_result: Array = []
var _tab_pending_key: Array = []
var _sky: SkyEnvironment
var _sky_retry: int = 0

## Слой поля облачности (CLF-5): параметры шейдеров cf_* (CLF-К2 + грубая карта), текстуры поля
## (новый и прошлый шаг — переход за step_s), грубая карта блоков (RG8: наибольшие покрытие и
## мощность блока с соседними клетками). cf_on = 0 — слой пуст, шейдеры его не проходят.
var field_params: Dictionary = {"cf_on": 0.0}
var field_tex: ImageTexture
var field_tex_prev: ImageTexture
var field_max_tex: ImageTexture
## Сколько раз текстура поля обновлялась (для проверок: только при смене данных поля).
var field_uploads: int = 0
var _cf_key: String = ""
var _cf_t_upd: float = 0.0
var _cf_step: float = 20.0
var _cf_img: Image
var _cf_prev_img: Image
## Срезы шума noise_shape для CPU-выборки (visible_density_at); null до готовности текстуры.
var _nz_slices: Array[Image] = []
var _cf_quant := PackedFloat32Array()
## Квантили маски по текстуре шума (путь → 16 значений) — считаются раз на процесс.
static var _quant_cache: Dictionary = {}
## Доля объёма маски выше последнего квантиля (верх шкалы превышения порога, cf_excess).
const MASK_TOP_TAIL := 1.0e-5


## Высота земли (x, z) м MSL или NAN, если места нет.
func ground_msl(x: float, z: float) -> float:
	return float(ground_fn.call(x, z)) if ground_fn.is_valid() else NAN


## Единичное направление фонового ветра на высоте облаков (x, 0, z); штиль — вдоль +X.
func _wind_dir() -> Vector3:
	var bw := atmo.background_wind(PackedFloat32Array([atmo.cloudbase_msl()]))
	var v := Vector2(bw[0], bw[1])
	return Vector3(v.x, 0.0, v.y).normalized() if v.length_squared() > 1.0e-6 else Vector3(1, 0, 0)


## atmo_cfg — конфиг атмосферы для рисования (пусто — configs/atmosphere.json).
func setup(atmosphere: Atmosphere, atmo_cfg: Dictionary = {}) -> void:
	atmo = atmosphere
	acfg = atmo_cfg if not atmo_cfg.is_empty() else Config.get_config("atmosphere")
	cfg = acfg.clouds
	model = CloudModel.new()
	model.setup(cfg)
	_gen_r = float(acfg.thermal.generation_radius_m)
	_interval = maxf(float(cfg.update_interval_s), 0.05)
	_win_n = maxi(1, roundi(float(cfg.get("fade_out_s", 60.0)) / _interval))
	atmo.weather_changed.connect(_on_weather_changed)
	_material = ShaderMaterial.new()
	_material.shader = load("res://scripts/atmosphere/cloud_volume.gdshader")
	var seed_value := int(acfg.seed)
	_material.set_shader_parameter(
		"noise_shape",
		_noise_texture(
			String(cfg.noise_shape_texture),
			int(cfg.noise_shape_size),
			int(cfg.noise_shape_cells),
			3,
			seed_value
		)
	)
	_material.set_shader_parameter(
		"noise_detail",
		_noise_texture(
			String(cfg.noise_detail_texture),
			int(cfg.noise_detail_size),
			int(cfg.noise_detail_cells),
			2,
			seed_value + 17
		)
	)
	var params := {
		"shape_period_m": "shape_period_m",
		"detail_period_m": "detail_period_m",
		"top_period_m": "top_period_m",
		"extinction": "extinction_per_m",
		"light_absorb": "light_absorb",
		"powder_strength": "powder_strength",
		"phase_forward": "phase_forward",
		"phase_back": "phase_back",
		"phase_mix": "phase_mix",
		"silver": "silver",
		"ms_strength": "multi_scatter",
		"light_step_m": "light_step_m",
		"hf_period_m": "hf_period_m",
		"curl_strength_m": "curl_strength_m",
		"base_darkness": "base_darkness",
		"base_relief_m": "base_relief_m",
		"sky_occlusion_m": "sky_occlusion_m",
		"surface_sharpness": "surface_sharpness",
		"light_step_growth": "light_step_growth",
		"lod_distance_m": "lod_distance_m",
		"ambient_energy": "ambient_energy",
	}
	for u in params:
		_material.set_shader_parameter(u, float(cfg[params[u]]))
	var st: Dictionary = acfg.storm
	for u in ["anvil_spread", "anvil_shift", "virga_depth_m", "virga_density", "virga_period_m"]:
		_material.set_shader_parameter(u, float(st[u]))
	_material.set_shader_parameter("shape_tex_size", float(cfg.noise_shape_size))
	_material.set_shader_parameter("detail_tex_size", float(cfg.noise_detail_size))
	_material.set_shader_parameter("ambient_top", _color(cfg.ambient_top))
	_material.set_shader_parameter("ambient_bottom", _color(cfg.ambient_bottom))
	sun_tab_tex = ImageTexture.create_from_image(Image.create(1, 1, false, Image.FORMAT_RGBF))
	_material.set_shader_parameter("sun_tab", sun_tab_tex)
	_box = BoxMesh.new()
	_box.size = Vector3.ONE
	var renderer := String(cfg.renderer)
	if renderer != "boxes" and RenderingServer.get_rendering_device() != null:
		_effect = CloudCompositorEffect.new()
		_effect.noise_shape = _material.get_shader_parameter("noise_shape")
		_effect.noise_detail = _material.get_shader_parameter("noise_detail")
	else:
		_make_multimesh()
	if bool(cfg.shadows) and GraphicsPresets.gpu_effect("cloud_shadows"):
		_shadow_map = CloudShadowMap.new()
		_shadow_map.name = "ShadowMap"
		add_child(_shadow_map)
		_shadow_map.setup(self, _material)
	set_quality(String(cfg.quality))
	_update_light()


## Качество: "low" | "medium" | "high" (configs/atmosphere.json → clouds.quality_presets).
func set_quality(q: String) -> void:
	var presets: Dictionary = cfg.quality_presets
	var p: Dictionary = presets.get(q, presets.medium)
	for u in ["coarse_steps", "max_iterations", "light_steps"]:
		_material.set_shader_parameter(u, int(p[u]))
	for u in ["fine_step_per_m", "fine_step_min_m"]:
		_material.set_shader_parameter(u, float(p[u]))
	_material.set_shader_parameter("detail_enabled", 1 if bool(p.detail) else 0)
	if _effect != null:
		_effect.resolution_scale = float(p.lowres_scale)
		_effect.max_buffer_px = int(p.get("max_buffer_px", 0))
	if _shadow_map != null:
		_shadow_map.set_quality(q)


## Текстуры шума генерируются в фоне; до готовности облака гладкие.
func textures_ready() -> bool:
	for u in ["noise_shape", "noise_detail"]:
		var t: Texture3D = _material.get_shader_parameter(u)
		if t == null or (t is NoiseTexture3D and t.get_data().is_empty()):
			return false
	return true


## Записи всех облаков, которые сейчас рисуются (для тестов и отладки).
func records() -> Array[PackedFloat32Array]:
	var out: Array[PackedFloat32Array] = []
	for i in _rec.size():
		if _slot_obj[i] != null and not _rec[i].is_empty():
			out.append(_rec[i])
	out.append_array(_wave_rec)
	return out


static func _color(a: Array) -> Color:
	return Color(float(a[0]), float(a[1]), float(a[2]))


## Текстура шума из файла (путь в конфиге, Texture3D, канал R) или процедурная.
func _noise_texture(
	path: String, size: int, cells: int, octaves: int, seed_value: int
) -> Texture3D:
	if path != "":
		if ResourceLoader.exists(path):
			var tex := load(path) as Texture3D
			if tex != null:
				return tex
		push_warning("CloudLayer: текстура шума '%s' не найдена — генерирую процедурно" % path)
	return _make_noise(size, cells, octaves, seed_value)


## Бесшовная 3D-текстура шума Уорли (фрактальная) — из неё клубы и рваные края.
func _make_noise(size: int, cells: int, octaves: int, seed_value: int) -> NoiseTexture3D:
	var n := FastNoiseLite.new()
	n.seed = seed_value
	n.noise_type = FastNoiseLite.TYPE_CELLULAR
	n.cellular_distance_function = FastNoiseLite.DISTANCE_EUCLIDEAN
	n.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
	n.cellular_jitter = 1.0
	n.fractal_type = FastNoiseLite.FRACTAL_FBM
	n.fractal_octaves = octaves
	n.fractal_gain = 0.45
	n.frequency = float(cells) / size
	var t := NoiseTexture3D.new()
	t.width = size
	t.height = size
	t.depth = size
	t.seamless = true
	t.normalize = true
	t.noise = n
	return t


func _make_multimesh() -> void:
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.mesh = _box
	_mmi = MultiMeshInstance3D.new()
	_mmi.multimesh = _mm
	_mmi.material_override = _material
	_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_mmi.custom_aabb = AABB(Vector3(-1.0e6, -1.0e4, -1.0e6), Vector3(2.0e6, 1.0e5, 2.0e6))
	add_child(_mmi)


func _on_weather_changed() -> void:
	_acc = 1.0e9
	_cf_key = ""
	_instant = true
	_hist.clear()
	_cnt.clear()


func _process(delta: float) -> void:
	if atmo == null:
		return
	var t := float(atmo.status().time_s)
	var dt := clampf(t - _last_t, 0.0, 1.0e6) if _last_t > -1.0e17 else 0.0
	_last_t = t
	# Шум облаков «течёт» с ветром на кромке: форма стоит над термиком, клубы плывут.
	var bw := atmo.background_wind(PackedFloat32Array([atmo.cloudbase_msl()]))
	var w := Vector2(bw[0], bw[1]) * float(cfg.noise_wind_factor)
	_material.set_shader_parameter("wind_offset", -Vector3(w.x, 0.0, w.y) * t)
	_material.set_shader_parameter("boil", t * float(cfg.boil_speed))
	_light_acc += delta
	if _light_acc > 1.0:
		_light_acc = 0.0
		_update_light()
	var cam := get_viewport().get_camera_3d()
	var eye := _eye_pos()
	if _effect != null:
		_attach_effect(cam)
	_update_field(t)
	_acc += delta
	# Выбор — на каждом интервале времени атмосферы (и при движении камеры на паузе).
	if _sj:
		_select_pump()
	elif (history_free and floori(t / _interval) != _last_k) or _acc >= _interval:
		_acc = 0.0
		if select_budget_us > 0 and not history_free and not _instant:
			_select_begin(t, eye)
			_select_pump()
		else:
			_select(t, eye)
	_update_some(t, eye)
	if not history_free:
		_update_fades(dt)
	_update_drift(t)
	if _shadow_map != null:
		_shadow_map.update(eye, _sun_dir, _material)
	var visible_recs := _visible_records(cam)
	if _effect != null:
		_push_to_effect(visible_recs)
	else:
		_push_to_multimesh(visible_recs, eye)


## Эффект вешается на активную камеру (к её Compositor, не трогая чужие эффекты).
func _attach_effect(cam: Camera3D) -> void:
	if cam == _cam_with_effect:
		return
	if _cam_with_effect != null and is_instance_valid(_cam_with_effect):
		var old := _cam_with_effect.compositor
		if old != null:
			var effs := old.compositor_effects.duplicate()
			effs.erase(_effect)
			old.compositor_effects = effs
	_cam_with_effect = cam
	if cam == null:
		return
	if cam.compositor == null:
		cam.compositor = Compositor.new()
	var list := cam.compositor.compositor_effects.duplicate()
	if not list.has(_effect):
		list.append(_effect)
		cam.compositor.compositor_effects = list


## Облака в пирамиде видимости камеры.
func _visible_records(cam: Camera3D) -> Array[PackedFloat32Array]:
	var planes: Array[Plane] = []
	if cam != null:
		planes = cam.get_frustum()
	var out: Array[PackedFloat32Array] = []
	for g in records():
		if g[20] <= 0.001:
			continue  # растаяло (слот освободится) — лучи на него не тратим
		var c := Vector3(g[0], g[1], g[2])
		var r := Vector3(g[6], g[3], g[7]).length()
		var inside := true
		for pl in planes:
			if pl.distance_to(c) > r:
				inside = false
				break
		if inside:
			out.append(g)
	return out


## Параметры материала и видимые облака — в compute-эффект.
func _push_to_effect(recs: Array[PackedFloat32Array]) -> void:
	var names := CloudCompositorEffect.FLOAT_PARAMS + CloudCompositorEffect.INT_PARAMS
	for pair in CloudCompositorEffect.VEC_PARAMS:
		names = names + pair
	for n: String in names:
		var v: Variant = _material.get_shader_parameter(n)
		if v is Color:
			v = Vector3(v.r, v.g, v.b)
		if v != null:
			_effect.params[n] = v
	var data := PackedFloat32Array()
	for g in recs:
		data.append_array(g)
	_effect.clouds_data = data
	_effect.cloud_count = recs.size()
	for k: String in field_params:
		_effect.params[k] = field_params[k]
	_effect.field_tex = field_tex
	_effect.field_tex_prev = field_tex_prev
	_effect.field_max_tex = field_max_tex
	_effect.sun_tab = sun_tab_tex


## Compatibility: боксы от дальних к ближним (порядок смешивания), записи — в float-текстуру.
func _push_to_multimesh(recs: Array[PackedFloat32Array], eye: Vector3) -> void:
	var sorted := recs.duplicate()
	sorted.sort_custom(
		func(a: PackedFloat32Array, b: PackedFloat32Array) -> bool:
			return (
				eye.distance_squared_to(Vector3(a[0], a[1], a[2]))
				> eye.distance_squared_to(Vector3(b[0], b[1], b[2]))
			)
	)
	var n := sorted.size()
	var rows := maxi(64, nearest_po2(maxi(n, 1)))
	if _mm.instance_count < rows:
		_mm.instance_count = rows
	_mm.visible_instance_count = n
	var data := PackedFloat32Array()
	data.resize(rows * FLOATS_PER_CLOUD)
	for i in n:
		var g: PackedFloat32Array = sorted[i]
		for k in FLOATS_PER_CLOUD:
			data[i * FLOATS_PER_CLOUD + k] = g[k]
		var ax := Vector3(g[4], 0.0, g[5])
		var b := Basis(ax * g[6] * 2.0, Vector3.UP * g[3] * 2.0, ax.cross(Vector3.UP) * g[7] * 2.0)
		_mm.set_instance_transform(i, Transform3D(b, Vector3(g[0], g[1], g[2])))
	var img := Image.create_from_data(6, rows, false, Image.FORMAT_RGBAF, data.to_byte_array())
	if _data_tex == null or _data_rows != rows:
		_data_tex = ImageTexture.create_from_image(img)
		_data_rows = rows
		_material.set_shader_parameter("cloud_data", _data_tex)
	else:
		_data_tex.update(img)


func _exit_tree() -> void:
	if _tab_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_tab_task)
		_tab_task = -1
	if _effect != null:
		_attach_effect(null)


## Солнце и дымка — из сцены (DirectionalLight3D, WorldEnvironment), иначе из конфига.
## Перистая пелена ослабляет прямой свет на облаках.
func _update_light() -> void:
	if _sun == null or not is_instance_valid(_sun):
		_sun = _find_light(get_tree().root) if is_inside_tree() else null
	var color := Color(1, 0.97, 0.92)
	_sun_energy = 1.3
	if _sun != null:
		_sun_dir = _sun.global_transform.basis.z.normalized()
		# Цвета узлов и окружения — sRGB; в шейдере всё линейное (как у движка).
		color = _sun.light_color.srgb_to_linear()
		_sun_energy = _sun.light_energy
	else:
		var el := deg_to_rad(float(cfg.sun_elevation_deg))
		var az := deg_to_rad(float(cfg.sun_azimuth_deg))
		_sun_dir = Vector3(sin(az) * cos(el), sin(el), -cos(az) * cos(el))
	_material.set_shader_parameter("sun_dir", _sun_dir)
	# Свет окружения (рассеянный свет неба и дымка) следует закату: яркость — sky_k сцены
	# (SunTransmission.sky_k, одна с рельефом, небом и дымкой SkyEnvironment, HH4 v3);
	# цвет низа окружения и дымки — × horizon_tint,
	# верх окружения (ambient_top, зенит) не подкрашивается — на закате зенит синий.
	var tint := Color.WHITE
	var sky_k := 1.0
	var sky := _find_sky()
	if bool(cfg.get("ambient_follows_sunset", true)) and sky != null and sky.clock != null:
		var el_s: float = sky.clock.angles().y
		tint = SunClock.light_at(el_s).horizon_tint as Color
		sky_k = SunTransmission.sky_k(el_s, _tab_params)
	var toa := Vector3(color.r, color.g, color.b)
	var energy := _sun_energy * atmo.get_insolation()
	var tab := _update_sun_transmission()
	if not tab.is_empty():
		toa = tab.toa
		energy = tab.energy_k * atmo.get_insolation()
	_material.set_shader_parameter("sun_color", toa)
	_material.set_shader_parameter("sun_energy", energy)
	var at := _color(cfg.ambient_top)
	var ab := _color(cfg.ambient_bottom) * tint
	_material.set_shader_parameter("ambient_top", at)
	_material.set_shader_parameter("ambient_bottom", ab)
	_material.set_shader_parameter("ambient_energy", float(cfg.ambient_energy) * sky_k)
	ambient_sky_k = sky_k
	var env: Environment = (
		get_world_3d().environment if is_inside_tree() and get_world_3d() != null else null
	)
	var fc_k := Vector3(tint.r, tint.g, tint.b) * sky_k
	if env != null and env.fog_enabled:
		var fc := env.fog_light_color.srgb_to_linear() * env.fog_light_energy
		_material.set_shader_parameter("fog_color", Vector3(fc.r, fc.g, fc.b) * fc_k)
		_material.set_shader_parameter("fog_density", env.fog_density)
	else:
		var fc2 := _color(cfg.fog_color_fallback).srgb_to_linear()
		_material.set_shader_parameter("fog_color", Vector3(fc2.r, fc2.g, fc2.b) * fc_k)
		_material.set_shader_parameter("fog_density", float(cfg.fog_density_fallback))
	# «Дымка к солнцу» — то же значение, что у наземной дымки и окружения (SkyEnvironment)
	_material.set_shader_parameter("fog_sun_scatter", SkyEnvironment.fog_sun_scatter())


## Свет облаков по пропусканию атмосферы (HH4): обновляет таблицу, T_ref, настоящее направление на
## солнце и параметры шейдеров; возвращает {toa: Vector3, energy_k: float} — солнце на опорной
## высоте
## (в линейном RGB, с поправкой за краем таблицы) и его яркость без перистой пелены, либо {} —
## свет прежний (нет дымки/часов или выключено в конфиге).
func _update_sun_transmission() -> Dictionary:
	var tc: Dictionary = cfg.get("sun_transmission", {})
	var sky := _find_sky()
	var haze: ShaderMaterial = sky.haze_material() if sky != null else null
	if not bool(tc.get("enabled", true)) or sky == null or haze == null or sky.clock == null:
		_material.set_shader_parameter("sun_tab_on", 0.0)
		return {}
	var p := _tab_params
	if p.is_empty():
		p = SunTransmission.params(tc)
		_tab_params = p
	var ext_v: Variant = haze.get_shader_parameter("extinction")
	var rgb_v: Variant = haze.get_shader_parameter("extinction_rgb")
	var ext := float(ext_v) if ext_v != null else 0.0
	var rgb: Vector3 = rgb_v if rgb_v is Vector3 else Vector3.ONE
	var top := sky.get_haze_top_msl()
	_update_sun_tab(ext, rgb, top, float(tc.get("rebuild_change", 0.05)))
	if _tab_key.is_empty():
		_material.set_shader_parameter("sun_tab_on", 0.0)
		return {}
	# Нормировка — по параметрам, с которыми собрана таблица (не по текущим: пересборка в фоне).
	var k_ext: float = _tab_key[0]
	var k_rgb: Vector3 = _tab_key[1]
	var k_top: float = _tab_key[2]
	var valley := float(atmo.weather().get("_derived", {}).get("valley_msl_m", 0.0))
	var el_true: float = sky.clock.angles().y
	var t_ref := SunTransmission.transmission(p.ref_el_deg, valley, k_ext, k_rgb, k_top, p)
	var f := SunTransmission.sun_factor(el_true, k_ext, k_rgb, k_top, valley, p)
	var world: Dictionary = Config.get_config("world").get("sun", {})
	var base_c := _color(world.get("color", [1.0, 1.0, 1.0]))
	base_c = base_c.srgb_to_linear()
	var toa := Vector3(base_c.r * f.x, base_c.g * f.y, base_c.b * f.z)
	var energy_k := float(world.get("energy", 1.2))
	# Настоящее направление: азимут — от света сцены, высота — по часам (не зажатая).
	var hz := Vector2(_sun_dir.x, _sun_dir.z)
	hz = hz.normalized() if hz.length() > 1.0e-4 else Vector2(0.0, -1.0)
	var el := deg_to_rad(el_true)
	_material.set_shader_parameter(
		"sun_dir_t", Vector3(hz.x * cos(el), sin(el), hz.y * cos(el))
	)
	var n_el: int = p.n_el
	var n_h: int = p.n_h
	var u := clampf((el_true - p.el_min_deg) / (p.el_max_deg - p.el_min_deg), 0.0, 1.0)
	_material.set_shader_parameter("sun_tab_u", (u * (n_el - 1) + 0.5) / n_el)
	_material.set_shader_parameter("sun_tab_vs", float(n_h - 1) / float(n_h) / float(p.h_max_m))
	_material.set_shader_parameter("sun_tab_vo", 0.5 / n_h)
	_material.set_shader_parameter("sun_tref", t_ref)
	_material.set_shader_parameter("sun_tab", sun_tab_tex)
	_material.set_shader_parameter("sun_tab_on", 1.0 if t_ref.y > 0.0 else 0.0)
	return {"toa": toa, "energy_k": energy_k}


## Таблица пропускания: первая сборка — сразу (при старте), пересборка при смене extinction дымки
## или её верха больше чем на `change` — в фоновом потоке (WorkerThreadPool), результат — позже.
func _update_sun_tab(ext: float, rgb: Vector3, top: float, change: float) -> void:
	if _tab_task >= 0 and WorkerThreadPool.is_task_completed(_tab_task):
		WorkerThreadPool.wait_for_task_completion(_tab_task)
		_tab_task = -1
		if not _tab_result.is_empty():
			sun_tab_tex.set_image(_tab_result[0])
			_tab_key = _tab_pending_key
			_tab_result = []
			sun_tab_builds += 1
	var drift := _tab_key.is_empty()
	if not drift:
		var k_ext: float = _tab_key[0]
		var k_top: float = _tab_key[2]
		drift = (
			absf(ext - k_ext) > change * maxf(k_ext, 1.0e-6)
			or absf(top - k_top) > change * maxf(k_top, 100.0)
		)
	if not drift or _tab_task >= 0:
		return
	var key := [ext, rgb, top]
	if _tab_key.is_empty():
		var t0 := Time.get_ticks_usec()
		var img := SunTransmission.build(ext, rgb, top, _tab_params)
		sun_tab_build_ms = (Time.get_ticks_usec() - t0) / 1000.0
		sun_tab_tex = ImageTexture.create_from_image(img)
		_material.set_shader_parameter("sun_tab", sun_tab_tex)
		_tab_key = key
		sun_tab_builds += 1
		return
	_tab_pending_key = key
	var prm := _tab_params
	_tab_task = WorkerThreadPool.add_task(
		func() -> void:
			var t0 := Time.get_ticks_usec()
			_tab_result = [SunTransmission.build(ext, rgb, top, prm)]
			sun_tab_build_ms = (Time.get_ticks_usec() - t0) / 1000.0
	)


func _find_sky() -> SkyEnvironment:
	if _sky != null and is_instance_valid(_sky):
		return _sky
	_sky = null
	if not is_inside_tree():
		return null
	if _sky_retry > 0:
		_sky_retry -= 1
		return null
	_sky = _find_sky_in(get_tree().root)
	if _sky == null:
		_sky_retry = 5
	return _sky


func _find_sky_in(n: Node) -> SkyEnvironment:
	if n is SkyEnvironment:
		return n
	for c in n.get_children():
		var r := _find_sky_in(c)
		if r != null:
			return r
	return null


func _find_light(n: Node) -> DirectionalLight3D:
	if n is DirectionalLight3D and (n as DirectionalLight3D).visible:
		return n
	for c in n.get_children():
		var r := _find_light(c)
		if r != null:
			return r
	return null


## Выбрать видимые облака над термиками и пересобрать неподвижные облака волны.
## Видимость выбора — доля последних _win_n интервалов, в которые облако побеждало при
## слиянии (плавно проявляется и тает, без памяти о кадрах); у лимита max_clouds дальние
## тают к дальности первого не вошедшего. Облако с нулевой видимостью освобождает слот.
func _select(t: float, eye: Vector3) -> void:
	var t0 := Time.get_ticks_usec()
	var wd := _wind_dir()
	_basis_axes = [wd, Vector3.UP, wd.cross(Vector3.UP)]
	if not history_free:
		_select_with_fades(t, eye)
		_wave_rec = _wave_clouds(eye)
		last_rebuild_us = Time.get_ticks_usec() - t0
		return
	_sync_history(floori(t / _interval))
	var cnt := _cnt
	var ths := _objs(t)
	var e2 := Vector2(eye.x, eye.z)
	var cand: Array = []
	for id in cnt:
		var ob: CloudModel.Obj = ths.get(id)
		if ob == null or not ob.alive(t):
			continue
		var c := ob.center_at(t)
		var d := e2.distance_to(c)
		if d > model.far_m(ob):
			continue
		var f := float(cnt[id]) / float(_win_n)
		cand.append([d, id, f, f * model.life_fade(ob, t) * _range_vis(ob, t, c, eye)])
	var want: Dictionary = {}
	var d_cap := _cap_distance(cand, float(cfg.max_clouds))
	var band := float(cfg.get("fade_band_m", 3000.0))
	for e: Array in cand:
		want[e[1]] = float(e[2]) * (1.0 - smoothstep(d_cap - band, d_cap, float(e[0])))
	for id in _slot_of.keys():
		if float(want.get(id, 0.0)) <= 0.0:
			_release(_slot_of[id])
	for id in want:
		var v := float(want[id])
		if v <= 0.0:
			continue
		if _slot_of.has(id):
			var s: int = _slot_of[id]
			_slot_obj[s] = ths[id]
			_sel[s] = v
			if not _rec[s].is_empty():
				_rec[s][20] = _base_vis[s] * v
			continue
		var slot: int = _free.pop_back() if not _free.is_empty() else _add_slot()
		_slot_obj[slot] = ths[id]
		_slot_of[id] = slot
		_sel[slot] = v
		_place(slot, t, eye)
	_wave_rec = _wave_clouds(eye)
	last_rebuild_us = Time.get_ticks_usec() - t0


## Одиночная игра: нарисованные (не тающие) облака в приоритете при наложении и обрезке по
## лимиту (гистерезис); выбывшее тает (_update_fades), слот освобождается при нуле.
func _select_with_fades(t: float, eye: Vector3) -> void:
	_apply_selection(model.select(_objs(t), t, eye, _shown_ids()), t, eye)


## Объекты-облака на момент t (W2 v4): {id: CloudModel.Obj}; весь набор, без ограничения по радиусу.
func _objs(t: float) -> Dictionary:
	return CloudModel.parse(atmo.cloud_objects(Vector3.ZERO, -1.0, t), t)


## Уже нарисованные (не тающие) облака: id -> true.
func _shown_ids() -> Dictionary:
	var shown: Dictionary = {}
	for id in _slot_of:
		if _want[_slot_of[id]] == 1:
			shown[id] = true
	return shown


## Выбор порциями (PF-8): тот же результат, что _select для одиночной игры, но набор кандидатов,
## слияние и волновые облака — по шагам за кадр (_select_pump); t, камера и «нарисованные» —
## на начало.
func _select_begin(t: float, eye: Vector3) -> void:
	var wd := _wind_dir()
	_basis_axes = [wd, Vector3.UP, wd.cross(Vector3.UP)]
	_sj = true
	_sj_ph = 0
	_sj_i = 0
	_sj_t = t
	_sj_eye = eye
	_sj_us = 0
	_sj_shown = _shown_ids()
	_sj_objs = _objs(t)
	_sj_keys = _sj_objs.keys()
	_sj_cand = []


func _select_pump() -> void:
	var t0 := Time.get_ticks_usec()
	var dl := t0 + select_budget_us
	if _sj_ph == 0:
		var n := _sj_keys.size()
		while _sj_i < n:
			var ob: CloudModel.Obj = _sj_objs.get(_sj_keys[_sj_i])
			_sj_i += 1
			if ob != null:
				var e := model.select_entry(ob, _sj_t, _sj_eye, _sj_shown)
				if not e.is_empty():
					_sj_cand.append(e)
			if (_sj_i & 7) == 0 and Time.get_ticks_usec() >= dl:
				_sj_us += Time.get_ticks_usec() - t0
				return
		_sj_ph = 1
	if _sj_ph == 1:
		if Time.get_ticks_usec() >= dl:
			_sj_us += Time.get_ticks_usec() - t0
			return
		_sj_drop = model.drop_begin(CloudModel.sort_by_score(_sj_cand))
		_sj_cand = []
		_sj_ph = 2
	if _sj_ph == 2:
		if not model.drop_step(_sj_drop, dl):
			_sj_us += Time.get_ticks_usec() - t0
			return
		_sj_ph = 3
	if _sj_ph == 3:
		if Time.get_ticks_usec() >= dl:
			_sj_us += Time.get_ticks_usec() - t0
			return
		_apply_selection(model.select_tail(_sj_drop.out, _sj_shown), _sj_t, _sj_eye)
		_sj_drop = {}
		_sj_ph = 4
		_sj_us += Time.get_ticks_usec() - t0
		return
	if _sj_ph == 4:
		_sj_crests = _wave_crests(_sj_eye) if _wave_enabled() else []
		_sj_ph = 5
		_sj_us += Time.get_ticks_usec() - t0
		return
	_wave_rec = _wave_clouds(_sj_eye, _sj_crests)
	_sj_crests = []
	_sj_objs = {}
	_sj = false
	last_rebuild_us = _sj_us + Time.get_ticks_usec() - t0


## Применить выбор (одиночная игра): слоты под выбранные облака, выбывшие тают.
func _apply_selection(list: Array, t: float, eye: Vector3) -> void:
	var keep: Dictionary = {}
	for e: Array in list:
		keep[(e[1] as CloudModel.Obj).id] = e[1]
	for id in _slot_of.keys():
		if not keep.has(id):
			if _instant:
				_release(_slot_of[id])
			else:
				_want[_slot_of[id]] = 0
	for id in keep:
		if _slot_of.has(id):
			var cur: int = _slot_of[id]
			_want[cur] = 1
			_slot_obj[cur] = keep[id]
			continue
		var slot: int = _free.pop_back() if not _free.is_empty() else _add_slot()
		_slot_obj[slot] = keep[id]
		_slot_of[id] = slot
		_want[slot] = 1
		_sel[slot] = 1.0 if _instant else 0.0
		_place(slot, t, eye)
	_instant = false


## Одиночная игра: выбранные облака проявляются, выбывшие тают (время атмосферы); растаявшее
## освобождает слот.
func _update_fades(dt: float) -> void:
	for i in _slot_obj.size():
		if _slot_obj[i] == null:
			continue
		var target := float(_want[i])
		if _sel[i] == target:
			continue
		_sel[i] = model.step_fade(_sel[i], target, dt)
		if _sel[i] <= 0.0 and target <= 0.0:
			_release(i)
			continue
		if not _rec[i].is_empty():
			_rec[i][20] = _base_vis[i] * _sel[i]


## Лимит max_clouds — дальностью: до неё набирается cap облаков по их видимости (с долями),
## дальше облака тают в полосе fade_band_m. Дальность непрерывна по видимостям и расстояниям
## (внутри промежутка между соседними облаками — интерполяция), поэтому облако у лимита не
## мигает и не зависит от того, что рисовалось раньше. Без обрезки — за последним облаком.
static func _cap_distance(cand: Array, cap: float) -> float:
	cand.sort_custom(
		func(a: Array, b: Array) -> bool:
			return a[0] < b[0] if a[0] != b[0] else int(a[1]) < int(b[1])
	)
	var cum := 0.0
	var prev_d := 0.0
	for e: Array in cand:
		var w := float(e[3])
		var d := float(e[0])
		if w > 0.0 and cum + w >= cap:
			return prev_d + (d - prev_d) * (cap - cum) / w
		cum += w
		prev_d = d
	return prev_d + (cap - cum) * 1.0e4


## Победители слияния за последние _win_n интервалов до k (недостающие — досчитать:
## при старте, смене погоды или скачке времени — сразу все, как у давно летящего).
func _sync_history(k: int) -> void:
	if k < _last_k or k - _last_k >= _win_n:
		_hist.clear()
		_cnt.clear()
	for kk in _hist.keys():
		if kk <= k - _win_n or kk > k:
			for id in _hist[kk]:
				var n := int(_cnt[id]) - 1
				if n > 0:
					_cnt[id] = n
				else:
					_cnt.erase(id)
			_hist.erase(kk)
	for kk in range(k - _win_n + 1, k + 1):
		if not _hist.has(kk):
			var tk := kk * _interval
			var won := model.merge_winners(_objs(tk), tk, _win_n * _interval)
			_hist[kk] = won
			for id in won:
				_cnt[id] = int(_cnt.get(id, 0)) + 1
	_last_k = k


func _release(slot: int) -> void:
	var ob: CloudModel.Obj = _slot_obj[slot]
	if ob != null:
		_slot_of.erase(ob.id)
	_slot_obj[slot] = null
	_want[slot] = 0
	_sel[slot] = 0.0
	_drifting.erase(slot)
	_rec[slot] = PackedFloat32Array()
	_free.append(slot)


## Обновить форму и стадию части облаков за кадр (по кругу) — без пиков нагрузки.
func _update_some(t: float, eye: Vector3) -> void:
	var n := _slot_obj.size()
	if n == 0:
		return
	var per_frame := ceili(float(n) / maxf(float(cfg.update_spread_frames), 1.0))
	for k in per_frame:
		_next_slot = (_next_slot + 1) % n
		if _slot_obj[_next_slot] != null:
			_place(_next_slot, t, eye)


func _add_slot() -> int:
	_rec.append(PackedFloat32Array())
	_slot_obj.append(null)
	_sel.append(0.0)
	_want.append(0)
	_base_vis.append(0.0)
	return _slot_obj.size() - 1


## Запись облака: бокс с запасом (контур шумит, верх растекается, у Cb — наковальня и вирга);
## vis — видимость 0..1 (плотность × vis: уходящее облако тает).
static func make_record(
	c: Vector2, ax: Vector3, base: float, h: float, rx: float, rz: float,
	state: Vector4, extra: Vector4, anvil_pad: float, below_m: float, vis: float = 1.0
) -> PackedFloat32Array:
	var pad := 1.65 + extra.x * 0.8 + extra.y * anvil_pad
	var sy := h * 1.4 + 10.0 + below_m
	var cy := base - below_m + sy * 0.5
	return PackedFloat32Array([
		c.x, cy, c.y, sy * 0.5,
		ax.x, ax.z, rx * pad, rz * pad,
		base, h, rx, rz,
		state.x, state.y, state.z, state.w,
		extra.x, extra.y, extra.z, extra.w,
		vis, 0.0, 0.0, 0.0,
	])


func _place(i: int, t: float, eye: Vector3) -> void:
	var ob: CloudModel.Obj = _slot_obj[i]
	if not ob.alive(t):
		_release(i)
		return
	var st := ob.stage
	var c := ob.center_at(t)
	var axes := _basis_axes
	if st.y > 0.0 or (not ob.is_static and t > ob.drift_t0):
		_drifting[i] = ob
	var sz4 := ob.size
	var base := ob.base_msl
	var anvil := 0.0
	var rain := 0.0
	var scfg: Dictionary = acfg.storm
	if ob.is_cb:
		# Наковальня растёт к началу бури, осадки — во время бури.
		var s0 := ob.storm_t0
		anvil = smoothstep(s0 - 900.0, s0 + 600.0, t)
		rain = ob.storm_k
	var below := 10.0 + (float(scfg.virga_depth_m) if rain > 0.0 else 0.0)
	var anvil_pad := float(scfg.anvil_spread) + float(scfg.anvil_shift)
	var vis := model.life_fade(ob, t) * _range_vis(ob, t, c, eye)
	_base_vis[i] = vis
	_rec[i] = make_record(
		c, axes[0], base, sz4.z, sz4.x, sz4.y,
		Vector4(st.x, st.y, st.z, float(ob.vis_seed)),
		Vector4(sz4.w, anvil, rain, 3.0 if ob.is_cb else 0.0), anvil_pad, below, vis * _sel[i]
	)


## Видимость по дальности: облако тает к max_distance_m (от камеры) и к радиусу, где живут
## термики (от пилота, по основанию столба — как удаляет набор термиков), а не срезается.
## Положение наблюдателя: eye_fn, иначе активная камера, иначе начало координат.
func _eye_pos() -> Vector3:
	if eye_fn.is_valid():
		return eye_fn.call()
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	return cam.global_position if cam != null else Vector3.ZERO


func _range_vis(ob: CloudModel.Obj, t: float, c: Vector2, eye: Vector3) -> float:
	var v := model.range_fade(Vector2(eye.x, eye.z).distance_to(c), model.far_m(ob))
	if not ob.is_static:
		var f := _eye_pos()
		var src := ob.src + ob.drift_at(t)
		v = minf(v, model.range_fade(Vector2(f.x, f.z).distance_to(src), _gen_r))
	return v


## Облака уплывают по ветру вместе с термиками — двигаем их каждый кадр, чтобы не дёргались.
func _update_drift(t: float) -> void:
	for i in _drifting:
		var ob: CloudModel.Obj = _slot_obj[i]
		var c := ob.center_at(t)
		if not _rec[i].is_empty():
			_rec[i][0] = c.x
			_rec[i][2] = c.y


## Облака волны (VR-27) — строго из поля смещения линий тока: лентикулярные в гребнях волн,
## шапка на самой высокой точке рельефа против ветра, роторные клочья под первым гребнем.
func _wave_clouds(eye: Vector3, crests_in: Variant = null) -> Array[PackedFloat32Array]:
	var out: Array[PackedFloat32Array] = []
	if not _wave_enabled():
		return out
	var w: Dictionary = acfg.wave
	var ax: Vector3 = _basis_axes[0]
	var crests: Array = crests_in if crests_in != null else _wave_crests(eye)
	var lam := _wave_length()
	var above := float(atmo.weather().get("lens_level_above_crest_m", 2000.0))
	var eta_ref := float(w.lens_eta_ref_m)
	var n := 0
	for cr: Dictionary in crests:
		if n >= int(w.lens_max):
			break
		var f := clampf(float(cr.eta) / eta_ref, 0.25, 1.0)
		var p: Vector2 = cr.pos
		var seed_v := float(absi(hash(Vector2i(roundi(p.x / 100.0), roundi(p.y / 100.0)))) % 9973)
		var length := lerpf(float(w.lens_length_m[0]), float(w.lens_length_m[1]), f)
		var thick := lerpf(float(w.lens_thickness_m[0]), float(w.lens_thickness_m[1]), f)
		var alt := float(cr.crest) + above + float(cr.eta) * 0.5
		out.append(make_record(
			p, ax, alt - thick * 0.5, thick, lam * float(w.lens_width_frac) * 0.5, length * 0.5,
			Vector4(1, 0, 0, seed_v), Vector4(0, 0, 0, 1), 0.0, 10.0
		))
		n += 1
	if crests.is_empty():
		return out
	var first: Dictionary = crests[0]
	var crest_h := float(first.crest)
	if bool(w.rotor_clouds):
		# Роторные клочья — на уровне гребня хребта под первым гребнем волны: рваные кучевые.
		var p1: Vector2 = first.pos
		out.append(make_record(
			p1, ax, crest_h + 150.0, 220.0, 450.0, 900.0,
			Vector4(0.8, 0.6, 0.0, 311.0), Vector4(0, 0, 0, 0), 0.0, 10.0
		))
	if bool(w.cap_cloud):
		var top := _highest_ground(eye, lam * 0.8)
		if top.z > 0.0:
			out.append(make_record(
				Vector2(top.x, top.y) + Vector2(ax.x, ax.z) * 250.0, ax, top.z - 180.0, 420.0,
				900.0, 2200.0, Vector4(1, 0.2, 0, 523.0), Vector4(0, 0, 0, 2), 0.0, 10.0
			))
	return out


## Волна есть (wave_info, W6 v4): включена и место загружено.
func _wave_enabled() -> bool:
	var info := atmo.wave_info()
	return info.size() > Atmosphere.WAVE_INFO_ENABLED and info[Atmosphere.WAVE_INFO_ENABLED] > 0.5


## Длина подветренной волны, м (wave_info).
func _wave_length() -> float:
	var info := atmo.wave_info()
	if info.size() <= Atmosphere.WAVE_INFO_LENGTH:
		return 0.0
	return float(info[Atmosphere.WAVE_INFO_LENGTH])


## Гребни волны вокруг камеры (первая, тяжёлая половина _wave_clouds): словари {pos, eta, crest}
## из записей wave_crests (шаг CREST_STRIDE: x, z, eta, crest).
func _wave_crests(eye: Vector3) -> Array[Dictionary]:
	var w: Dictionary = acfg.wave
	var raw := atmo.wave_crests(
		Vector2(eye.x, eye.z),
		float(w.lens_radius_m),
		float(w.lens_min_eta_m),
		float(w.lens_length_m[1]) * 0.9
	)
	var out: Array[Dictionary] = []
	@warning_ignore("integer_division")
	var n := raw.size() / Atmosphere.CREST_STRIDE
	for i in n:
		var o := i * Atmosphere.CREST_STRIDE
		out.append({"pos": Vector2(raw[o], raw[o + 1]), "eta": raw[o + 2], "crest": raw[o + 3]})
	return out


## Самая высокая точка рельефа рядом (для шапки): Vector3(x, z, высота) или z < 0.
func _highest_ground(eye: Vector3, radius: float) -> Vector3:
	if is_nan(ground_msl(eye.x, eye.z)):
		return Vector3(0, 0, -1)
	var best := Vector3(0, 0, -1.0e9)
	var step := radius / 10.0
	for j in range(-10, 11):
		for i in range(-10, 11):
			var x := eye.x + i * step
			var z := eye.z + j * step
			var h := ground_msl(x, z)
			if h > best.z:
				best = Vector3(x, z, h)
	return best


# ---------------------------------------------------------------- слой поля облачности (CLF-5)

## Поле облачности → текстуры и параметры слоя. Текстура обновляется только при смене данных
## поля (новый шаг step_s, смена сетки, основания, фона), между шагами — переход от прошлого
## шага к новому за step_s (поле само сносится ветром; без перехода облака прыгали бы раз в шаг).
func _update_field(t: float) -> void:
	var ver := atmo.cloud_raster_version()
	if ver <= 0 or not textures_ready():
		field_params["cf_on"] = 0.0
		return
	var key := str(ver)
	if key != _cf_key:
		var r := atmo.cloud_raster()
		if int(r.get("nx", 0)) <= 0 or int(r.get("ny", 0)) <= 0:
			field_params["cf_on"] = 0.0
			return
		_cf_key = key
		_upload_field(r, t)
	var misc: Vector4 = field_params.get("cf_misc", Vector4.ZERO)
	misc.w = clampf((t - _cf_t_upd) / _cf_step, 0.0, 1.0)
	field_params["cf_misc"] = misc


## Растр cloud_raster() -> RGBA8 (CLF-К2): R = покрытие, G = мощность / depth_max_m,
## B = (стадия + 1)/2, A = активность; строка растёт к +Z, как строка текстуры.
func _raster_image(r: Dictionary, dmax: float) -> Image:
	var nx := int(r.nx)
	var ny := int(r.ny)
	var cover: PackedFloat32Array = r.cover
	var depth: PackedFloat32Array = r.depth
	var stage: PackedFloat32Array = r.stage
	var act: PackedFloat32Array = r.activity
	var out := PackedByteArray()
	out.resize(nx * ny * 4)
	var inv := 1.0 / dmax
	for c in nx * ny:
		var o := c * 4
		out[o] = int(round(clampf(cover[c], 0.0, 1.0) * 255.0))
		out[o + 1] = int(round(clampf(depth[c] * inv, 0.0, 1.0) * 255.0))
		out[o + 2] = int(round(clampf((stage[c] + 1.0) * 0.5, 0.0, 1.0) * 255.0))
		out[o + 3] = int(round(clampf(act[c], 0.0, 1.0) * 255.0))
	return Image.create_from_data(nx, ny, false, Image.FORMAT_RGBA8, out)


func _upload_field(r: Dictionary, t: float) -> void:
	var fc: Dictionary = acfg.get("cloud_field", {})
	_cf_step = maxf(float(fc.get("step_s", 20.0)), 0.1)
	var nx := int(r.nx)
	var ny := int(r.ny)
	var dx := float(r.dx)
	var base_msl := float(r.base_msl)
	var bg_c: PackedFloat32Array = r.bg_cover
	var bg_d: PackedFloat32Array = r.bg_depth
	var bg_cover := bg_c[0] if not bg_c.is_empty() else 0.0
	var bg_depth := bg_d[0] if not bg_d.is_empty() else 0.0
	var dmax := maxf(float(fc.get("depth_max_m", 2500.0)), 1.0)
	var img := _raster_image(r, dmax)
	var same_grid := field_tex != null and _cf_img != null and _cf_img.get_size() == img.get_size()
	# Переход от прошлого шага — только к соседнему шагу (скачок времени, сброс — сразу новое).
	var dt := t - _cf_t_upd
	var prev: Image = _cf_img if same_grid and dt >= 0.0 and dt <= 3.0 * _cf_step else img
	if same_grid:
		field_tex_prev.update(prev)
		field_tex.update(img)
	else:
		field_tex_prev = ImageTexture.create_from_image(prev)
		field_tex = ImageTexture.create_from_image(img)
	_cf_prev_img = prev
	_cf_img = img
	_cf_t_upd = t
	field_uploads += 1
	var mm := field_max_map(prev, img, nx, ny)
	var b: int = mm.block
	var mimg: Image = mm.image
	if field_max_tex != null and field_max_tex.get_size() == Vector2(mimg.get_size()):
		field_max_tex.update(mimg)
	else:
		field_max_tex = ImageTexture.create_from_image(mimg)
	var top := maxf(float(mm.g_max) / 255.0 * dmax, bg_depth)
	var any_cloud := int(mm.r_max) > 0 or bg_cover > 0.0
	# Растр W6: x0, z0 — центр ячейки (0, 0), строка растёт к +Z; рамка — от края ячейки.
	var x_min := float(r.x0) - 0.5 * dx
	var z_min := float(r.z0) - 0.5 * dx
	field_params["cf_rect"] = Vector4(x_min, z_min, 1.0 / (nx * dx), 1.0 / (ny * dx))
	field_params["cf_base"] = Vector4(base_msl, dmax, bg_cover, bg_depth)
	field_params["cf_edge"] = float(fc.get("edge_fade_m", 2000.0))
	field_params["cf_shell_w"] = float(cfg.get("field_shell_width_m", 40.0))
	field_params["cf_shell_dens"] = float(cfg.get("field_shell_density", 0.25))
	field_params["cf_shell_h"] = float(cfg.get("field_shell_out_m", 25.0))
	field_params["cf_base_soft"] = float(cfg.get("field_base_soft_m", 60.0))
	field_params["cf_mrect"] = Vector4(
		x_min, z_min, 1.0 / (mimg.get_width() * b * dx), 1.0 / (mimg.get_height() * b * dx)
	)
	# Верх слоя: купол не выше мощности поля, оболочка — с запасом (cf_envelope: ×1,2 + 40 м).
	field_params["cf_misc"] = Vector4(
		top * 1.2 + 60.0, float(cfg.max_distance_m), float(cfg.field_mask_period_m), 0.0
	)
	var q := _cf_quantiles()
	for k in 4:
		field_params["cf_q%d" % k] = Vector4(q[k * 4], q[k * 4 + 1], q[k * 4 + 2], q[k * 4 + 3])
	field_params["cf_on"] = 1.0 if any_cloud and top > 1.0 else 0.0


# ---------------------------------------------------------------- CVW-К3: плотность рисуемых облаков

# Константы формы — копия из cloud_common.gdshaderinc (тест сверяет).
const V_FADE_H0 := 1.2
const V_FADE_H1 := 1.35
const V_FADE_R1 := 1.6
const V_TOWERS := 8
const V_CF_DOME_E := 0.6
const V_CF_ASPECT := 0.55
const V_CF_D_REF := 1500.0
const V_CF_W_MIN := 200.0
const V_CF_W_MAX := 3000.0
const V_CF_XI_MU := 0.866
const V_CF_XI_SD := 0.219
const V_CF_XI_LO := -1.0
const V_CF_XI_HI := 2.5
const V_CF_MASK_K := 0.7351
const V_CF_MASK_O := Vector3(0.317, 0.642, 0.139)
const V_CF_EDGE_E := 0.12


## Плотность 0..1 в точке p (мир) по облакам, которые сейчас рисуются: записи облаков (объекты,
## волновые) и слой поля облачности. Форма — крупная часть cloud_density / cf_density_top из
## cloud_common.gdshaderinc (без мелкой эрозии краёв, без клочьев вне границы, без вирги).
## −1 — ничего не рисуется (слой не настроен, нет записей с видимостью > 0, поле выключено).
## Вне всех рисуемых облаков — 0. Цена: одна точка, обход записей (десятки), без выделений в цикле.
func visible_density_at(p: Vector3) -> float:
	if atmo == null:
		return -1.0
	_ensure_nz()
	var drawn := false
	var best := 0.0
	for i in _rec.size():
		if _slot_obj[i] == null:
			continue
		var r: PackedFloat32Array = _rec[i]
		if r.size() < 21 or r[20] <= 0.0:
			continue
		drawn = true
		best = maxf(best, _rec_density(r, p))
	for r: PackedFloat32Array in _wave_rec:
		if r.size() < 21 or r[20] <= 0.0:
			continue
		drawn = true
		best = maxf(best, _rec_density(r, p))
	if float(field_params.get("cf_on", 0.0)) > 0.5 and _cf_img != null and _cf_quant.size() == 16:
		drawn = true
		best = maxf(best, _field_density(p))
	return clampf(best, 0.0, 1.0) if drawn else -1.0


static func _vfract(x: float) -> float:
	return x - floorf(x)


## Выборка канала (0 R, 1 G, 2 B) 3D-шума в координатах текстуры u (повтор), мип 0, трилинейно.
func _nz(ch: int, u: Vector3) -> float:
	var sl := _nz_slices
	var nd := sl.size()
	if nd == 0:
		return 0.5
	var w := sl[0].get_width()
	var h := sl[0].get_height()
	var x := u.x * w - 0.5
	var y := u.y * h - 0.5
	var z := u.z * nd - 0.5
	var x0 := floori(x)
	var y0 := floori(y)
	var z0 := floori(z)
	var fx := x - x0
	var fy := y - y0
	var fz := z - z0
	var acc := 0.0
	for dz in 2:
		var im := sl[posmod(z0 + dz, nd)]
		var wz := fz if dz == 1 else 1.0 - fz
		for dy in 2:
			var wy := fy if dy == 1 else 1.0 - fy
			var yy := posmod(y0 + dy, h)
			for dx in 2:
				var wx := fx if dx == 1 else 1.0 - fx
				var c := im.get_pixel(posmod(x0 + dx, w), yy)
				acc += (c.r if ch == 0 else (c.g if ch == 1 else c.b)) * wx * wy * wz
	return acc


## Срезы шума из текстуры слоя (один раз; без сжатия, RGB8).
func _ensure_nz() -> void:
	if not _nz_slices.is_empty():
		return
	var tex: Texture3D = _material.get_shader_parameter("noise_shape")
	if tex == null or (tex is NoiseTexture3D and tex.get_data().is_empty()):
		return
	var data := tex.get_data()
	# get_data() у импортированной текстуры отдаёт и срезы мипов - берём только мип 0
	var sz := Vector2i(tex.get_width(), tex.get_height())
	for src: Image in data:
		if src.get_size() != sz or _nz_slices.size() >= tex.get_depth():
			continue
		var c := src.duplicate() as Image
		if c.is_compressed():
			c.decompress()
		c.convert(Image.FORMAT_RGB8)
		_nz_slices.append(c)


## Башни облака-записи (cloud_init_towers): центр (u, v), высота, радиус; seed_off — зерно.
static func _towers(seed_off: Vector3, kind: int) -> Array[Vector4]:
	var out: Array[Vector4] = []
	for k in V_TOWERS:
		var n := seed_off.x * 13.1 + float(k) * 7.13
		var hx := _vfract(sin(n) * 43758.5453)
		var hy := _vfract(sin(n + 1.7) * 22578.1459)
		var hz := _vfract(sin(n + 3.1) * 19642.3490)
		var main_t := k == 0
		var ang := hx * TAU
		var rr := 0.12 * hy if main_t else lerpf(0.25, 0.62, hy)
		var th := 1.0 if main_t else lerpf(0.45, 0.85, hz) * (1.0 - 0.45 * rr)
		var rk := 0.8 if main_t else lerpf(0.35, 0.55, _vfract(hz * 7.1 + hx)) * lerpf(0.75, 1.0, th)
		if kind == 3:
			th = 1.0 if main_t else lerpf(0.6, 0.95, hz)
			rk = 0.9 if main_t else lerpf(0.45, 0.65, _vfract(hz * 7.1 + hx))
		out.append(Vector4(cos(ang) * rr, sin(ang) * rr, th, rk))
	return out


static func _towers_at(tw: Array[Vector4], uv: Vector2, h: float, kind: int) -> float:
	var best := -2.0
	for t in tw:
		var q := Vector2(uv.distance_to(Vector2(t.x, t.y)) / t.w, h / t.z)
		if kind == 3:
			var q2x := q.x * q.x
			var q2y := q.y * q.y
			best = maxf(best, 1.0 - sqrt(sqrt(q2x * q2x + q2y * q2y)))
		else:
			best = maxf(best, 1.0 - q.length())
	return best


## Плотность одной записи облака в точке (крупная форма cloud_density_raw × vis³).
func _rec_density(r: PackedFloat32Array, p: Vector3) -> float:
	var kind := int(r[19] + 0.5)
	var height := maxf(r[9], 10.0)
	var rx := maxf(r[10], 10.0)
	var rz := maxf(r[11], 10.0)
	var h := (p.y - r[8]) / height
	var dx := p.x - r[0]
	var dz := p.z - r[2]
	# бокс записи: вне него шейдер облако не рисует
	var bx := dx * r[4] + dz * r[5]
	var bz := -dx * r[5] + dz * r[4]
	if absf(bx) > r[6] or absf(bz) > r[7] or absf(p.y - r[1]) > r[3]:
		return 0.0
	var uv := Vector2(bx / rx, bz / rz)
	var vis := clampf(r[20], 0.0, 1.0)
	var v3 := vis * vis * vis
	if kind == 1 or kind == 2:
		if h < 0.0 or h > 1.0:
			return 0.0
		return _lens(kind, uv, h, r[15]) * v3
	if h < 0.0 or h > V_FADE_H1:
		return 0.0  # вирга под основанием не учитывается
	var spread := r[16]
	var anvil := r[17]
	var a_spread := float(acfg.storm.anvil_spread)
	var a_shift := float(acfg.storm.anvil_shift)
	var fade_r := V_FADE_R1 + spread * 0.8 + anvil * (a_spread + a_shift)
	var r_box := uv.length()
	if r_box > fade_r:
		return 0.0
	var box_fade := (1.0 - smoothstep(fade_r - 0.25, fade_r, r_box)) * (1.0 - smoothstep(V_FADE_H0, V_FADE_H1, h))
	var spread_k := 1.0 + spread * smoothstep(0.55, 1.0, h)
	if kind == 3:
		spread_k += anvil * 0.8 * smoothstep(0.6, 0.95, h)
	var s := r[15]
	var seed_off := Vector3(_vfract(s * 0.1031), _vfract(s * 0.1130), _vfract(s * 0.0973)) * 7.0
	var decay := r[13]
	var growth := r[12]
	var shape := _towers_at(_towers(seed_off, kind), uv / spread_k, h, kind)
	shape -= decay * 0.15 + (1.0 - vis) * 0.35
	shape = clampf(shape / lerpf(0.55, 0.8, decay), 0.0, 1.0)
	var anvil_m := 0.0
	if anvil > 0.0 and h > 0.7:
		var ua := uv - Vector2(a_shift * anvil, 0.0)
		var ra := 1.0 + a_spread * anvil
		var rr := Vector2(ua.x, ua.y * 1.6).length() / ra
		var thick := lerpf(0.12, 0.03, smoothstep(0.0, 1.0, rr))
		var av := smoothstep(0.97 - thick, 0.97 - thick + 0.02, h) * (1.0 - smoothstep(0.97, 1.0, h))
		var ah := 1.0 - smoothstep(0.7, 1.0, rr)
		anvil_m = av * ah * anvil * lerpf(1.0, 0.35, smoothstep(0.1, 0.8, rr))
	if shape <= 0.0 and anvil_m <= 0.0:
		return 0.0
	# клубы (канал R шума), как у шейдера: ветер и «кипение»
	var ns := clampf(height / 2500.0, 1.0, 3.5) if kind == 3 else 1.0
	var billow := _billow(p, seed_off, ns, true)
	var base_soft := lerpf(10.0, 120.0, decay) / height
	var base_lift := (float(cfg.base_relief_m) / height + decay * 0.3) * (1.0 - billow)
	var dns := shape * smoothstep(base_lift, base_lift + base_soft, h)
	var erosion := (lerpf(0.75, 0.93, decay) + (1.0 - growth) * 0.15) * (1.0 - 0.6 * anvil_m)
	if kind == 3:
		erosion *= 0.8
	dns = clampf(_remap01(dns, erosion * (1.0 - billow)), 0.0, 1.0)
	if anvil_m > 0.0:
		dns = maxf(dns, anvil_m * 0.7)  # волокна ледяной плиты опущены: среднее smoothstep(0,15..0,6)
	dns = smoothstep(0.0, lerpf(float(cfg.surface_sharpness), 1.0, decay), dns)
	return dns * box_fade * lerpf(0.3, 1.0, growth) * lerpf(1.0, 0.2, decay * decay) * v3


static func _remap01(v: float, lo: float) -> float:
	return (v - lo) / maxf(1.0 - lo, 1.0e-4)


func _wind_off() -> Vector3:
	var w: Variant = _material.get_shader_parameter("wind_offset")
	return w if w is Vector3 else Vector3.ZERO


## Клубы Уорли (канал R) в точке: seed_off/ns — у записей, нули/1 — у слоя поля.
func _billow(p: Vector3, seed_off: Vector3, ns: float, two: bool) -> float:
	if _nz_slices.is_empty():
		return 0.5
	var wo := _wind_off()
	var bv: Variant = _material.get_shader_parameter("boil")
	var boil := float(bv) if bv != null else 0.0
	var per := float(cfg.shape_period_m)
	var sp := (p + wo) / (per * ns) + seed_off + Vector3(0.0, boil, 0.0)
	var b1 := smoothstep(0.2, 0.85, 1.0 - _nz(0, sp))
	if not two:
		return b1
	var b2 := smoothstep(0.2, 0.85, 1.0 - _nz(0, sp * 2.7 + Vector3(0.5, 0.5, 0.5)))
	return b1 * 0.6 + b2 * 0.4


## Линза (вид 1) и шапка (вид 2): гладкая форма без шума (lens_density).
static func _lens(kind: int, uv: Vector2, h: float, seed_v: float) -> float:
	var r := uv.length()
	if r >= 1.0:
		return 0.0
	if kind == 1:
		var sy := _vfract(seed_v * 0.1130) * 7.0
		var n := 2 + int(_vfract(sy * 3.7) * 2.99)
		var fn := float(n)
		var dns := 0.0
		for i in n:
			var hc := (float(i) + 0.5) / fn
			var mid := absf(float(i) - (fn - 1.0) * 0.5) / fn
			var ri := r / (1.0 - 0.35 * mid)
			if ri >= 1.0:
				continue
			var th := 0.5 / fn * pow(1.0 - ri * ri, 0.8)
			dns = maxf(dns, smoothstep(0.0, 0.25 / fn, th - absf(h - hc)))
		return dns
	var inside := pow(1.0 - r * r, 0.5) - absf(2.0 * h - 1.0)
	return smoothstep(0.0, 0.1, inside) if inside > 0.0 else 0.0


# --- слой поля облачности (cf_* в cloud_common.gdshaderinc)

func _cf_px(img: Image, nx: int, ny: int, uv: Vector2) -> Color:
	var x := uv.x * nx - 0.5
	var y := uv.y * ny - 0.5
	var x0 := floori(x)
	var y0 := floori(y)
	var fx := x - x0
	var fy := y - y0
	var c := Color(0, 0, 0, 0)
	for dy in 2:
		for dx in 2:
			var w := (fx if dx == 1 else 1.0 - fx) * (fy if dy == 1 else 1.0 - fy)
			c += img.get_pixel(clampi(x0 + dx, 0, nx - 1), clampi(y0 + dy, 0, ny - 1)) * w
	return c


## Поле в xz: (покрытие, мощность м, стадия −1..1, активность) — cf_sample.
func _cf_field(x: float, z: float) -> Vector4:
	var rect: Vector4 = field_params["cf_rect"]
	var base: Vector4 = field_params["cf_base"]
	var uv := Vector2((x - rect.x) * rect.z, (z - rect.y) * rect.w)
	var nx := _cf_img.get_width()
	var ny := _cf_img.get_height()
	var k: float = field_params["cf_misc"].w
	var v := _cf_px(_cf_img, nx, ny, uv)
	if _cf_prev_img != null and k < 1.0 and _cf_prev_img.get_size() == _cf_img.get_size():
		v = _cf_px(_cf_prev_img, nx, ny, uv).lerp(v, k)
	var ox := maxf(maxf(-uv.x, uv.x - 1.0), 0.0) / rect.z
	var oz := maxf(maxf(-uv.y, uv.y - 1.0), 0.0) / rect.w
	var w := clampf(1.0 - Vector2(ox, oz).length() / maxf(float(field_params["cf_edge"]), 1.0), 0.0, 1.0)
	return Vector4(
		lerpf(base.z, v.r, w), lerpf(base.w, v.g * base.y, w), (v.b * 2.0 - 1.0) * w, v.a * w
	)


func _cf_threshold(c: float) -> float:
	var x := clampf(1.0 - c, 0.0, 1.0) * 15.0
	var i := mini(int(x), 14)
	return lerpf(_cf_quant[i], _cf_quant[i + 1], x - float(i))


## Превышение порога маски (cf_excess): x — превышение, y — предел высоты, м.
func _cf_excess(p: Vector3, f: Vector4) -> Vector2:
	var base: Vector4 = field_params["cf_base"]
	var per: float = field_params["cf_misc"].z
	var wo := _wind_off()
	var q := Vector3(p.x + wo.x, (p.y - base.x) * 0.3, p.z + wo.z) / per
	var q2 := q * V_CF_MASK_K + V_CF_MASK_O
	var mg := _nz(1, q) + _nz(1, q2)
	var mb := _nz(2, q) + _nz(2, q2)
	var xi := clampf(((mb - V_CF_XI_MU) / V_CF_XI_SD - V_CF_XI_LO) / (V_CF_XI_HI - V_CF_XI_LO), 0.0, 1.0)
	var lim := minf(
		f.y, V_CF_ASPECT * maxf(1.0, f.y / V_CF_D_REF) * V_CF_W_MIN * pow(V_CF_W_MAX / V_CF_W_MIN, xi)
	)
	return Vector2((mg - _cf_threshold(f.x)) / maxf(_cf_quant[15] - _cf_quant[8], 1.0e-3), lim)


## Плотность слоя поля в точке (cf_density_top, quality 1): без клочьев вне границы и мелкой эрозии.
func _field_density(p: Vector3) -> float:
	var base: Vector4 = field_params["cf_base"]
	var shell_w0: float = field_params["cf_shell_w"]
	var shell_h0: float = field_params["cf_shell_h"]
	var f := _cf_field(p.x, p.z)
	var h := p.y - base.x
	if h < -shell_h0 or f.x < 0.004 or f.y < 1.0:
		return 0.0
	var ex0 := _cf_excess(p, f)
	var e := ex0.x
	var lim := ex0.y
	if e <= 0.0 or h < 0.0:
		return 0.0  # снаружи — только редкие клочья (≤ cf_shell_dens), не считаем
	var shell_w := shell_w0 * lerpf(1.0, 0.5, maxf(f.z, 0.0)) * (1.0 + 0.5 * maxf(-f.z, 0.0))
	var shell_on := shell_w0 > 0.5
	var d_in := 1.0e9
	if shell_on and (e < 0.5 or h < shell_w):
		var ex := _cf_excess(p + Vector3(30.0, 0.0, 0.0), f).x
		var ez := _cf_excess(p + Vector3(0.0, 0.0, 30.0), f).x
		var g := maxf(Vector2(ex - e, ez - e).length() / 30.0, 1.0 / 3000.0)
		d_in = e / g
	var x := clampf(e / V_CF_DOME_E, 0.0, 1.0)
	var top := lim * sqrt(x * (2.0 - x))
	if h > top * 1.2 + 30.0:
		return 0.0
	var growth := 1.0 - 0.7 * maxf(f.z, 0.0)
	var decay := maxf(-f.z, 0.0)
	var shape := minf(1.0 - h / maxf(top, 1.0), e / V_CF_EDGE_E)
	shape -= decay * 0.15
	shape = clampf(shape / lerpf(0.55, 0.8, decay), 0.0, 1.0)
	if shape <= 0.0:
		return 0.0
	var billow := _billow(p, Vector3.ZERO, 1.0, true)
	var rag := 1.0 + 2.5 * maxf(f.z, 0.0)
	var cbs := float(cfg.get("field_base_soft_m", 60.0))
	var base_soft := lerpf(maxf(cbs, 10.0), maxf(cbs, 120.0), decay) + 40.0 * maxf(f.z, 0.0)
	var base_lift := (float(cfg.base_relief_m) * rag + decay * decay * 0.45 * minf(top, 700.0)) * (1.0 - billow)
	var dns := shape * smoothstep(base_lift, base_lift + base_soft, h)
	if dns <= 0.0:
		return 0.0
	var erosion := lerpf(0.75, 0.93, decay) + (1.0 - growth) * 0.15
	dns = clampf(_remap01(dns, erosion * (1.0 - billow)), 0.0, 1.0)
	dns = smoothstep(0.0, lerpf(float(cfg.surface_sharpness), 1.0, decay), dns)
	var shell := 1.0
	if shell_on:
		d_in = minf(d_in, top - h)
		shell = smoothstep(0.0, 1.0, d_in / maxf(shell_w, 1.0))
	return dns * lerpf(0.3, 1.0, growth) * lerpf(1.0, 0.2, decay * decay) * shell


## Грубая карта поля: блок B × B клеток (B — делитель nx и ny из 4, 3, 2, 1), в блоке — наибольшие
## покрытие (R) и мощность (G) по клеткам блока и соседним (билинейная выборка заходит на соседа)
## у прошлого и нового шага. {image: RG8 nbx × nby (строки — как у текстуры К2), block, r_max,
## g_max}.
static func field_max_map(prev: Image, cur: Image, nx: int, ny: int) -> Dictionary:
	var b := 1
	for c in [4, 3, 2]:
		if nx % c == 0 and ny % c == 0:
			b = c
			break
	var pa := prev.get_data()
	var ca := cur.get_data()
	var n := nx * ny
	var r := PackedByteArray()
	var g := PackedByteArray()
	r.resize(n)
	g.resize(n)
	var r_max := 0
	var g_max := 0
	for k in n:
		var o := k * 4
		var rv := maxi(pa[o], ca[o])
		var gv := maxi(pa[o + 1], ca[o + 1]) if rv > 0 else 0
		r[k] = rv
		g[k] = gv
		r_max = maxi(r_max, rv)
		g_max = maxi(g_max, gv)
	var nbx := floori(float(nx) / b)
	var nby := floori(float(ny) / b)
	var out := PackedByteArray()
	out.resize(nbx * nby * 2)
	if r_max > 0:
		# Сначала по строкам (окно блока ± 1 клетка), затем по столбцам.
		var hr := PackedByteArray()
		var hg := PackedByteArray()
		hr.resize(nbx * ny)
		hg.resize(nbx * ny)
		for row in ny:
			for bx in nbx:
				var mr := 0
				var mg := 0
				for i in range(maxi(bx * b - 1, 0), mini(bx * b + b + 1, nx)):
					mr = maxi(mr, r[row * nx + i])
					mg = maxi(mg, g[row * nx + i])
				hr[row * nbx + bx] = mr
				hg[row * nbx + bx] = mg
		for by in nby:
			for bx in nbx:
				var mr := 0
				var mg := 0
				for row in range(maxi(by * b - 1, 0), mini(by * b + b + 1, ny)):
					mr = maxi(mr, hr[row * nbx + bx])
					mg = maxi(mg, hg[row * nbx + bx])
				out[(by * nbx + bx) * 2] = mr
				out[(by * nbx + bx) * 2 + 1] = mg
	var img := Image.create_from_data(nbx, nby, false, Image.FORMAT_RG8, out)
	return {"image": img, "block": b, "r_max": r_max, "g_max": g_max}


## Квантили маски на долях 0, 1/15 … 1 (сумма двух выборок канала G текстуры шума): порог
## покрытия c —
## квантиль 1 − c, над ним ровно доля c объёма маски (площадь под облаком = покрытие поля).
func _cf_quantiles() -> PackedFloat32Array:
	if _cf_quant.size() == 16:
		return _cf_quant
	var tex: Texture3D = _material.get_shader_parameter("noise_shape")
	var key := tex.resource_path if tex.resource_path != "" else str(tex.get_instance_id())
	if not _quant_cache.has(key):
		_quant_cache[key] = noise_quantiles(tex)
	_cf_quant = _quant_cache[key]
	return _cf_quant


## Последний квантиль — не предел носителя (2·max G — нигде не достижим), а 1 − MASK_TOP_TAIL.
## 16 квантилей суммы двух независимых выборок канала G 3D-текстуры (cloud_shape.png, RGB; cf_mask в
## cloud_common.gdshaderinc берёт две выборки в разных точках): гистограмма G (каждый 4-й срез,
## каждый 7-й
## тексель) сворачивается сама с собой. Значения — в долях 1 (сумма 0…2).
static func noise_quantiles(tex: Texture3D) -> PackedFloat32Array:
	return slice_quantiles(tex.get_data())


## То же по срезам (изображения; без текстуры — тесты читают атлас PNG напрямую).
static func slice_quantiles(slices: Array[Image]) -> PackedFloat32Array:
	var hist := PackedFloat64Array()
	hist.resize(256)
	var total := 0.0
	for zi in range(0, slices.size(), 4):
		var im := slices[zi].duplicate() as Image
		if im.is_compressed():
			im.decompress()
		im.convert(Image.FORMAT_RGB8)
		var d := im.get_data()
		for k in range(1, d.size(), 21):
			hist[d[k]] += 1.0
			total += 1.0
	var q := PackedFloat32Array()
	q.resize(16)
	if total == 0.0:
		for k in 16:
			q[k] = 2.0 * k / 15.0
		return q
	var conv := PackedFloat64Array()
	conv.resize(511)
	for i in 256:
		if hist[i] == 0.0:
			continue
		for j in 256:
			conv[i + j] += hist[i] * hist[j]
	var sum2 := total * total
	var cum := 0.0
	var k := 1
	var lo := -1
	for v in 511:
		if conv[v] > 0.0 and lo < 0:
			lo = v
		cum += conv[v]
		while k < 16 and cum >= sum2 * (float(k) / 15.0 if k < 15 else 1.0 - MASK_TOP_TAIL) - 1e-9:
			q[k] = v / 255.0
			k += 1
	q[0] = maxi(lo, 0) / 255.0
	return q
