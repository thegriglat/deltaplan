class_name CloudLayer
extends Node3D
## Облака и их тени на земле (CloudShadowMap). Всё видимое — строго из физической модели (VR-0):
## - кучевые над термиками: рост → зрелость (плотное, чёткие клубы, тёмное плоское основание) →
##   распад (рваное, тает, уплывает); Cb — башня до тропопаузы, наковальня, вирга (VR-26);
## - лентикулярные в гребнях подветренных волн, шапка на гребне хребта, роторные клочья (VR-27).
## Два способа рисовать (общий код — cloud_common.gdshaderinc):
## - compute (Forward+/Mobile): все облака одним raymarch-проходом в буфере пониженного
##   разрешения с апскейлом (CloudCompositorEffect на активной камере);
## - boxes (Compatibility): одна MultiMesh, бокс на облако, параметры — в float-текстуре.
## Никаких других визуальных признаков термиков (FR-22).

const FLOATS_PER_CLOUD := 24

var atmo: Atmosphere
var cfg: Dictionary
## Время последнего выбора облаков (CPU), мкс — для замеров.
var last_rebuild_us: int = 0
## Логика: стадии, размеры, выбор видимых облаков (общая с физикой: atmo.cloud_phys.model).
var model: CloudModel
## Выбор без памяти о кадрах (только сетевая игра, ставит NetFlight): набор облаков и их
## видимость — функция времени атмосферы, одинаковая у всех клиентов зоны (NET-00). В одиночной
## игре — выбор с гистерезисом и накопленным проявлением/таянием: облако, чей термик ушёл из
## поля, тает, а не пропадает за кадр (в режиме без памяти такие облака исчезали за кадр).
var history_free := false

var _material: ShaderMaterial
var _box: BoxMesh
var _shadow_map: CloudShadowMap
## Слоты облаков над термиками: термик в слоте (null — свободен), id -> слот, свободные слоты.
var _slot_th: Array = []
var _slot_of: Dictionary = {}
var _free: Array[int] = []
## Записи облаков по слотам (по FLOATS_PER_CLOUD чисел) и облаков волны (неподвижные).
var _rec: Array[PackedFloat32Array] = []
var _wave_rec: Array[PackedFloat32Array] = []
## Распадающиеся облака (слот -> термик) — их снос обновляется каждый кадр.
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
## Термики живут в этом радиусе вокруг пилота (ThermalField) — к нему облако тает.
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


func setup(atmosphere: Atmosphere) -> void:
	atmo = atmosphere
	cfg = atmo.cfg.clouds
	model = atmo.cloud_phys.model
	_gen_r = float(atmo.cfg.thermal.generation_radius_m)
	_interval = maxf(float(cfg.update_interval_s), 0.05)
	_win_n = maxi(1, roundi(float(cfg.get("fade_out_s", 60.0)) / _interval))
	atmo.weather_changed.connect(_on_weather_changed)
	_material = ShaderMaterial.new()
	_material.shader = load("res://scripts/atmosphere/cloud_volume.gdshader")
	var seed_value := int(atmo.cfg.seed)
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
	var st: Dictionary = atmo.cfg.storm
	for u in ["anvil_spread", "anvil_shift", "virga_depth_m", "virga_density", "virga_period_m"]:
		_material.set_shader_parameter(u, float(st[u]))
	_material.set_shader_parameter("shape_tex_size", float(cfg.noise_shape_size))
	_material.set_shader_parameter("detail_tex_size", float(cfg.noise_detail_size))
	_material.set_shader_parameter("ambient_top", _color(cfg.ambient_top))
	_material.set_shader_parameter("ambient_bottom", _color(cfg.ambient_bottom))
	_box = BoxMesh.new()
	_box.size = Vector3.ONE
	var renderer := String(cfg.renderer)
	if renderer != "boxes" and RenderingServer.get_rendering_device() != null:
		_effect = CloudCompositorEffect.new()
		_effect.noise_shape = _material.get_shader_parameter("noise_shape")
		_effect.noise_detail = _material.get_shader_parameter("noise_detail")
	else:
		_make_multimesh()
	if bool(cfg.shadows):
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
		if _slot_th[i] != null and not _rec[i].is_empty():
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
	# Модель облаков — общая с физикой (подсос считается по тем же стадиям и размерам).
	model = atmo.cloud_phys.model
	_acc = 1.0e9
	_instant = true
	_hist.clear()
	_cnt.clear()


