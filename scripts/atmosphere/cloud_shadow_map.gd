class_name CloudShadowMap
extends Node
## Тени облаков на земле (VR-2): карта пропускания прямого солнца сквозь облака вокруг пилота.
## Рисуется в маленьком SubViewport (только 2D): квад на облако, шейдер
## cloud_shadow_map.gdshader проходит луч к солнцу сквозь ТУ ЖЕ плотность, что рисуется
## (cloud_common.gdshaderinc) — тень повторяет форму облака, плывёт с ним, тает вместе с ним.
## Карта и её привязка к миру — глобальные параметры шейдеров (project.godot → [shader_globals]);
## рельеф, трава, лес, кусты, камни гасят ею только прямое солнце (scripts/terrain/
## cloud_shadow.gdshaderinc). Слой поля облачности (CLF-5) — квад во всю карту тем же шейдером
## (field_pass), той же плотностью; без облаков в поле квад скрыт. Настройки — configs/atmosphere.json → clouds.shadow_*.

## Время последней перерисовки карты на CPU (выбор облаков, данные), мкс — для замеров.
var last_update_us: int = 0

var _layer: CloudLayer
var _cfg: Dictionary
var _vp: SubViewport
var _mat: ShaderMaterial
## Слой поля: квад во всю карту и его материал (тот же шейдер, field_pass).
var _field_rect: ColorRect
var _field_mat: ShaderMaterial
var _mm: MultiMesh
var _data_tex: ImageTexture
var _data_rows: int = 0
var _uniforms: PackedStringArray = []
var _size_m: float = 24000.0
var _frames: int = 0
var _interval: int = 2


func setup(layer: CloudLayer, cloud_material: ShaderMaterial) -> void:
	_layer = layer
	_cfg = layer.cfg
	_size_m = float(_cfg.shadow_map_size_m)
	_interval = maxi(int(_cfg.shadow_map_interval_frames), 1)
	_mat = ShaderMaterial.new()
	_mat.shader = load("res://scripts/atmosphere/cloud_shadow_map.gdshader")
	# Общие с облаками параметры (шум, ветер, форма) — по именам uniform облаков.
	for u: Dictionary in cloud_material.shader.get_shader_uniform_list():
		_uniforms.append(String(u.name))
	_vp = SubViewport.new()
	_vp.disable_3d = true
	_vp.transparent_bg = false
	_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	var bg := ColorRect.new()
	bg.color = Color.WHITE
	_vp.add_child(bg)
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_2D
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	_mm.mesh = quad
	var mmi := MultiMeshInstance2D.new()
	mmi.multimesh = _mm
	mmi.material = _mat
	_vp.add_child(mmi)
	_field_mat = ShaderMaterial.new()
	_field_mat.shader = _mat.shader
	_field_mat.set_shader_parameter("field_pass", true)
	_field_rect = ColorRect.new()
	_field_rect.material = _field_mat
	_field_rect.visible = false
	_vp.add_child(_field_rect)
	add_child(_vp)
	set_quality(String(_cfg.quality))
	RenderingServer.global_shader_parameter_set("cloud_shadow_map", _vp.get_texture())


## Разрешение карты и шаги луча — из clouds.quality_presets.
func set_quality(q: String) -> void:
	var presets: Dictionary = _cfg.quality_presets
	var p: Dictionary = presets.get(q, presets.medium)
	var px := int(p.shadow_map_px)
	_vp.size = Vector2i(px, px)
	(_vp.get_child(0) as ColorRect).size = Vector2(px, px)
	_field_rect.size = Vector2(px, px)
	_mat.set_shader_parameter("shadow_steps", int(p.shadow_steps))
	_field_mat.set_shader_parameter("shadow_steps", int(p.shadow_steps))
	_frames = 0


func _exit_tree() -> void:
	RenderingServer.global_shader_parameter_set("cloud_shadow_rect", Vector4.ZERO)


