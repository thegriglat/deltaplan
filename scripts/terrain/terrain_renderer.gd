class_name TerrainRenderer
extends Node3D
## Меш рельефа: каждый слой высот режется на квадратные чанки, у чанка несколько уровней
## детализации (LOD). Сетки LOD общие для всех чанков слоя (плоские), высоту вершинам даёт
## шейдер из текстуры высот — поэтому построение мгновенное, а памяти нужно мало.
## Щели между чанками разного LOD закрывает «юбка» (опущенный вниз край).
## Грубый слой не рисуется там, где его полностью перекрывает более детальный.

const SHADER := preload("res://scripts/terrain/terrain.gdshader")
## Текстура плавного шума для пятен лугов и волн ветра с высоты (macro_noise_tex): размер, пятно
## шума в текселях (шейдер считает масштаб из них — MACRO_NOISE_FEATURE там же).
const MACRO_NOISE_SIZE := 256
const MACRO_NOISE_FEATURE := 16.0

static var _macro_noise: ImageTexture
## Средние цвета текстур: путь ресурса (или RID) → Color (_average_color).
static var _avg_cache: Dictionary = {}

## Текстуры высот по слоям (для деревьев и др.).
var height_textures: Array[Texture2D] = []
## Текстуры карты поверхности по слоям (для деревьев).
var surface_textures: Array[Texture2D] = []
## Камера, по которой считается LOD. Если не задана — активная камера вьюпорта.
var lod_camera: Camera3D

## Чанки: {mi, aabb: AABB (мир), meshes: Array[Mesh], lods: PackedFloat32Array, lod: int}
var _chunks: Array[Dictionary] = []
var _update_interval_s: float = 0.1
var _timer: float = 0.0
var _materials: Array[ShaderMaterial] = []
## Материалы (все LOD) по слоям — для полей рельефа, пришедших после build.
var _layer_mats: Array[Array] = []


## Построить чанки. layers — от детального к грубому, surfaces — карта поверхности каждого слоя
## (тот же порядок). render_cfg — раздел "render" локации (по id слоя), look — terrain_look,
## world_render — раздел "rendering" из world.json; reliefs — поля рельефа слоёв (TerrainRelief,
## влажность/AO/горизонт к солнцу), пусто — без них.
func build(
	layers: Array[HeightLayer],
	surfaces: Array[SurfaceLayer],
	render_cfg: Dictionary,
	look: Dictionary,
	world_render: Dictionary,
	reliefs: Array[TerrainRelief] = []
) -> void:
	clear()
	_update_interval_s = float(world_render.get("lod_update_interval_s", 0.1))
	for li in layers.size():
		var layer: HeightLayer = layers[li]
		var rc: Dictionary = render_cfg.get(layer.id, {})
		if rc.is_empty():
			push_error("TerrainRenderer: нет раздела render.%s в конфиге локации" % layer.id)
			continue
		var cells := int(rc.chunk_cells)
		var lod_d := PackedFloat32Array(rc.lod_distances_m)
		var n_lod := lod_d.size() + 1
		var skirt := float(rc.skirt_depth_m)
		if (layer.width - 1) % cells != 0 or cells % (1 << (n_lod - 1)) != 0:
			push_error(
				(
					"TerrainRenderer: chunk_cells=%d не подходит слою %s (%d клеток, %d LOD)"
					% [cells, layer.id, layer.width - 1, n_lod]
				)
			)
			continue
		var mat := _make_material(layer, surfaces[li], skirt, look)
		set_relief(mat, reliefs[li] if li < reliefs.size() else null)
		if li > 0:
			var f: HeightLayer = layers[li - 1]
			mat.set_shader_parameter("hole_min", Vector2(f.origin_x, f.origin_z))
			mat.set_shader_parameter(
				"hole_max", Vector2(f.origin_x + f.size_x(), f.origin_z + f.size_z())
			)
		# материал на каждый LOD (шаг вершин — обычный uniform: instance uniform на сотнях чанков
		# переполняет буфер в Compatibility)
		var lod_mats: Array[ShaderMaterial] = []
		while _layer_mats.size() <= li:
			_layer_mats.append([])
		for lod in n_lod:
			var lm := mat if lod == 0 else mat.duplicate() as ShaderMaterial
			lm.set_shader_parameter("lod_stride", float(1 << lod))
			lod_mats.append(lm)
			_materials.append(lm)
			_layer_mats[li].append(lm)
		var meshes: Array[Mesh] = []
		for lod in n_lod:
			var step := 1 << lod
			meshes.append(_grid_mesh(cells / step, layer.spacing * step))
		var chunk_m := cells * layer.spacing
		var finer: Array[HeightLayer] = []
		for k in li:
			finer.append(layers[k])
		var cast := li == 0
		for cj in (layer.height - 1) / cells:
			for ci in (layer.width - 1) / cells:
				var x0 := layer.origin_x + ci * chunk_m
				var z0 := layer.origin_z + cj * chunk_m
				if _covered_by(finer, x0, z0, chunk_m):
					continue
				var hr := _chunk_height_range(layer, ci * cells, cj * cells, cells)
				var mi := MeshInstance3D.new()
				mi.name = "%s_%d_%d" % [layer.id, ci, cj]
				mi.mesh = meshes[n_lod - 1]
				mi.material_override = lod_mats[n_lod - 1]
				mi.position = Vector3(x0, 0.0, z0)
				mi.cast_shadow = (
					GeometryInstance3D.SHADOW_CASTING_SETTING_ON
					if cast
					else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				)
				mi.custom_aabb = AABB(
					Vector3(0.0, hr.x - skirt, 0.0), Vector3(chunk_m, hr.y - hr.x + skirt, chunk_m)
				)
				add_child(mi)
				(
					_chunks
					. append(
						{
							"mi": mi,
							"aabb":
							AABB(Vector3(x0, hr.x, z0), Vector3(chunk_m, hr.y - hr.x, chunk_m)),
							"meshes": meshes,
							"lods": lod_d,
							"lod": n_lod - 1,
							"mats": lod_mats,
						}
					)
				)
	update_lods(true)


