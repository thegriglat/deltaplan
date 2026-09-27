class_name CloudLayer
extends Node3D
## Кучевые облака над термиками: по одному объёмному боксу (raymarch-шейдер) на облако
## и пятно тени на земле (Decal). Стадия облака — из жизненного цикла его термика:
## рост → зрелость (плотное, чёткие клубы, тёмное плоское основание) →
## распад (рваное, тает, уплывает).
## Никаких других визуальных признаков термиков (FR-22).

var atmo: Atmosphere
var cfg: Dictionary
## Время последней пересборки облаков (CPU), мкс — для замеров.
var last_rebuild_us: int = 0
## Логика: стадии, размеры, выбор видимых облаков.
var model: CloudModel = CloudModel.new()

var _material: ShaderMaterial
var _box: BoxMesh
var _pool: Array[MeshInstance3D] = []
var _shadows: Array[Decal] = []
var _shadow_tex: Texture2D
## Слоты пула: какой термик в слоте (null — свободен), id термика -> слот, свободные слоты.
var _slot_th: Array = []
var _slot_of: Dictionary = {}
var _free: Array[int] = []
## Распадающиеся облака (слот -> термик) — их снос обновляется каждый кадр.
var _drifting: Dictionary = {}
var _next_slot: int = 0
var _basis_axes: Array = [Vector3.RIGHT, Vector3.UP, Vector3.BACK]

var _acc: float = 1.0e9
var _light_acc: float = 1.0e9
var _sun: DirectionalLight3D
var _sun_dir: Vector3 = Vector3.UP
var _wind_offset: Vector3 = Vector3.ZERO
var _boil: float = 0.0


func setup(atmosphere: Atmosphere) -> void:
	atmo = atmosphere
	cfg = atmo.cfg.clouds
	model.setup(cfg)
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
		"lod_distance_m": "lod_distance_m",
		"ambient_energy": "ambient_energy",
	}
	for u in params:
		_material.set_shader_parameter(u, float(cfg[params[u]]))
	set_quality(String(cfg.quality))
	_material.set_shader_parameter("shape_tex_size", float(cfg.noise_shape_size))
	_material.set_shader_parameter("detail_tex_size", float(cfg.noise_detail_size))
	_material.set_shader_parameter("ambient_top", _color(cfg.ambient_top))
	_material.set_shader_parameter("ambient_bottom", _color(cfg.ambient_bottom))
	_box = BoxMesh.new()
	_box.size = Vector3.ONE
	if bool(cfg.shadows):
		_shadow_tex = _make_shadow_texture(int(cfg.shadow_texture_size))
	_update_light()


## Качество: "low" | "medium" | "high" (configs/atmosphere.json → clouds.quality_presets).
func set_quality(q: String) -> void:
	var presets: Dictionary = cfg.quality_presets
	var p: Dictionary = presets.get(q, presets.medium)
	for u in ["coarse_steps", "max_iterations", "light_steps"]:
		_material.set_shader_parameter(u, int(p[u]))
	for u in ["fine_step_per_m", "fine_step_min_m"]:
		_material.set_shader_parameter(u, float(p[u]))
	_material.set_shader_parameter("detail_enabled", bool(p.detail))


## Текстуры шума генерируются в фоне; до готовности облака гладкие.
func textures_ready() -> bool:
	for u in ["noise_shape", "noise_detail"]:
		var t: Texture3D = _material.get_shader_parameter(u)
		if t == null or (t is NoiseTexture3D and t.get_data().is_empty()):
			return false
	return true


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


## Пятно тени: мягкий край с рваной кромкой.
func _make_shadow_texture(size: int) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var n := FastNoiseLite.new()
	n.seed = int(atmo.cfg.seed) + 5
	n.frequency = 4.0 / size
	for y in size:
		for x in size:
			var u := (x + 0.5) / size * 2.0 - 1.0
			var v := (y + 0.5) / size * 2.0 - 1.0
			var r := sqrt(u * u + v * v) + n.get_noise_2d(x, y) * 0.25
			var a := 1.0 - smoothstep(0.45, 0.95, r)
			img.set_pixel(x, y, Color(0, 0, 0, a))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


