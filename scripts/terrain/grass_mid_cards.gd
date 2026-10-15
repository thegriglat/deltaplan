class_name GrassMidCards
extends MultiMeshInstance3D
## Карточки-пучки средней дистанции травы, режим «angle» (G4 v4, GR-21; наработки GR-7 из
## archive/grass-cards): planes пересекающихся вертикальных квадов на пучок, текстура — массив кадров
## нарисованных пучков (data/vegetation/grass_cards_atlas.png, VARIANTS кадров в ряд, импорт —
## Texture2DArray: у каждого кадра свои мипмапы, соседние кадры не смешиваются). Карточки — там, где
## взгляд скользит по рельефу (угол к поверхности α < grass.mid.card_angle_none_deg); круче — слои
## GrassMidShell. Цвет — луг рельефа под пучком (кадр рельефа, как у слоёв), см. grass_mid_cards.gdshader.
## Сетка пучков привязана к миру и едет за камерой (как у GrassField).
## Параметры — configs/vegetation.json → grass.mid (общие и углы) и grass.mid.cards.

const SHADER := preload("res://scripts/terrain/grass_mid_cards.gdshader")
const ATLAS_PATH := "res://data/vegetation/grass_cards_atlas.png"
## Кадр атласа, пикселей (квадрат). Пучок 0,5 м на 10 м при 1080p и FOV 75° — ≈35 px:
## 128 px — с запасом на близкий край и на 1440p, дальше работают мипмапы.
const CELL_PX := 128
## Кадров (вариантов пучка) в атласе.
const VARIANTS := 4
## Прозрачная кайма кадра сбоку и сверху, пикселей: до мипа 3 (16 px на кадр) край кадра пуст —
## контур квада не проступает (до GR-21 травинки доходили до края кадра — «квадраты» вдали).
const MARGIN_PX := 8
## Порог альфы (как ALPHA_SCISSOR): пиксель травинки — альфа выше порога.
const ALPHA_CUT := 0.5
## Мипов, для которых считается поправка покрытия (128 px → 1 px — 8 уровней).
const MIP_LEVELS := 8

var camera: Camera3D
var material: ShaderMaterial
var _spacing: float = 0.45
var _last_cell := Vector2(INF, INF)

static var _scales_cache := PackedFloat32Array()
static var _tone_cache := {}


## near_mat — материал ближнего кольца (общие uniform'ы рельефа, вида и травы уже заданы);
## cfg — configs/vegetation.json → grass (берутся mid, mid.cards и углы mid.card_angle_*).
func setup(near_mat: ShaderMaterial, layer: HeightLayer, cfg: Dictionary) -> void:
	var mid: Dictionary = cfg.get("mid", {})
	var cc: Dictionary = mid.get("cards", {})
	_spacing = float(cc.get("spacing_m", 0.45))
	if bool(cfg.get("density_scaled", true)):
		_spacing = GrassField.spacing_for_density(_spacing, GrassField.density_k(cfg))
	var inner := float(mid.get("inner_radius_m", 8.4))
	var outer := float(mid.get("outer_radius_m", 40.0))
	var offs := GrassField.ring_offsets(_spacing, inner, outer)
	var n := offs.size()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = card_mesh(int(cc.get("planes", 3)))
	mm.instance_count = n
	var buf := PackedFloat32Array()
	buf.resize(n * 16)
	for i in n:
		buf[i * 16] = 1.0
		buf[i * 16 + 5] = 1.0
		buf[i * 16 + 10] = 1.0
		buf[i * 16 + 12] = offs[i].x
		buf[i * 16 + 13] = offs[i].y
	mm.buffer = buf
	multimesh = mm
	material = ShaderMaterial.new()
	material.shader = SHADER
	GrassMidShell.copy_shared_params(near_mat, material)
	material.set_shader_parameter("clump_spacing_m", _spacing)
	material.set_shader_parameter("mid_inner_m", inner)
	material.set_shader_parameter("mid_inner_fade_m", maxf(float(mid.get("inner_fade_m", 5.6)), 0.001))
	material.set_shader_parameter("mid_outer_m", outer)
	material.set_shader_parameter("mid_outer_fade_m", maxf(float(mid.get("outer_fade_m", 8.0)), 0.001))
	GrassMidCards.set_angle_params(material, mid)
	material.set_shader_parameter("card_width_m", float(cc.get("width_m", 0.55)))
	material.set_shader_parameter("card_height_k", float(cc.get("height_k", 1.1)))
	material.set_shader_parameter("far_density_min", float(cc.get("far_density_min", 0.5)))
	material.set_shader_parameter("far_width_k", float(cc.get("far_width_k", 1.4)))
	material.set_shader_parameter("height_k", float(cfg.get("height_k", 1.0)))
	var atlas := load_atlas()
	material.set_shader_parameter("atlas_tex", atlas)
	material.set_shader_parameter("atlas_cell_px", float(CELL_PX))
	material.set_shader_parameter("alpha_cut", ALPHA_CUT)
	material.set_shader_parameter("mip_alpha_scale", coverage_scales(atlas))
	var shade: Array = cc.get("shade", [0.8, 1.1])
	var sh := Vector2(float(shade[0]), float(shade[1]))
	material.set_shader_parameter("card_shade", sh)
	material.set_shader_parameter("card_tone", float(cc.get("tone", 0.1)))
	# средняя яркость видимых пикселей карточки = луг под ней (нормировка по атласу)
	material.set_shader_parameter("card_norm", 1.0 / maxf(mean_modulation(atlas, sh), 0.1))
	material.set_shader_parameter("clump_reach_m", float(cc.get("width_m", 0.55)) * 0.5)
	material_override = material
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	custom_aabb = AABB(
		Vector3(layer.origin_x, layer.min_h - 10.0, layer.origin_z),
		Vector3(layer.size_x(), layer.max_h - layer.min_h + 20.0, layer.size_z())
	)