func clear() -> void:
	for c in _chunks:
		(c.mi as Node).queue_free()
	_chunks.clear()
	_materials.clear()
	_layer_mats.clear()
	height_textures.clear()
	surface_textures.clear()


## Материалы рельефа (по слоям) — для передачи ветра (TerrainWind).
func materials() -> Array[ShaderMaterial]:
	return _materials


func chunk_count() -> int:
	return _chunks.size()


## Обновить параметры вида (terrain_look) без перестройки.
func apply_look(look: Dictionary) -> void:
	for m in _materials:
		_apply_look(m, look)


func _process(delta: float) -> void:
	_timer += delta
	if _timer >= _update_interval_s:
		_timer = 0.0
		update_lods(false)


## Выбрать LOD каждого чанка по расстоянию от камеры до его AABB.
func update_lods(force: bool) -> void:
	var cam := (
		lod_camera
		if lod_camera != null
		else get_viewport().get_camera_3d() if is_inside_tree() else null
	)
	if cam == null:
		return
	var p := cam.global_position if cam.is_inside_tree() else cam.position
	for c in _chunks:
		var box: AABB = c.aabb
		var q := Vector3(
			clampf(p.x, box.position.x, box.end.x),
			clampf(p.y, box.position.y, box.end.y),
			clampf(p.z, box.position.z, box.end.z)
		)
		var d := p.distance_to(q)
		var lods: PackedFloat32Array = c.lods
		var lod := lods.size()
		for k in lods.size():
			if d < lods[k]:
				lod = k
				break
		if lod != int(c.lod) or force:
			c.lod = lod
			var mi: MeshInstance3D = c.mi
			mi.mesh = c.meshes[lod]
			mi.material_override = c.mats[lod]


## Сколько чанков сейчас на каждом LOD (для отладки/тестов).
func lod_histogram() -> Dictionary:
	var h := {}
	for c in _chunks:
		h[c.lod] = int(h.get(c.lod, 0)) + 1
	return h


func _covered_by(finer: Array[HeightLayer], x0: float, z0: float, size: float) -> bool:
	for f in finer:
		if (
			x0 >= f.origin_x
			and z0 >= f.origin_z
			and x0 + size <= f.origin_x + f.size_x()
			and z0 + size <= f.origin_z + f.size_z()
		):
			return true
	return false


## Мин/макс высоты чанка по прореженной выборке + запас на пропущенные узлы.
func _chunk_height_range(layer: HeightLayer, i0: int, j0: int, cells: int) -> Vector2:
	var stride := maxi(1, cells / 16)
	var lo := INF
	var hi := -INF
	var j := j0
	while j <= j0 + cells:
		var i := i0
		while i <= i0 + cells:
			var v := layer.node(i, j)
			lo = minf(lo, v)
			hi = maxf(hi, v)
			i += stride
		j += stride
	var margin := (hi - lo) * 0.1 + layer.spacing
	return Vector2(lo - margin, hi + margin)


func _make_material(
	layer: HeightLayer, surface: SurfaceLayer, skirt: float, look: Dictionary
) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = SHADER
	var tex := layer.make_texture()
	height_textures.append(tex)
	m.set_shader_parameter("height_tex", tex)
	m.set_shader_parameter("layer_origin", Vector2(layer.origin_x, layer.origin_z))
	m.set_shader_parameter("layer_spacing", layer.spacing)
	m.set_shader_parameter("layer_texels", Vector2(layer.width, layer.height))
	m.set_shader_parameter("skirt_depth", skirt)
	var stex := surface.make_texture()
	surface_textures.append(stex)
	set_surface(m, surface, stex)
	set_forest_mask(m, surface)
	m.set_shader_parameter("macro_noise_tex", macro_noise_texture())
	_apply_look(m, look)
	return m


