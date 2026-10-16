class_name GrassMidCards
extends MultiMeshInstance3D
## Карточки-пучки средней дистанции травы, режим «angle» (G4 v4, GR-21; наработки GR-7 из
## archive/grass-cards): planes пересекающихся вертикальных квадов на пучок, текстура — массив кадров
## нарисованных пучков (data/vegetation/grass_cards_atlas.png, VARIANTS кадров в ряд, импорт —
## Texture2DArray: у каждого кадра свои мипмапы, соседние кадры не смешиваются). Карточки — там, где
## взгляд скользит по рельефу (угол к поверхности α < grass.mid.card_angle_none_deg); круче — слои
## GrassMidShell. Цвет — луг рельефа под пучком (кадр рельефа, как у слоёв), см. grass_mid_cards.gdshader.
## Сетка пучков привязана к миру и едет за камерой (как у GrassField).
## Форма (GR-25, grass.mid.cards.shape): tuft — пучок из planes пересекающихся квадов с рваным верхом;
## strip — низкая вытянутая полоса стеблей, повёрнутая к камере по рыску (торцом не видна), низ
## изогнут по рельефу (segments отрезков, высота земли в каждой вершине).
## Параметры — configs/vegetation.json → grass.mid (общие и углы) и grass.mid.cards (strip — поверх).

const SHADER := preload("res://scripts/terrain/grass_mid_cards.gdshader")
const ATLAS_PATH := "res://data/vegetation/grass_cards_atlas.png"
const STRIP_ATLAS_PATH := "res://data/vegetation/grass_strip_atlas.png"
## Формы карточек (grass.mid.cards.shape).
const SHAPES: PackedStringArray = ["tuft", "strip"]
## Кадр атласа пучка, пикселей (квадрат). Пучок 0,5 м на 10 м при 1080p и FOV 75° — ≈35 px:
## 128 px — с запасом на близкий край и на 1440p, дальше работают мипмапы.
const CELL_PX := 128
## Кадр атласа полосы, пикселей (ширина × высота; полоса ~4 высоты травы в длину).
const STRIP_CELL := Vector2i(256, 64)
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

var shape := "tuft"

static var _scales_cache := {}
static var _tone_cache := {}


## near_mat — материал ближнего кольца (общие uniform'ы рельефа, вида и травы уже заданы);
## cfg — configs/vegetation.json → grass (берутся mid, mid.cards и углы mid.card_angle_*).
func setup(near_mat: ShaderMaterial, layer: HeightLayer, cfg: Dictionary) -> void:
	var mid: Dictionary = cfg.get("mid", {})
	var cc: Dictionary = mid.get("cards", {}).duplicate(true)
	shape = shape_of(cc)
	if shape == "strip" and cc.get("strip", null) is Dictionary:
		cc.merge(cc.strip, true)
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
	if shape == "strip":
		mm.mesh = strip_mesh(int(cc.get("segments", 4)))
	else:
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
	material.set_shader_parameter("strip_mode", shape == "strip")
	var hv: Array = cc.get("height_var", [1.0, 1.0])
	material.set_shader_parameter("card_height_var", Vector2(float(hv[0]), float(hv[1])))
	material.set_shader_parameter("card_tilt", float(cc.get("tilt", 0.0)))
	var atlas := load_atlas(shape)
	material.set_shader_parameter("atlas_tex", atlas)
	material.set_shader_parameter("atlas_cell_px", Vector2(cell_size(shape)))
	material.set_shader_parameter("alpha_cut", ALPHA_CUT)
	material.set_shader_parameter("mip_alpha_scale", coverage_scales(atlas))
	var shade: Array = cc.get("shade", [0.8, 1.1])
	var sh := Vector2(float(shade[0]), float(shade[1]))
	material.set_shader_parameter("card_shade", sh)
	material.set_shader_parameter("card_tone", float(cc.get("tone", 0.1)))
	# средняя яркость видимых пикселей карточки = луг под ней (нормировка по атласу)
	material.set_shader_parameter("card_norm", 1.0 / maxf(mean_modulation(atlas, sh), 0.1))
	material.set_shader_parameter("clump_reach_m", float(cc.get("width_m", 0.55)) * 0.5)
	var rt: Array = cc.get("root_depth_tol", [0.3, 0.25])
	material.set_shader_parameter("root_depth_tol", Vector2(float(rt[0]), float(rt[1])))
	material_override = material
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	custom_aabb = AABB(
		Vector3(layer.origin_x, layer.min_h - 10.0, layer.origin_z),
		Vector3(layer.size_x(), layer.max_h - layer.min_h + 20.0, layer.size_z())
	)