func _process(delta: float) -> void:
	if atmo == null:
		return
	var t := atmo.time_s
	# Шум облаков «течёт» с ветром на кромке: форма стоит над термиком, клубы плывут.
	var cb_agl := maxf(atmo.field.cloudbase_msl - atmo._ground_ref, 100.0)
	var w := atmo.wind.vec2_at(cb_agl) * float(cfg.noise_wind_factor)
	_wind_offset = -Vector3(w.x, 0.0, w.y) * t
	_boil = t * float(cfg.boil_speed)
	_material.set_shader_parameter("wind_offset", _wind_offset)
	_material.set_shader_parameter("boil", _boil)
	_light_acc += delta
	if _light_acc > 1.0:
		_light_acc = 0.0
		_update_light()
	var cam := get_viewport().get_camera_3d()
	var eye := cam.global_position if cam != null else atmo.get_focus()
	_acc += delta
	if _acc >= float(cfg.update_interval_s):
		_acc = 0.0
		_select(t, eye)
	_update_some(t, eye)
	_update_drift(t)


## Солнце и дымка — из сцены (DirectionalLight3D, WorldEnvironment), иначе из конфига.
func _update_light() -> void:
	if _sun == null or not is_instance_valid(_sun):
		_sun = _find_light(get_tree().root) if is_inside_tree() else null
	var color := Color(1, 0.97, 0.92)
	var energy := 1.3
	if _sun != null:
		_sun_dir = _sun.global_transform.basis.z.normalized()
		color = _sun.light_color
		energy = _sun.light_energy
	else:
		var el := deg_to_rad(float(cfg.sun_elevation_deg))
		var az := deg_to_rad(float(cfg.sun_azimuth_deg))
		_sun_dir = Vector3(sin(az) * cos(el), sin(el), -cos(az) * cos(el))
	_material.set_shader_parameter("sun_dir", _sun_dir)
	_material.set_shader_parameter("sun_color", Vector3(color.r, color.g, color.b))
	_material.set_shader_parameter("sun_energy", energy)
	var env: Environment = (
		get_world_3d().environment if is_inside_tree() and get_world_3d() != null else null
	)
	if env != null and env.fog_enabled:
		var fc := env.fog_light_color * env.fog_light_energy
		_material.set_shader_parameter("fog_color", Vector3(fc.r, fc.g, fc.b))
		_material.set_shader_parameter("fog_density", env.fog_density)
		_material.set_shader_parameter("fog_sun_scatter", env.fog_sun_scatter)
	else:
		var fc2 := _color(cfg.fog_color_fallback)
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


## Выбрать видимые облака и раздать им слоты (облако остаётся в своём слоте, пока видно).
func _select(t: float, eye: Vector3) -> void:
	var t0 := Time.get_ticks_usec()
	var list := model.select(atmo.field.thermals, t, eye)
	var keep: Dictionary = {}
	for e: Array in list:
		keep[(e[1] as AtmoThermal).id] = e[1]
	for id in _slot_of.keys():
		if not keep.has(id):
			_release(_slot_of[id])
	for id in keep:
		if _slot_of.has(id):
			continue
		var slot: int = _free.pop_back() if not _free.is_empty() else _add_slot()
		_slot_th[slot] = keep[id]
		_slot_of[id] = slot
		_place(slot, t, eye)
	var wd := atmo.wind.dir
	if wd.length_squared() < 1.0e-6:
		wd = Vector3(1, 0, 0)
	_basis_axes = [wd, Vector3.UP, wd.cross(Vector3.UP)]
	last_rebuild_us = Time.get_ticks_usec() - t0


func _release(slot: int) -> void:
	var th: AtmoThermal = _slot_th[slot]
	if th != null:
		_slot_of.erase(th.id)
	_slot_th[slot] = null
	_drifting.erase(slot)
	_pool[slot].visible = false
	if slot < _shadows.size():
		_shadows[slot].visible = false
	_free.append(slot)


