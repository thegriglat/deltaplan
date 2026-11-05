class_name SailMaterial
extends RefCounted
## Материал паруса (docs/guide/models.md → «Шейдер паруса»). Подключение из визуала планера:
##   var mat := SailMaterial.apply(sail_mesh_instance, "glider_sport")   # один раз после загрузки
##   SailMaterial.set_flight(mat, airspeed_ms, stall_amount, turbulence)   # каждый кадр
## Раскраска берётся из исходного материала .glb, карты — assets/shaders/sail/<модель>_*.png,
## параметры — configs/sail.json (через Config). Нет файлов — остаётся исходный материал.

const SHADER_PATH := "res://assets/shaders/sail/sail.gdshader"
const DIR := "res://assets/shaders/sail/"


## Поставить ShaderMaterial паруса на меш Sail. model — имя модели крыла без .glb.
static func apply(sail: MeshInstance3D, model: String) -> ShaderMaterial:
	if sail == null or sail.mesh == null or not ResourceLoader.exists(SHADER_PATH):
		push_warning("SailMaterial: нет меша Sail или шейдера — исходный материал")
		return null
	var mat := ShaderMaterial.new()
	mat.shader = load(SHADER_PATH) as Shader
	var src := sail.mesh.surface_get_material(0) as BaseMaterial3D
	if src != null:
		mat.set_shader_parameter("albedo_tex", src.albedo_texture)
		mat.set_shader_parameter("albedo_tint", src.albedo_color)
	for map_name: String in ["normal", "trans"]:
		# Одинаковые карты разных крыльев хранятся одним файлом (sail_maps.json, tools/blender/sail_dedupe.py).
		var shared: String = str(_maps().get(model, {}).get(map_name, model))
		var path := DIR + "%s_%s.png" % [shared, map_name]
		if ResourceLoader.exists(path):
			mat.set_shader_parameter(map_name + "_tex", load(path))
		else:
			push_warning("SailMaterial: нет карты " + path)
	var params := _params()
	for key: String in params:
		var v: Variant = params[key]
		if v is Array:
			v = Vector3(float(v[0]), float(v[1]), float(v[2]))
		if key != "cast_shadows":
			mat.set_shader_parameter(key, v)
	# Парус отбрасывает тень на землю и пилота (VR-6); сам тени не принимает (shadows_disabled
	# в шейдере), поэтому своя тень не гасит просвечивание нижней обшивки.
	sail.cast_shadow = (GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			if bool(params.get("cast_shadows", true))
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	var asp := _skin_aspects(sail.mesh)
	mat.set_shader_parameter("custom_aspect_top", asp.x)
	mat.set_shader_parameter("custom_aspect_bottom", asp.y)
	sail.material_override = mat
	return mat


## Своя картинка паруса (SLT-К2): tex == null — родная текстура; mat == null — ничего.
## Вызывать только для паруса игрока (боты и чужие — родная).
static func set_custom(mat: ShaderMaterial, tex: Texture2D) -> void:
	if mat == null:
		return
	if tex == null or tex.get_width() <= 0 or tex.get_height() <= 0:
		mat.set_shader_parameter("custom_on", 0.0)
		return
	mat.set_shader_parameter("custom_tex", tex)
	mat.set_shader_parameter("custom_img_aspect", float(tex.get_width()) / float(tex.get_height()))
	mat.set_shader_parameter("custom_on", 1.0)


## Аспекты обшивок (размах / корневая хорда, м/м) по вершинам меша Sail: Vector2(верх, низ).
## Обшивка — по UV1 (верх v > 0,5); карман киля (|нормаль.x| > 0,7) не входит; корневая хорда — диапазон z
## вершин обшивки при |x| < 3 % полуразмаха. Нет данных — 4 (типичное значение).
static func _skin_aspects(mesh: Mesh) -> Vector2:
	var out := Vector2(4.0, 4.0)
	if mesh == null or mesh.get_surface_count() == 0:
		return out
	var arr := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var uvs: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV]
	var nrm: PackedVector3Array = arr[Mesh.ARRAY_NORMAL] if arr[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
	if verts.is_empty() or uvs.size() != verts.size():
		return out
	for skin in 2:
		var xmin := INF
		var xmax := -INF
		for i in verts.size():
			if (uvs[i].y > 0.5) != (skin == 0) or (nrm.size() == verts.size() and absf(nrm[i].x) > 0.7):
				continue
			xmin = minf(xmin, verts[i].x)
			xmax = maxf(xmax, verts[i].x)
		if xmax <= xmin:
			continue
		var half := 0.5 * (xmax - xmin)
		var cx := 0.5 * (xmax + xmin)
		var zmin := INF
		var zmax := -INF
		for i in verts.size():
			if (uvs[i].y > 0.5) != (skin == 0) or (nrm.size() == verts.size() and absf(nrm[i].x) > 0.7):
				continue
			if absf(verts[i].x - cx) < 0.03 * half:
				zmin = minf(zmin, verts[i].z)
				zmax = maxf(zmax, verts[i].z)
		if zmax > zmin:
			out[skin] = (xmax - xmin) / (zmax - zmin)
	return out


## Параметры полёта: воздушная скорость, м/с; сваливание 0..1; турбулентность 0..1.
static func set_flight(mat: ShaderMaterial, airspeed_ms: float, stall_amount: float,
		turbulence: float) -> void:
	if mat == null:
		return
	mat.set_shader_parameter("airspeed_ms", airspeed_ms)
	mat.set_shader_parameter("stall_amount", clampf(stall_amount, 0.0, 1.0))
	mat.set_shader_parameter("turbulence", clampf(turbulence, 0.0, 1.0))


static var _maps_cache: Dictionary = {}


static func _maps() -> Dictionary:
	if _maps_cache.is_empty():
		var f := FileAccess.open(DIR + "sail_maps.json", FileAccess.READ)
		if f != null:
			var d: Variant = JSON.parse_string(f.get_as_text())
			if d is Dictionary:
				_maps_cache = d
	return _maps_cache


static func _params() -> Dictionary:
	var out := {}
	var data: Dictionary = Config.get_config("sail")
	for key: String in data:
		if not key.begins_with("_") and not key.ends_with("_doc") and key != "turbulence_full_g":
			out[key] = data[key]
	return out