func _process(delta: float) -> void:
	if atmo == null:
		return
	var t := atmo.time_s
	var dt := clampf(t - _last_t, 0.0, 1.0e6) if _last_t > -1.0e17 else 0.0
	_last_t = t
	# Шум облаков «течёт» с ветром на кромке: форма стоит над термиком, клубы плывут.
	var cb_agl := maxf(atmo.field.cloudbase_msl - atmo._ground_ref, 100.0)
	var w := atmo.wind.vec2_at(cb_agl) * float(cfg.noise_wind_factor)
	_material.set_shader_parameter("wind_offset", -Vector3(w.x, 0.0, w.y) * t)
	_material.set_shader_parameter("boil", t * float(cfg.boil_speed))
	_light_acc += delta
	if _light_acc > 1.0:
		_light_acc = 0.0
		_update_light()
	var cam := get_viewport().get_camera_3d()
	var eye := cam.global_position if cam != null else atmo.get_focus()
	if _effect != null:
		_attach_effect(cam)
	_acc += delta
	# Выбор — на каждом интервале времени атмосферы (и при движении камеры на паузе).
	if (history_free and floori(t / _interval) != _last_k) or _acc >= _interval:
		_acc = 0.0
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
	_material.set_shader_parameter("sun_color", Vector3(color.r, color.g, color.b))
	_material.set_shader_parameter("sun_energy", _sun_energy * atmo.get_insolation())
	var env: Environment = (
		get_world_3d().environment if is_inside_tree() and get_world_3d() != null else null
	)
	if env != null and env.fog_enabled:
		var fc := env.fog_light_color.srgb_to_linear() * env.fog_light_energy
		_material.set_shader_parameter("fog_color", Vector3(fc.r, fc.g, fc.b))
		_material.set_shader_parameter("fog_density", env.fog_density)
		_material.set_shader_parameter("fog_sun_scatter", env.fog_sun_scatter)
	else:
		var fc2 := _color(cfg.fog_color_fallback).srgb_to_linear()
		_material.set_shader_parameter("fog_color", Vector3(fc2.r, fc2.g, fc2.b))
		_material.set_shader_parameter("fog_density", float(cfg.fog_density_fallback))


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
	var wd := atmo.wind.dir
	if wd.length_squared() < 1.0e-6:
		wd = Vector3(1, 0, 0)
	_basis_axes = [wd, Vector3.UP, wd.cross(Vector3.UP)]
	if not history_free:
		_select_with_fades(t, eye)
		_wave_rec = _wave_clouds(eye)
		last_rebuild_us = Time.get_ticks_usec() - t0
		return
	_sync_history(floori(t / _interval))
	var cnt := _cnt
	var ths: Dictionary = atmo.field.thermals
	var e2 := Vector2(eye.x, eye.z)
	var cand: Array = []
	for id in cnt:
		var th: AtmoThermal = ths.get(id)
		if th == null or model.stage(th, t).x < 0.0:
			continue
		var c := model.center(th, t)
		var d := e2.distance_to(c)
		if d > model.far_m(th):
			continue
		var f := float(cnt[id]) / float(_win_n)
		cand.append([d, id, f, f * model.life_fade(th, t) * _range_vis(th, t, c, eye)])
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
			_slot_th[s] = ths[id]
			_sel[s] = v
			if not _rec[s].is_empty():
				_rec[s][20] = _base_vis[s] * v
			continue
		var slot: int = _free.pop_back() if not _free.is_empty() else _add_slot()
		_slot_th[slot] = ths[id]
		_slot_of[id] = slot
		_sel[slot] = v
		_place(slot, t, eye)
	_wave_rec = _wave_clouds(eye)
	last_rebuild_us = Time.get_ticks_usec() - t0


## Одиночная игра: нарисованные (не тающие) облака в приоритете при наложении и обрезке по
## лимиту (гистерезис); выбывшее тает (_update_fades), слот освобождается при нуле.
func _select_with_fades(t: float, eye: Vector3) -> void:
	var shown: Dictionary = {}
	for id in _slot_of:
		if _want[_slot_of[id]] == 1:
			shown[id] = true
	var list := model.select(atmo.field.thermals, t, eye, shown)
	var keep: Dictionary = {}
	for e: Array in list:
		keep[(e[1] as AtmoThermal).id] = e[1]
	for id in _slot_of.keys():
		if not keep.has(id):
			if _instant:
				_release(_slot_of[id])
			else:
				_want[_slot_of[id]] = 0
	for id in keep:
		if _slot_of.has(id):
			_want[_slot_of[id]] = 1
			continue
		var slot: int = _free.pop_back() if not _free.is_empty() else _add_slot()
		_slot_th[slot] = keep[id]
		_slot_of[id] = slot
		_want[slot] = 1
		_sel[slot] = 1.0 if _instant else 0.0
		_place(slot, t, eye)
	_instant = false


## Одиночная игра: выбранные облака проявляются, выбывшие тают (время атмосферы); растаявшее
## освобождает слот.
func _update_fades(dt: float) -> void:
	for i in _slot_th.size():
		if _slot_th[i] == null:
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
			var won := model.merge_winners(atmo.field.thermals, kk * _interval, _win_n * _interval)
			_hist[kk] = won
			for id in won:
				_cnt[id] = int(_cnt.get(id, 0)) + 1
	_last_k = k