## Обновить форму и стадию части облаков за кадр (по кругу) — без пиков нагрузки.
func _update_some(t: float, eye: Vector3) -> void:
	var n := _pool.size()
	if n == 0:
		return
	var per_frame := ceili(float(n) / maxf(float(cfg.update_spread_frames), 1.0))
	for k in per_frame:
		_next_slot = (_next_slot + 1) % n
		if _slot_th[_next_slot] != null:
			_place(_next_slot, t, eye)


func _add_slot() -> int:
	var mi := MeshInstance3D.new()
	mi.mesh = _box
	mi.material_override = _material
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	add_child(mi)
	_pool.append(mi)
	if _shadow_tex != null:
		var dc := Decal.new()
		dc.texture_albedo = _shadow_tex
		dc.albedo_mix = 1.0
		dc.upper_fade = 0.05
		dc.lower_fade = 0.05
		dc.distance_fade_enabled = true
		dc.distance_fade_begin = float(cfg.shadow_distance_m) * 0.8
		dc.distance_fade_length = float(cfg.shadow_distance_m) * 0.2
		add_child(dc)
		_shadows.append(dc)
	_slot_th.append(null)
	return _pool.size() - 1


func _place(i: int, t: float, eye: Vector3) -> void:
	var th: AtmoThermal = _slot_th[i]
	var st := model.stage(th, t)
	if st.x < 0.0:
		_release(i)
		return
	var c := model.center(th, t)
	var axes := _basis_axes
	if st.y > 0.0:
		_drifting[i] = th
	var g := st.x
	var dcy := st.y
	var sz4 := model.size(th, st)
	var rx := sz4.x
	var rz := sz4.y
	var h := sz4.z
	var spread := sz4.w
	var base := th.top
	var mi := _pool[i]
	mi.visible = true
	# Бокс с запасом: контур шумит, верх переразвитого растекается.
	var pad := 1.45 + spread * 0.8
	var sy := h * 1.4 + 20.0
	var sx := 2.0 * rx * pad
	var sz := 2.0 * rz * pad
	var b := Basis(axes[0] * sx, axes[1] * sy, axes[2] * sz)
	mi.transform = Transform3D(b, Vector3(c.x, base - 10.0 + sy * 0.5, c.y))
	mi.set_instance_shader_parameter("cloud_shape", Vector4(base, h, rx, rz))
	mi.set_instance_shader_parameter(
		"cloud_state", Vector4(g, dcy, st.z, float(th.noise_seed % 9973))
	)
	mi.set_instance_shader_parameter("cloud_extra", Vector4(spread, 0, 0, 0))
	if i < _shadows.size():
		var dc := _shadows[i]
		var dist := Vector2(eye.x, eye.z).distance_to(c)
		if dist > float(cfg.shadow_distance_m) or _sun_dir.y < 0.05:
			dc.visible = false
			return
		dc.visible = true
		# Тень смещена от облака против солнца на (высота над землёй / tg высоты солнца).
		var gh := atmo.ground.height(c.x, c.y)
		var k := (base - gh) / _sun_dir.y
		var sp := Vector2(c.x - _sun_dir.x * k, c.y - _sun_dir.z * k)
		var gs := atmo.ground.height(sp.x, sp.y)
		k = (base - gs) / _sun_dir.y
		sp = Vector2(c.x - _sun_dir.x * k, c.y - _sun_dir.z * k)
		var depth := maxf(base - gs, 400.0)
		dc.size = Vector3(2.0 * rx * 1.1, depth, 2.0 * rz * 1.1)
		dc.transform = Transform3D(Basis(axes[0], axes[1], axes[2]), Vector3(sp.x, gs, sp.y))
		dc.modulate = Color(
			1, 1, 1, float(cfg.shadow_opacity) * g * (1.0 - dcy) * clampf(h / 300.0, 0.3, 1.0)
		)


## Распадающиеся облака уплывают по ветру — двигаем их каждый кадр, чтобы не дёргались.
func _update_drift(t: float) -> void:
	for i in _drifting:
		var th: AtmoThermal = _drifting[i]
		var c := model.center(th, t)
		var mi := _pool[i]
		mi.position = Vector3(c.x, mi.position.y, c.y)