## Пороги угла взгляда к рельефу (G4 v4) — в материал слоёв или карточек: angle_mode включает
## деление, card_angle_full_deg/none_deg — из grass.mid.
static func set_angle_params(mat: ShaderMaterial, mid: Dictionary) -> void:
	var full := float(mid.get("card_angle_full_deg", 15.0))
	var none := maxf(float(mid.get("card_angle_none_deg", 30.0)), full + 0.1)
	mat.set_shader_parameter("angle_mode", true)
	mat.set_shader_parameter("card_angle_full_deg", full)
	mat.set_shader_parameter("card_angle_none_deg", none)


## Доля карточек при угле взгляда к рельефу alpha_deg (та же формула, что card_share в шейдерах):
## 1 — только карточки (α ≤ full), 0 — только слои (α ≥ none), между — линейно.
static func card_share(alpha_deg: float, full_deg: float, none_deg: float) -> float:
	return clampf((none_deg - alpha_deg) / maxf(none_deg - full_deg, 0.1), 0.0, 1.0)


func _process(_delta: float) -> void:
	var cam := camera if camera != null else get_viewport().get_camera_3d()
	if cam == null or material == null:
		return
	var p := cam.global_position
	var cell := Vector2(floor(p.x / _spacing), floor(p.z / _spacing))
	if cell != _last_cell:
		_last_cell = cell
		material.set_shader_parameter("grid_center_cell", cell)