## Бесшовная текстура плавного шума RGBA (4 независимых канала, пятно ~MACRO_NOISE_FEATURE
## текселей, мипмапы): пятна лугов и волны ветра с высоты берут шум из неё, а не считают хеши —
## дешевле на GPU, мипмапы сами гасят пятна мельче пикселя. Строится один раз на игру.
static func macro_noise_texture() -> ImageTexture:
	if _macro_noise != null:
		return _macro_noise
	var n := MACRO_NOISE_SIZE
	var chans: Array[PackedByteArray] = []
	for k in 4:
		var fn := FastNoiseLite.new()
		fn.seed = 7919 * (k + 1)
		fn.noise_type = FastNoiseLite.TYPE_VALUE_CUBIC
		fn.fractal_type = FastNoiseLite.FRACTAL_NONE
		fn.frequency = 1.0 / MACRO_NOISE_FEATURE
		var img := fn.get_seamless_image(n, n)
		img.convert(Image.FORMAT_L8)
		chans.append(img.get_data())
	var data := PackedByteArray()
	data.resize(n * n * 4)
	for i in n * n:
		data[i * 4] = chans[0][i]
		data[i * 4 + 1] = chans[1][i]
		data[i * 4 + 2] = chans[2][i]
		data[i * 4 + 3] = chans[3][i]
	var out := Image.create_from_data(n, n, false, Image.FORMAT_RGBA8, data)
	out.generate_mipmaps()
	_macro_noise = ImageTexture.create_from_image(out)
	return _macro_noise


## Карта поверхности → uniform'ы шейдера (рельеф и деревья).
static func set_surface(m: ShaderMaterial, surface: SurfaceLayer, tex: Texture2D) -> void:
	m.set_shader_parameter("surface_tex", tex)
	m.set_shader_parameter("surface_origin", Vector2(surface.origin_x, surface.origin_z))
	m.set_shader_parameter("surface_spacing", surface.spacing)
	m.set_shader_parameter("surface_texels", Vector2(surface.width, surface.height))


## Поля рельефа слоёв (посчитаны в фоне после build) → все материалы.
func set_reliefs(reliefs: Array[TerrainRelief]) -> void:
	for li in _layer_mats.size():
		for m: ShaderMaterial in _layer_mats[li]:
			set_relief(m, reliefs[li] if li < reliefs.size() else null)


## Поля рельефа (TerrainRelief) → uniform'ы шейдера; null — без них (нейтрально).
static func set_relief(m: ShaderMaterial, relief: TerrainRelief) -> void:
	m.set_shader_parameter("use_relief", relief != null)
	if relief == null:
		return
	m.set_shader_parameter("relief_tex", relief.texture)
	m.set_shader_parameter("relief_shadow_tex", relief.shadow_texture)
	m.set_shader_parameter("relief_origin", Vector2(relief.origin_x, relief.origin_z))
	m.set_shader_parameter("relief_cell_m", relief.cell_m)
	m.set_shader_parameter("relief_texels", Vector2(relief.width, relief.height))


## Маска «деталь 10 м» (T02) → uniform'ы шейдера; нет маски — лес из карты классов.
static func set_forest_mask(m: ShaderMaterial, surface: SurfaceLayer) -> void:
	var tex := surface.make_mask_texture() if surface != null else null
	m.set_shader_parameter("use_forest_mask", tex != null)
	if tex == null:
		return
	m.set_shader_parameter("forest_mask_tex", tex)
	m.set_shader_parameter(
		"forest_mask_origin", Vector2(surface.mask_origin_x, surface.mask_origin_z)
	)
	m.set_shader_parameter("forest_mask_spacing", surface.mask_spacing)
	m.set_shader_parameter("forest_mask_texels", Vector2(surface.mask_width, surface.mask_height))


func _apply_look(m: ShaderMaterial, look: Dictionary) -> void:
	apply_look_params(m, look)


## Передать параметры terrain_look в uniform'ы шейдера
## (ключ = имя uniform; массивы → Color/Vector2).
static func apply_look_params(m: ShaderMaterial, look: Dictionary) -> void:
	for key in look:
		if String(key).begins_with("_") or String(key).ends_with("_doc"):
			continue
		var v: Variant = look[key]
		var uniform_name := String(key)
		if uniform_name == "roughness" or uniform_name == "specular":
			uniform_name += "_value"
		if (
			v is Array
			and not (v as Array).is_empty()
			and ((v as Array)[0] is float or (v as Array)[0] is int)
		):
			var a: Array = v
			if a.size() == 3:
				v = Color(float(a[0]), float(a[1]), float(a[2]))
			elif a.size() == 2:
				v = Vector2(float(a[0]), float(a[1]))
		m.set_shader_parameter(uniform_name, v)


