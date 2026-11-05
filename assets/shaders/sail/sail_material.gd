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


## Индексы вершин обшивки меша Sail: top — верх (UV.y > 0,5), иначе низ (UV.y < 0,5). Обшивку определяют
## треугольники: вершины на шве v = 0,5 (задняя кромка верха, передняя кромка низа) принадлежат своей обшивке.
## Карман киля (|нормаль.x| > 0,7) не входит.
static func skin_indices(mesh: Mesh, top: bool) -> PackedInt32Array:
	var out := PackedInt32Array()
	if mesh == null or mesh.get_surface_count() == 0:
		return out
	var arr := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var uvs: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV]
	var nrm: PackedVector3Array = arr[Mesh.ARRAY_NORMAL] if arr[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
	if verts.is_empty() or uvs.size() != verts.size():
		return out
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	if idx.is_empty():
		idx.resize(verts.size())
		for i in verts.size():
			idx[i] = i
	var mark := PackedByteArray()
	mark.resize(verts.size())
	for t in range(0, idx.size() - 2, 3):
		var vmin := minf(uvs[idx[t]].y, minf(uvs[idx[t + 1]].y, uvs[idx[t + 2]].y))
		var vmax := maxf(uvs[idx[t]].y, maxf(uvs[idx[t + 1]].y, uvs[idx[t + 2]].y))
		var is_top := vmin >= 0.5 - 1e-4 and vmax > 0.5 + 1e-4
		var is_bottom := vmax <= 0.5 + 1e-4 and vmin < 0.5 - 1e-4
		if (top and is_top) or (not top and is_bottom):
			for k in 3:
				mark[idx[t + k]] = 1
	for i in verts.size():
		if mark[i] == 1 and not (nrm.size() == verts.size() and absf(nrm[i].x) > 0.7):
			out.append(i)
	return out


## Аспекты обшивок (размах / наибольшая хорда обшивки, м/м) по вершинам меша Sail: Vector2(верх, низ).
## Хорда — наибольший по размаху диапазон z вершин в полосе по x шириной 3 % полуразмаха (К2 v3). Нет данных — 4 (типичное значение).
static func _skin_aspects(mesh: Mesh) -> Vector2:
	var out := Vector2(4.0, 4.0)
	if mesh == null or mesh.get_surface_count() == 0:
		return out
	var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	for skin in 2:
		var ids := skin_indices(mesh, skin == 0)
		var xmin := INF
		var xmax := -INF
		for i in ids:
			xmin = minf(xmin, verts[i].x)
			xmax = maxf(xmax, verts[i].x)
		if xmax <= xmin:
			continue
		# хорда — диапазон z вершин в полосе по x шириной 3 % полуразмаха; берём наибольшую (SLT-К2 v3)
		var half := 0.5 * (xmax - xmin)
		var w := 0.03 * half
		var nb := int(ceil((xmax - xmin) / w)) + 1
		var zlo := PackedFloat32Array()
		var zhi := PackedFloat32Array()
		zlo.resize(nb)
		zhi.resize(nb)
		zlo.fill(INF)
		zhi.fill(-INF)
		for i in ids:
			var k := int((verts[i].x - xmin) / w)
			zlo[k] = minf(zlo[k], verts[i].z)
			zhi[k] = maxf(zhi[k], verts[i].z)
		var chord := 0.0
		for k in nb:
			if zhi[k] > zlo[k]:
				chord = maxf(chord, zhi[k] - zlo[k])
		if chord > 0.0:
			out[skin] = (xmax - xmin) / chord
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