## Пучок из planes вертикальных квадов через центр, повёрнутых на 180°/planes: VERTEX.xz — ±0,5
## (ширину задаёт шейдер), VERTEX.y — 0..1 (высоту задаёт шейдер), UV — кадр атласа (v = 0 сверху).
static func card_mesh(planes: int) -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	for p in planes:
		var a := PI * p / planes
		var s := Vector2(cos(a), sin(a)) * 0.5
		var o := verts.size()
		verts.append_array(
			PackedVector3Array(
				[Vector3(-s.x, 0.0, -s.y), Vector3(s.x, 0.0, s.y), Vector3(-s.x, 1.0, -s.y), Vector3(s.x, 1.0, s.y)]
			)
		)
		uvs.append_array(PackedVector2Array([Vector2(0, 1), Vector2(1, 1), Vector2(0, 0), Vector2(1, 0)]))
		idx.append_array(PackedInt32Array([o, o + 2, o + 1, o + 1, o + 2, o + 3]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Атлас — Texture2DArray из импортированного файла (сжатие + мипмапы по каждому кадру); нет файла —
## тот же атлас, собранный на лету (без сжатия, с мипмапами).
static func load_atlas() -> Texture2DArray:
	if ResourceLoader.exists(ATLAS_PATH):
		var t := load(ATLAS_PATH) as Texture2DArray
		if t != null:
			return t
	var layers: Array[Image] = []
	var strip := atlas_image(CELL_PX, VARIANTS)
	for v in VARIANTS:
		var img := strip.get_region(Rect2i(v * CELL_PX, 0, CELL_PX, CELL_PX))
		img.generate_mipmaps()
		layers.append(img)
	var arr := Texture2DArray.new()
	arr.create_from_images(layers)
	return arr


## Кадры атласа (распакованные RGBA8 с мипмапами): из текстуры (с GPU — чтение слоёв); без данных
## (headless, заглушка рендера) — те же кадры, собранные на лету (мипмапы — тем же фильтром, что импорт).
static func _layer_images(tex: Texture2DArray) -> Array[Image]:
	var out: Array[Image] = []
	for li in tex.get_layers():
		var img := tex.get_layer_data(li)
		if img == null or img.is_empty():
			out.clear()
			break
		if img.is_compressed():
			img.decompress()
		if img.get_format() != Image.FORMAT_RGBA8:
			img.convert(Image.FORMAT_RGBA8)
		out.append(img)
	if out.is_empty():
		var strip := atlas_image(CELL_PX, VARIANTS)
		for v in VARIANTS:
			var img := strip.get_region(Rect2i(v * CELL_PX, 0, CELL_PX, CELL_PX))
			img.generate_mipmaps()
			out.append(img)
	return out


## Поправка покрытия по мипам (мипмапы с сохранением покрытия, Castaño 2010): усреднение альфы
## тонких травинок на мипе k уменьшает долю пикселей выше порога ALPHA_CUT — пучок «тает» вдали.
## Для каждого мипа — множитель альфы s_k, при котором доля пикселей с a·s_k > порога та же, что на
## мипе 0 (по всем кадрам вместе). Шейдер берёт s по уровню мипа (линейно между уровнями).
static func coverage_scales(tex: Texture2DArray) -> PackedFloat32Array:
	if not _scales_cache.is_empty():
		return _scales_cache
	var out := PackedFloat32Array()
	out.resize(MIP_LEVELS)
	out.fill(1.0)
	var mips: Array[PackedByteArray] = []
	for k in MIP_LEVELS:
		mips.append(PackedByteArray())
	for img in _layer_images(tex):
		var data := img.get_data()
		var levels := mini(img.get_mipmap_count() + 1, MIP_LEVELS)
		for k in levels:
			var off := img.get_mipmap_offset(k)
			var end := img.get_mipmap_offset(k + 1) if k < img.get_mipmap_count() else data.size()
			var a := PackedByteArray()
			a.resize((end - off) / 4)
			for j in a.size():
				a[j] = data[off + j * 4 + 3]
			mips[k].append_array(a)
	var cut := int(ALPHA_CUT * 255.0)
	var a0 := mips[0]
	if a0.is_empty():
		return out
	var cov0 := 0
	for a in a0:
		if a > cut:
			cov0 += 1
	var share0 := float(cov0) / a0.size()
	for k in range(1, MIP_LEVELS):
		var a := mips[k].duplicate()
		if a.is_empty():
			out[k] = out[k - 1]
			continue
		a.sort()
		# значение альфы, выше которого лежит доля share0 пикселей мипа
		var i := clampi(int((1.0 - share0) * a.size()), 0, a.size() - 1)
		var t := maxf(float(a[i]), 1.0)
		# на мелких мипах (4×4 на кадр) квантиль по десяткам пикселей шумит; потеря покрытия с мипом
		# только растёт — множитель не меньше предыдущего
		out[k] = clampf(maxf((cut + 0.5) / t, out[k - 1]), 1.0, 4.0)
	_scales_cache = out
	return out


## Средняя модуляция видимых пикселей карточки на мипе 0: тон кадра (RGB, серый; ÷0,9 как в шейдере)
## × затенение к корню mix(shade.x, shade.y, t), t — доля высоты (0 у корня). Шейдер делит на неё —
## в среднем карточка той же яркости, что луг под ней.
static func mean_modulation(tex: Texture2DArray, shade: Vector2) -> float:
	if _tone_cache.has(shade):
		return _tone_cache[shade]
	var sum := 0.0
	var cnt := 0
	var cut := int(ALPHA_CUT * 255.0)
	for img in _layer_images(tex):
		var w := img.get_width()
		var h := img.get_height()
		var data := img.get_data()
		for y in h:
			var sh := lerpf(shade.x, shade.y, 1.0 - (y + 0.5) / h)
			for x in w:
				var o := (y * w + x) * 4
				if data[o + 3] > cut:
					sum += data[o] / 255.0 / 0.9 * sh
					cnt += 1
	var m := sum / cnt if cnt > 0 else 1.0
	_tone_cache[shade] = m
	return m


## Атлас пучков: variants кадров cell×cell в ряд. В кадре — пучок травинок от корня у середины низа:
## 26–40 травинок, сужаются от ~2,5 % ширины кадра у корня к острому кончику, изогнуты наружу,
## высота 45–100 % кадра без каймы. Травинки не заходят в кайму MARGIN_PX сбоку и сверху (наклон
## ограничен): на мипах до 16 px на кадр край квада прозрачен. RGB — тон травинки (серый 0,8–1,
## линейный; цвет даёт шейдер по лугу рельефа), под нулевой альфой — средний тон кадра (дилатация:
## мипмапы и сжатие не тянут к краю чужой цвет), A — покрытие (растр 4×4 субпикселя). Детерминирован.
static func atlas_image(cell: int, variants: int) -> Image:
	var ss := 4
	var big := cell * ss
	var m := MARGIN_PX * ss
	var img := Image.create(cell * variants, cell, false, Image.FORMAT_RGBA8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 1983
	for v in variants:
		var cov := PackedFloat32Array()
		cov.resize(big * big)
		var tone := PackedFloat32Array()
		tone.resize(big * big)
		var blades := rng.randi_range(26, 40)
		for b in blades:
			var root := Vector2(big * 0.5 + clampf(rng.randfn(0.0, big * 0.06), -big * 0.15, big * 0.15), big - 1.0)
			var hgt := (big - m) * rng.randf_range(0.45, 1.0)
			var lean := rng.randfn(0.0, 0.2)  # наклон кончика, доля высоты
			var curl := rng.randfn(0.0, 0.08)
			# кончик не дальше каймы: смещение (lean + curl)·hgt не больше места до каймы
			var room := (big * 0.5 - m - big * 0.02) - absf(root.x - big * 0.5)
			var reach := absf(lean + curl) * hgt
			if reach > room and reach > 0.0:
				lean *= room / reach
				curl *= room / reach
			var w0 := big * rng.randf_range(0.018, 0.03)
			var shade := rng.randf_range(0.8, 1.0)
			var steps := int(hgt)
			for s in steps + 1:
				var t := float(s) / steps
				var c := root + Vector2((lean * t + curl * t * t) * hgt, -t * hgt)
				var hw := w0 * (1.0 - t) * 0.5 + 0.5
				var x0 := int(floor(c.x - hw))
				var x1 := int(ceil(c.x + hw))
				var y := int(c.y)
				if y < m or y >= big:
					continue
				for x in range(maxi(x0, m), mini(x1, big - 1 - m) + 1):
					if absf(x + 0.5 - c.x) <= hw:
						var k := y * big + x
						if cov[k] < 1.0 or shade > tone[k]:
							tone[k] = shade
						cov[k] = 1.0
		var px_a := PackedFloat32Array()
		px_a.resize(cell * cell)
		var px_g := PackedFloat32Array()
		px_g.resize(cell * cell)
		var g_sum := 0.0
		var g_n := 0.0
		for py in cell:
			for px in cell:
				var a := 0.0
				var tsum := 0.0
				for sy in ss:
					for sx in ss:
						var k := (py * ss + sy) * big + px * ss + sx
						a += cov[k]
						tsum += tone[k] * cov[k]
				px_a[py * cell + px] = a / (ss * ss)
				if a > 0.0:
					px_g[py * cell + px] = tsum / a
					g_sum += tsum
					g_n += a
		var g_mean := g_sum / g_n if g_n > 0.0 else 0.9
		for py in cell:
			for px in cell:
				var a := px_a[py * cell + px]
				var g := px_g[py * cell + px] if a > 0.0 else g_mean
				img.set_pixel(v * cell + px, py, Color(g, g, g, a))
	return img
