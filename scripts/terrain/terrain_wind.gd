class_name TerrainWind
extends Node
## Ветер для визуала земли (VR-17, VR-0): раз в update_interval_s берёт у атмосферы средний ветер
## у земли под камерой и ближайшие термики и передаёт их шейдерам рельефа, травы и деревьев
## (terrain_wind.gdshaderinc). Источники задаёт Terrain.set_wind_sources(); без них ветра нет.
## Параметры — configs/world.json → wind_visual.

const MAX_THERMALS := 8

## (pos: Vector3) -> Vector3 — средний ветер, м/с (Atmosphere.mean_wind_at).
var mean_wind_fn: Callable
## (pos: Vector3, radius: float) -> Array[Dictionary] — термики рядом (Atmosphere.thermals_near).
var thermals_fn: Callable
## (pos: Vector3) -> Vector3 — мгновенная скорость воздуха (Atmosphere.air_velocity_at),
## необязательный: без него порывистость (gust_ms) остаётся 0 — поведение как до T05.
var air_fn: Callable
## (x, z) -> высота земли.
var ground_fn: Callable
## Источник поля воздуха (AM-10, WF-10): сам Atmosphere (duck typing — has_method
## is_air_field_on, свойство air_field: AirFieldSet с sample(pos, ground_h) -> Vector4);
## null — травы берёт только средний ветер камеры, как раньше (WF-04/05 не подключены).
var field_src: Object = null
var camera: Camera3D
var materials: Array[ShaderMaterial] = []
## Последние переданные значения (для тестов/отладки).
var wind: Vector2 = Vector2.ZERO
var thermals: Array[Vector4] = []
## Накопленное на CPU смещение рисунка порывов (offset += wind · dt, T05) — заменяет TIME · wind
## в шейдере, чтобы смена направления ветра не «прыгала» рисунком.
var offset: Vector2 = Vector2.ZERO
## Порывистость |air_velocity_at − mean_wind_at| у земли, сглаженная экспонентой (gust_tau_s).
var gust_ms: float = 0.0
## 2D-текстура горизонтального ветра нижнего слоя поля (RG16F/RGF) вокруг камеры (WF-10),
## для последних переданных материалам значений (тесты/отладка).
var field_tex: ImageTexture
var field_origin: Vector2 = Vector2.ZERO
var field_size_m: float = 0.0

var _cfg: Dictionary = {}
var _timer: float = 1e9
var _field_timer: float = 1e9


func setup(cfg: Dictionary) -> void:
	_cfg = cfg
	_timer = 1e9


## Добавить материалы и сразу передать им постоянные параметры.
func add_materials(list: Array) -> void:
	for m: ShaderMaterial in list:
		if m == null or materials.has(m):
			continue
		materials.append(m)
		for key in [
			"wind_gust_scale_m",
			"wind_gust_speed_k",
			"wind_wave_len_m",
			"wind_full_ms",
			"wind_shade",
			"wind_bend",
			"wind_fade_m",
			"thermal_reach",
			"thermal_ring_m",
			"thermal_arms",
			"thermal_inflow_hz",
			"thermal_gain",
			"gust_full_ms",
			"gust_gain",
			"wind_far_gust_m",
			"wind_far_wave_m",
			"wind_far_shade",
			"wind_far_silver",
			"wind_far_fade_m",
			"wind_far_morph_k",
		]:
			if _cfg.has(key):
				m.set_shader_parameter(key, float(_cfg[key]))
		m.set_shader_parameter("wind_offset", offset)
		m.set_shader_parameter("wind_gust_ms", gust_ms)
		m.set_shader_parameter("field_wind_size_m", field_size_m)
		if field_tex != null:
			m.set_shader_parameter("field_wind_tex", field_tex)
			m.set_shader_parameter("field_wind_origin", field_origin)
	_timer = 1e9
	_field_timer = 1e9


func clear_materials() -> void:
	materials.clear()


func _process(delta: float) -> void:
	advance(delta)
	_timer += delta
	_field_timer += delta
	var due_wind := _timer >= float(_cfg.get("update_interval_s", 0.2))
	var due_field := field_src != null and _field_timer >= float(_cfg.get("field_tex_interval_s", 1.5))
	if not due_wind and not due_field:
		return
	var cam := camera if camera != null else get_viewport().get_camera_3d()
	if cam == null:
		return
	if due_wind:
		var dt := _timer
		_timer = 0.0
		update_at(cam.global_position, dt)
	if due_field:
		_field_timer = 0.0
		_update_field_texture(cam.global_position)


## Накопить смещение рисунка порывов на CPU (offset += wind · dt, T05) и передать шейдерам —
## каждый кадр, отдельно от редких запросов к атмосфере (update_at), чтобы бег пятен был плавным
## и не зависел от TIME (смена направления ветра не двигает рисунок задним числом).
func advance(delta: float) -> void:
	offset += wind * delta
	for m in materials:
		m.set_shader_parameter("wind_offset", offset)