## Подключить текстуры поверхностей из configs/world.json → terrain_textures:
## {"grass": {"albedo": "res://…png", "tile_m": 4}, …}. Пустой путь — процедурная заглушка;
## путь есть, а файла нет — предупреждение в лог и тоже заглушка.
func apply_textures(tex_cfg: Dictionary) -> void:
	for m in _materials:
		m.set_shader_parameter("texture_strength", float(tex_cfg.get("strength", 1.0)))
		m.set_shader_parameter("texture_color_mix", float(tex_cfg.get("color_mix", 0.3)))
		m.set_shader_parameter("texture_contrast", float(tex_cfg.get("contrast", 1.0)))
		for surf in ["grass", "forest", "rock", "snow", "scree"]:
			var sc: Dictionary = tex_cfg.get(surf, {})
			var tex := load_texture(String(sc.get("albedo", "")))
			m.set_shader_parameter("use_%s_tex" % surf, tex != null)
			if tex != null:
				m.set_shader_parameter("%s_tex" % surf, tex)
				m.set_shader_parameter("%s_tex_avg" % surf, _average_color(tex))
				m.set_shader_parameter("%s_tex_tile_m" % surf, float(sc.get("tile_m", 4.0)))
			var ntex := load_texture(String(sc.get("normal", "")))
			if surf == "rock" or surf == "grass":
				m.set_shader_parameter("use_%s_normal" % surf, ntex != null)
				if ntex != null:
					m.set_shader_parameter("%s_normal_tex" % surf, ntex)


## Средний цвет текстуры (линейный, как видит шейдер с source_color); считается раз на текстуру
## (распаковка большой текстуры — десятки мс, а материалов у рельефа десяток).
static func _average_color(tex: Texture2D) -> Color:
	var key: Variant = tex.resource_path if tex.resource_path != "" else tex.get_rid()
	if _avg_cache.has(key):
		return _avg_cache[key]
	var c := _compute_average_color(tex)
	_avg_cache[key] = c
	return c


static func _compute_average_color(tex: Texture2D) -> Color:
	var img := tex.get_image()
	if img == null:
		return Color(0.5, 0.5, 0.5)
	img = img.duplicate()
	if img.is_compressed():
		img.decompress()
	img.clear_mipmaps()
	img.resize(1, 1, Image.INTERPOLATE_BILINEAR)
	var c := img.get_pixel(0, 0).srgb_to_linear()
	return Color(maxf(c.r, 0.01), maxf(c.g, 0.01), maxf(c.b, 0.01))


## Текстура по пути: ресурс проекта (res://…) или картинка на диске (user://…, абсолютный путь).
static func load_texture(path: String) -> Texture2D:
	if path == "":
		return null
	if ResourceLoader.exists(path):
		return load(path) as Texture2D
	if FileAccess.file_exists(path):
		var img := Image.load_from_file(path)
		if img != null:
			img.generate_mipmaps()
			return ImageTexture.create_from_image(img)
	push_warning("Terrain: текстура не найдена: %s — используется процедурная раскраска" % path)
	return null


## Плоская сетка cells×cells клеток шагом step + «юбка» по краю (вершины с COLOR.r = 1).
static func _grid_mesh(cells: int, step: float) -> ArrayMesh:
	var n := cells + 1
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var idx := PackedInt32Array()
	verts.resize(n * n)
	colors.resize(n * n)
	for j in n:
		for i in n:
			verts[j * n + i] = Vector3(i * step, 0.0, j * step)
			colors[j * n + i] = Color(0, 0, 0)
	for j in cells:
		for i in cells:
			var a := j * n + i
			var b := a + 1
			var c := a + n
			var d := c + 1
			# по часовой стрелке при взгляде сверху — лицевая сторона вверх
			idx.append_array([a, b, c, b, d, c])
	# контур по периметру
	var ring: PackedInt32Array = []
	for i in n:
		ring.append(i)
	for j in range(1, n):
		ring.append(j * n + cells)
	for i in range(cells - 1, -1, -1):
		ring.append(cells * n + i)
	for j in range(cells - 1, 0, -1):
		ring.append(j * n)
	var base := verts.size()
	for k in ring.size():
		verts.append(verts[ring[k]])
		colors.append(Color(1, 0, 0))
	var rn := ring.size()
	for k in rn:
		var t0 := ring[k]
		var t1 := ring[(k + 1) % rn]
		var s0 := base + k
		var s1 := base + (k + 1) % rn
		# юбка видна с обеих сторон
		idx.append_array([t0, t1, s0, t1, s1, s0])
		idx.append_array([t0, s0, t1, t1, s0, s1])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