## Перерисовать карту вокруг eye (раз в shadow_map_interval_frames кадров).
func update(eye: Vector3, sun_dir: Vector3, cloud_material: ShaderMaterial) -> void:
	_frames -= 1
	if _frames > 0:
		return
	_frames = _interval
	var t0 := Time.get_ticks_usec()
	var atmo := _layer.atmo
	if sun_dir.y < 0.05:
		RenderingServer.global_shader_parameter_set("cloud_shadow_rect", Vector4.ZERO)
		return
	var px := _vp.size.x
	var m_px := _size_m / px
	# Опорная плоскость — земля под пилотом; угол карты — по пикселям (тень не «плавает»).
	var plane := atmo.ground.height(eye.x, eye.z) if atmo.ground.has_ground else atmo._ground_ref
	var x0 := floorf((eye.x - _size_m * 0.5) / m_px) * m_px
	var z0 := floorf((eye.z - _size_m * 0.5) / m_px) * m_px
	var s := Vector2(sun_dir.x, sun_dir.z) / sun_dir.y
	var data := PackedFloat32Array()
	var n := 0
	var lim := Rect2(x0, z0, _size_m, _size_m)
	for g in _layer.records():
		if g[20] <= 0.001:
			continue
		var c := Vector2(g[0], g[2]) - s * (g[1] - plane)
		var r := Vector2(g[6], g[7]).length() + s.length() * g[3]
		if not lim.grow(r).has_point(c):
			continue
		data.append_array(g)
		n += 1
	var rows := maxi(64, nearest_po2(maxi(n, 1)))
	if _mm.instance_count < rows:
		_mm.instance_count = rows
		for i in rows:
			_mm.set_instance_transform_2d(i, Transform2D.IDENTITY)
	_mm.visible_instance_count = n
	data.resize(rows * CloudLayer.FLOATS_PER_CLOUD)
	var img := Image.create_from_data(6, rows, false, Image.FORMAT_RGBAF, data.to_byte_array())
	if _data_tex == null or _data_rows != rows:
		_data_tex = ImageTexture.create_from_image(img)
		_data_rows = rows
		_mat.set_shader_parameter("cloud_data", _data_tex)
	else:
		_data_tex.update(img)
	for u in _uniforms:
		if u != "cloud_data" and u != "depth_tex":
			var v: Variant = cloud_material.get_shader_parameter(u)
			_mat.set_shader_parameter(u, v)
			_field_mat.set_shader_parameter(u, v)
	_mat.set_shader_parameter("map_rect", Vector4(x0, z0, m_px, plane))
	_update_field(Vector4(x0, z0, m_px, plane))
	_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	# Под перистой пеленой тени бледнее (больше рассеянного света).
	var cover := clampf(float(atmo.weather.get("cirrus_cover", 0.0)), 0.0, 1.0)
	var soft := float(atmo.cfg.cirrus.shadow_softening)
	var strength := float(_cfg.shadow_strength) * (1.0 - soft * cover)
	RenderingServer.global_shader_parameter_set(
		"cloud_shadow_rect", Vector4(x0, z0, 1.0 / _size_m, strength)
	)
	RenderingServer.global_shader_parameter_set(
		"cloud_shadow_sky", float(_cfg.shadow_sky) * strength
	)
	RenderingServer.global_shader_parameter_set(
		"cloud_shadow_sun", Vector4(s.x, s.y, plane, float(_cfg.shadow_edge_fade))
	)
	last_update_us = Time.get_ticks_usec() - t0


## Слой поля облачности: квад во всю карту, если в поле есть облака (параметры — CloudLayer).
func _update_field(map_rect: Vector4) -> void:
	var fp: Dictionary = _layer.field_params
	var on := float(fp.get("cf_on", 0.0)) > 0.5 and _layer.field_tex != null
	_field_rect.visible = on
	if not on:
		return
	for k: String in fp:
		if k != "cf_on":
			_field_mat.set_shader_parameter(k, fp[k])
	_field_mat.set_shader_parameter("cf_tex", _layer.field_tex)
	_field_mat.set_shader_parameter("cf_tex_prev", _layer.field_tex_prev)
	_field_mat.set_shader_parameter("cf_max", _layer.field_max_tex)
	_field_mat.set_shader_parameter("map_rect", map_rect)