## Взять ветер, термики и порывистость у атмосферы для точки p (обычно камера) и передать шейдерам.
## dt — время с прошлого вызова (для экспоненциального сглаживания порывистости), по умолчанию —
## update_interval_s из конфига.
func update_at(p: Vector3, dt: float = -1.0) -> void:
	if dt < 0.0:
		dt = float(_cfg.get("update_interval_s", 0.2))
	var g := float(ground_fn.call(p.x, p.z)) if ground_fn.is_valid() else 0.0
	var sample_pos := Vector3(p.x, g + float(_cfg.get("sample_agl_m", 10.0)), p.z)
	wind = Vector2.ZERO
	var w := Vector3.ZERO
	if mean_wind_fn.is_valid():
		w = mean_wind_fn.call(sample_pos)
		wind = Vector2(w.x, w.z)
	var gust_raw := 0.0
	if air_fn.is_valid():
		var air: Vector3 = air_fn.call(sample_pos)
		gust_raw = Vector2(air.x - w.x, air.z - w.z).length()
	var tau := maxf(float(_cfg.get("gust_tau_s", 3.0)), 0.05)
	gust_ms = lerpf(gust_ms, gust_raw, 1.0 - exp(-dt / tau))
	thermals = _collect_thermals(Vector3(p.x, g, p.z))
	var arr := thermals.duplicate()
	while arr.size() < MAX_THERMALS:
		arr.append(Vector4(1e9, 1e9, 1.0, 0.0))
	for m in materials:
		m.set_shader_parameter("wind_vec", wind)
		m.set_shader_parameter("wind_thermals", arr)
		m.set_shader_parameter("wind_thermal_count", thermals.size())
		m.set_shader_parameter("wind_gust_ms", gust_ms)


func _collect_thermals(p: Vector3) -> Array[Vector4]:
	var out: Array[Vector4] = []
	if not thermals_fn.is_valid():
		return out
	var radius := float(_cfg.get("thermal_search_radius_m", 2500.0))
	var norm := maxf(float(_cfg.get("thermal_norm_ms", 3.0)), 0.1)
	var list: Array = thermals_fn.call(p, radius)
	var items: Array[Vector4] = []
	for d: Dictionary in list:
		var c: Vector3 = d.get("ground_axis", d.get("source", Vector3.ZERO))
		var s := float(d.get("strength_ms", 0.0)) * float(d.get("envelope", 1.0)) / norm
		if s <= 0.01:
			continue
		items.append(Vector4(c.x, c.z, float(d.get("radius_m", 100.0)), clampf(s, 0.0, 1.0)))
	items.sort_custom(
		func(a: Vector4, b: Vector4) -> bool:
			return Vector2(a.x - p.x, a.y - p.z).length() < Vector2(b.x - p.x, b.y - p.z).length()
	)
	for k in mini(items.size(), MAX_THERMALS):
		out.append(items[k])
	return out


## Пересобрать текстуру ветра поля вокруг центра cam_pos (WF-10): нет поля — выключить (сброс
## field_wind_size_m → 0, шейдер берёт только wind_vec, как раньше); есть — сетка field_tex_res ×
## field_tex_res на field_tex_size_m метров, RG = (u, −v) = мировые (x, z) горизонтального ветра на sample_agl_m
## над рельефом (тот же канал AirFieldSet.sample, что видит пилот). Центр округлён до половины
## клетки текстуры — сетка не «плавает» между пересборками.
func _update_field_texture(cam_pos: Vector3) -> void:
	var on := field_src != null and field_src.has_method("is_air_field_on") and bool(
		field_src.call("is_air_field_on")
	)
	if not on:
		if field_size_m != 0.0:
			field_size_m = 0.0
			for m in materials:
				m.set_shader_parameter("field_wind_size_m", 0.0)
		return
	var af: Variant = field_src.get("air_field")
	if af == null or not af.has_method("sample"):
		return
	var res := maxi(int(_cfg.get("field_tex_res", 40)), 4)
	var size_m := maxf(float(_cfg.get("field_tex_size_m", 2400.0)), 100.0)
	var step := size_m / res
	var cx := roundf(cam_pos.x / step) * step - size_m * 0.5
	var cz := roundf(cam_pos.z / step) * step - size_m * 0.5
	var agl := float(_cfg.get("sample_agl_m", 10.0))
	var img := Image.create(res, res, false, Image.FORMAT_RGF)
	for j in res:
		var z := cz + (j + 0.5) * step
		for i in res:
			var x := cx + (i + 0.5) * step
			var g := float(ground_fn.call(x, z)) if ground_fn.is_valid() else 0.0
			var v: Vector4 = af.call("sample", Vector3(x, g + agl, z), g)
			img.set_pixel(i, j, Color(v.x, v.z, 0.0))
	if field_tex == null or field_tex.get_width() != res or field_tex.get_height() != res:
		field_tex = ImageTexture.create_from_image(img)
	else:
		field_tex.update(img)
	field_origin = Vector2(cx, cz)
	field_size_m = size_m
	for m in materials:
		m.set_shader_parameter("field_wind_tex", field_tex)
		m.set_shader_parameter("field_wind_origin", field_origin)
		m.set_shader_parameter("field_wind_size_m", field_size_m)