func _release(slot: int) -> void:
	var th: AtmoThermal = _slot_th[slot]
	if th != null:
		_slot_of.erase(th.id)
	_slot_th[slot] = null
	_want[slot] = 0
	_sel[slot] = 0.0
	_drifting.erase(slot)
	_rec[slot] = PackedFloat32Array()
	_free.append(slot)


## Обновить форму и стадию части облаков за кадр (по кругу) — без пиков нагрузки.
func _update_some(t: float, eye: Vector3) -> void:
	var n := _slot_th.size()
	if n == 0:
		return
	var per_frame := ceili(float(n) / maxf(float(cfg.update_spread_frames), 1.0))
	for k in per_frame:
		_next_slot = (_next_slot + 1) % n
		if _slot_th[_next_slot] != null:
			_place(_next_slot, t, eye)


func _add_slot() -> int:
	_rec.append(PackedFloat32Array())
	_slot_th.append(null)
	_sel.append(0.0)
	_want.append(0)
	_base_vis.append(0.0)
	return _slot_th.size() - 1


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
	var th: AtmoThermal = _slot_th[i]
	var st := model.stage(th, t)
	if st.x < 0.0:
		_release(i)
		return
	var c := model.center(th, t)
	var axes := _basis_axes
	if st.y > 0.0 or (not th.is_static and t > th.drift_start()):
		_drifting[i] = th
	var sz4 := model.size(th, st)
	var base := th.top
	var anvil := 0.0
	var rain := 0.0
	var scfg: Dictionary = atmo.cfg.storm
	if th.is_cb:
		# Наковальня растёт к началу бури, осадки — во время бури.
		var s0 := atmo.storm.storm_start(th)
		anvil = smoothstep(s0 - 900.0, s0 + 600.0, t)
		rain = atmo.storm.intensity(th, t)
	var below := 10.0 + (float(scfg.virga_depth_m) if rain > 0.0 else 0.0)
	var anvil_pad := float(scfg.anvil_spread) + float(scfg.anvil_shift)
	var vis := model.life_fade(th, t) * _range_vis(th, t, c, eye)
	_base_vis[i] = vis
	_rec[i] = make_record(
		c, axes[0], base, sz4.z, sz4.x, sz4.y,
		Vector4(st.x, st.y, st.z, float(th.noise_seed % 9973)),
		Vector4(sz4.w, anvil, rain, 3.0 if th.is_cb else 0.0), anvil_pad, below, vis * _sel[i]
	)


## Видимость по дальности: облако тает к max_distance_m (от камеры) и к радиусу, где живут
## термики (от пилота, по основанию столба — как ThermalField удаляет), а не срезается.
func _range_vis(th: AtmoThermal, t: float, c: Vector2, eye: Vector3) -> float:
	var v := model.range_fade(Vector2(eye.x, eye.z).distance_to(c), model.far_m(th))
	if not th.is_static:
		var f := atmo.get_focus()
		var sd := th.drift_at(t)
		var src := Vector2(th.src.x + sd.x, th.src.z + sd.y)
		v = minf(v, model.range_fade(Vector2(f.x, f.z).distance_to(src), _gen_r))
	return v


## Облака уплывают по ветру вместе с термиками — двигаем их каждый кадр, чтобы не дёргались.
func _update_drift(t: float) -> void:
	for i in _drifting:
		var th: AtmoThermal = _drifting[i]
		var c := model.center(th, t)
		if not _rec[i].is_empty():
			_rec[i][0] = c.x
			_rec[i][2] = c.y


## Облака волны (VR-27) — строго из поля смещения линий тока: лентикулярные в гребнях волн,
## шапка на самой высокой точке рельефа против ветра, роторные клочья под первым гребнем.
func _wave_clouds(eye: Vector3) -> Array[PackedFloat32Array]:
	var out: Array[PackedFloat32Array] = []
	var wf := atmo.wave
	if wf == null or not wf.enabled:
		return out
	var w: Dictionary = atmo.cfg.wave
	var ax: Vector3 = _basis_axes[0]
	var crests := wf.crests(
		eye, float(w.lens_radius_m), float(w.lens_min_eta_m), float(w.lens_length_m[1]) * 0.9
	)
	var lam := wf.wavelength()
	var above := float(atmo.weather.get("lens_level_above_crest_m", 2000.0))
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


## Самая высокая точка рельефа рядом (для шапки): Vector3(x, z, высота) или z < 0.
func _highest_ground(eye: Vector3, radius: float) -> Vector3:
	if not atmo.ground.has_ground:
		return Vector3(0, 0, -1)
	var best := Vector3(0, 0, -1.0e9)
	var step := radius / 10.0
	for j in range(-10, 11):
		for i in range(-10, 11):
			var x := eye.x + i * step
			var z := eye.z + j * step
			var h := atmo.ground.height(x, z)
			if h > best.z:
				best = Vector3(x, z, h)
	return best