## Форма карточек: переменная окружения DP_GRASS_CARDS=tuft|strip (кадры, замеры) сильнее
## grass.mid.cards.shape; неизвестная или нет ключа — tuft.
static func shape_of(cards_cfg: Dictionary) -> String:
	var env := OS.get_environment("DP_GRASS_CARDS").strip_edges().to_lower()
	if env in SHAPES:
		return env
	var sh := String(cards_cfg.get("shape", "tuft")).to_lower()
	return sh if sh in SHAPES else "tuft"


## Размер кадра атласа формы, пикселей.
static func cell_size(sh: String) -> Vector2i:
	return STRIP_CELL if sh == "strip" else Vector2i(CELL_PX, CELL_PX)


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


## Полоса: один вертикальный квад, segments отрезков по длине (низ гнётся по рельефу — высота земли
## в каждой вершине), VERTEX.x — −0,5…+0,5 (длину и поворот к камере задаёт шейдер), VERTEX.y — 0..1.
static func strip_mesh(segments: int) -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	var n := maxi(segments, 1)
	for i in n + 1:
		var u := float(i) / n
		verts.append_array(PackedVector3Array([Vector3(u - 0.5, 0.0, 0.0), Vector3(u - 0.5, 1.0, 0.0)]))
		uvs.append_array(PackedVector2Array([Vector2(u, 1), Vector2(u, 0)]))
		if i > 0:
			var o := (i - 1) * 2
			idx.append_array(PackedInt32Array([o, o + 1, o + 2, o + 2, o + 1, o + 3]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Атлас формы — Texture2DArray из импортированного файла (сжатие + мипмапы по каждому кадру); нет
## файла — тот же атлас, собранный на лету (без сжатия, с мипмапами).
static func load_atlas(sh := "tuft") -> Texture2DArray:
	var path := STRIP_ATLAS_PATH if sh == "strip" else ATLAS_PATH
	if ResourceLoader.exists(path):
		var t := load(path) as Texture2DArray
		if t != null:
			return t
	var arr := Texture2DArray.new()
	arr.create_from_images(_generated_layers(sh))
	return arr


## Кадры атласа формы, собранные на лету (с мипмапами).
static func _generated_layers(sh: String) -> Array[Image]:
	var cs := cell_size(sh)
	var row := atlas_image(cs.x, cs.y, VARIANTS, sh)
	var layers: Array[Image] = []
	for v in VARIANTS:
		var img := row.get_region(Rect2i(v * cs.x, 0, cs.x, cs.y))
		img.generate_mipmaps()
		layers.append(img)
	return layers


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
		var sh := "strip" if tex.get_width() != tex.get_height() else "tuft"
		out = _generated_layers(sh)
	return out


## Поправка покрытия по мипам (мипмапы с сохранением покрытия, Castaño 2010): усреднение альфы
## тонких травинок на мипе k уменьшает долю пикселей выше порога ALPHA_CUT — пучок «тает» вдали.
## Для каждого мипа — множитель альфы s_k, при котором доля пикселей с a·s_k > порога та же, что на
## мипе 0 (по всем кадрам вместе). Шейдер берёт s по уровню мипа (линейно между уровнями).
static func coverage_scales(tex: Texture2DArray) -> PackedFloat32Array:
	var key := tex.get_width() * 100000 + tex.get_height()
	if _scales_cache.has(key):
		return _scales_cache[key]
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
	_scales_cache[key] = out
	return out


## Средняя модуляция видимых пикселей карточки на мипе 0: тон кадра (RGB, серый; ÷0,9 как в шейдере)
## × затенение к корню mix(shade.x, shade.y, t), t — доля высоты (0 у корня). Шейдер делит на неё —
## в среднем карточка той же яркости, что луг под ней.
static func mean_modulation(tex: Texture2DArray, shade: Vector2) -> float:
	var key := [tex.get_width(), tex.get_height(), shade]
	if _tone_cache.has(key):
		return _tone_cache[key]
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
	_tone_cache[key] = m
	return m


## Атлас: variants кадров cell_w×cell_h в ряд (GR-25: силуэт — отдельные стебли разной высоты, верх
## рваный, без сплошной кромки и на мелких мипах). Травинка сужается от корня к острому кончику,
## изогнута; RGB — тон травинки (серый 0,8–1, линейный; цвет даёт шейдер по лугу рельефа), под нулевой
## альфой — средний тон кадра (дилатация: мипмапы и сжатие не тянут к краю чужой цвет), A — покрытие
## (растр 4×4 субпикселя). Травинки не заходят в кайму MARGIN_PX сбоку и сверху. Детерминирован.
## tuft — пучок от корней у середины низа (разброс ±28 % ширины): 18–26 травинок высотой 30–100 %
## кадра (больше средних, длинных мало), ширина у корня 2,2–3,2 % кадра;
## strip — полоса: корни по всей длине, 17–20 травинок на высоту кадра длины, высота 30–100 % и к концам
## полосы ниже (огибающая на 18 % длины с каждого конца — торцы не срезаны вертикалью), ширина как у пучка
## в метрах (кадр полосы вдвое ниже по пикселям на метр).
static func atlas_image(cell_w: int, cell_h: int, variants: int, sh := "tuft") -> Image:
	var ss := 4
	var bw := cell_w * ss
	var bh := cell_h * ss
	var strip := sh == "strip"
	var m := MARGIN_PX * ss
	var mt := (MARGIN_PX / 2 if strip else MARGIN_PX) * ss
	var img := Image.create(cell_w * variants, cell_h, false, Image.FORMAT_RGBA8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 1983 if not strip else 2025
	for v in variants:
		var cov := PackedFloat32Array()
		cov.resize(bw * bh)
		var tone := PackedFloat32Array()
		tone.resize(bw * bh)
		var blades := rng.randi_range(18, 26)
		if strip:
			blades = int(round(float(cell_w) / cell_h * rng.randf_range(17.0, 20.0)))
		for b in blades:
			var root: Vector2
			var env := 1.0
			if strip:
				var xr := rng.randf_range(0.03, 0.97)
				root = Vector2(m + xr * (bw - 2 * m), bh - 1.0)
				env = lerpf(0.4, 1.0, smoothstep(0.0, 0.18, xr) * smoothstep(0.0, 0.18, 1.0 - xr))
			else:
				root = Vector2(bw * 0.5 + clampf(rng.randfn(0.0, bw * 0.1), -bw * 0.28, bw * 0.28), bh - 1.0)
			var hgt := (bh - mt) * (0.3 + 0.7 * pow(rng.randf(), 0.8)) * env
			var lean := rng.randfn(0.0, 0.25 if strip else 0.22)  # наклон кончика, доля высоты
			var curl := rng.randfn(0.0, 0.08)
			# кончик не дальше каймы сбоку
			var room := (root.x - m - ss) if (lean + curl) < 0.0 else (bw - m - ss - root.x)
			var reach := absf(lean + curl) * hgt
			if reach > room and reach > 0.0:
				var k := maxf(room, 0.0) / reach
				lean *= k
				curl *= k
			# ширина у корня: пучок — доля ширины кадра (0,55 м → 1,2–1,8 см); полоса — доля высоты кадра
			# (0,4–0,6 м → те же 1–2 см)
			var w0 := bh * rng.randf_range(0.025, 0.04) if strip else bw * rng.randf_range(0.022, 0.032)
			var shade := rng.randf_range(0.8, 1.0)
			var steps := int(hgt)
			for s in steps + 1:
				var t := float(s) / maxi(steps, 1)
				var c := root + Vector2((lean * t + curl * t * t) * hgt, -t * hgt)
				var hw := w0 * (1.0 - t) * 0.5 + 0.5
				var x0 := int(floor(c.x - hw))
				var x1 := int(ceil(c.x + hw))
				var y := int(c.y)
				if y < mt or y >= bh:
					continue
				for x in range(maxi(x0, m), mini(x1, bw - 1 - m) + 1):
					if absf(x + 0.5 - c.x) <= hw:
						var k2 := y * bw + x
						if cov[k2] < 1.0 or shade > tone[k2]:
							tone[k2] = shade
						cov[k2] = 1.0
		var px_a := PackedFloat32Array()
		px_a.resize(cell_w * cell_h)
		var px_g := PackedFloat32Array()
		px_g.resize(cell_w * cell_h)
		var g_sum := 0.0
		var g_n := 0.0
		for py in cell_h:
			for px in cell_w:
				var a := 0.0
				var tsum := 0.0
				for sy in ss:
					for sx in ss:
						var k3 := (py * ss + sy) * bw + px * ss + sx
						a += cov[k3]
						tsum += tone[k3] * cov[k3]
				px_a[py * cell_w + px] = a / (ss * ss)
				if a > 0.0:
					px_g[py * cell_w + px] = tsum / a
					g_sum += tsum
					g_n += a
		var g_mean := g_sum / g_n if g_n > 0.0 else 0.9
		for py in cell_h:
			for px in cell_w:
				var a := px_a[py * cell_w + px]
				var g := px_g[py * cell_w + px] if a > 0.0 else g_mean
				img.set_pixel(v * cell_w + px, py, Color(g, g, g, a))
	return img
