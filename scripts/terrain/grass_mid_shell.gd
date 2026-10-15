class_name GrassMidShell
extends MeshInstance3D
## Средняя дистанция травы, режим «shell» (G4, GR-7): N горизонтальных слоёв сетки-кольца
## inner..outer над рельефом. Слой k на доле высоты травы (k+1)/N; в слое видны только «стебли»
## шумовой маски (data/vegetation/grass_shell_mask.png, мипмапы), чья высота не ниже доли слоя —
## снизу густо, кверху редеет: издали бархатный ворс. Сетка привязана к миру (шаг mesh_step_m,
## центр — клетка камеры): вершины берут высоту рельефа в одних и тех же точках, при движении не
## «плывут». Класс поверхности, скос, приминание, ветер — как у травинок (общие uniform'ы копируются
## из материала ближнего кольца). Цвет (GR-8) — луг рельефа прямо за слоем (кадр рельефа,
## hint_screen_texture) с модуляцией ворса; края растворяются в луг (grass_mid_shell.gdshader).
## Параметры — configs/vegetation.json → grass.mid (общие) и grass.mid.shell.

const SHADER := preload("res://scripts/terrain/grass_mid_shell.gdshader")
const MASK_PATH := "res://data/vegetation/grass_shell_mask.png"
## Размер маски, текселей (квадрат, бесшовная плитка).
const MASK_SIZE := 256

var camera: Camera3D
var material: ShaderMaterial
var _step: float = 1.0
var _last_cell := Vector2(INF, INF)


## near_mat — материал ближнего кольца (общие uniform'ы рельефа, вида и травы уже заданы);
## cfg — configs/vegetation.json → grass (берутся mid и mid.shell).
func setup(near_mat: ShaderMaterial, layer: HeightLayer, cfg: Dictionary) -> void:
	var mid: Dictionary = cfg.get("mid", {})
	var sc: Dictionary = mid.get("shell", {})
	_step = float(sc.get("mesh_step_m", 1.0))
	var inner := float(mid.get("inner_radius_m", 8.4))
	var outer := float(mid.get("outer_radius_m", 40.0))
	var layers := int(sc.get("layers", 6))
	mesh = shell_mesh(_step, inner, outer, layers)
	material = ShaderMaterial.new()
	material.shader = SHADER
	GrassMidShell.copy_shared_params(near_mat, material)
	material.set_shader_parameter("mid_inner_m", inner)
	material.set_shader_parameter("mid_inner_fade_m", maxf(float(mid.get("inner_fade_m", 5.6)), 0.001))
	material.set_shader_parameter("mid_outer_m", outer)
	material.set_shader_parameter("mid_outer_fade_m", maxf(float(mid.get("outer_fade_m", 8.0)), 0.001))
	material.set_shader_parameter("mesh_step_m", _step)
	material.set_shader_parameter("mask_tex", load_mask())
	material.set_shader_parameter("mask_tile_m", float(sc.get("mask_tile_m", 4.0)))
	material.set_shader_parameter("coverage", clampf(GrassField.density_k(cfg), 0.0, 1.0))
	material.set_shader_parameter("height_k", float(cfg.get("height_k", 1.0)) * float(sc.get("height_k", 1.0)))
	material_override = material
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	custom_aabb = AABB(
		Vector3(layer.origin_x, layer.min_h - 10.0, layer.origin_z),
		Vector3(layer.size_x(), layer.max_h - layer.min_h + 20.0, layer.size_z())
	)


func _process(_delta: float) -> void:
	var cam := camera if camera != null else get_viewport().get_camera_3d()
	if cam == null or material == null:
		return
	var p := cam.global_position
	var cell := Vector2(floor(p.x / _step), floor(p.z / _step))
	if cell != _last_cell:
		_last_cell = cell
		material.set_shader_parameter("grid_origin", cell * _step)


## Все uniform'ы материала src, которые есть в шейдере dst (рельеф, вид, палитра луга, параметры
## травы, скошенное, приминание), — в dst. Так средняя трава считает цвет тем же путём, что травинки.
static func copy_shared_params(src: ShaderMaterial, dst: ShaderMaterial) -> void:
	var have := {}
	for u in dst.shader.get_shader_uniform_list():
		have[String(u.name)] = true
	for u in src.shader.get_shader_uniform_list():
		var n := String(u.name)
		if not have.has(n):
			continue
		var v: Variant = src.get_shader_parameter(n)
		if v != null:
			dst.set_shader_parameter(n, v)


## Сетка-кольцо слоёв: квадраты шага step, чей центр на расстоянии [inner − 2·step; outer + 2·step]
## от начала (камера внутри своей клетки — запас); слоёв layers, UV.x — доля высоты слоя
## (k+1)/layers. Индексы — сверху вниз: верхний слой рисуется первым, нижние отбрасываются тестом
## глубины там, где их закрыл верхний (меньше перерисовки с discard).
static func shell_mesh(step: float, inner: float, outer: float, layers: int) -> ArrayMesh:
	var m := int(ceil(outer / step)) + 3
	var lo := maxf(inner - 2.0 * step, 0.0)
	var hi := outer + 2.0 * step
	var n := 2 * m + 1
	var used := PackedByteArray()
	used.resize(n * n)
	var quads := PackedInt32Array()
	for j in range(-m, m):
		for i in range(-m, m):
			var d := Vector2(i + 0.5, j + 0.5).length() * step
			if d >= lo and d <= hi:
				quads.append((j + m) * n + (i + m))
	# вершины, задействованные квадратами
	var vid := PackedInt32Array()
	vid.resize((n + 1) * (n + 1))
	vid.fill(-1)
	var base := PackedVector2Array()
	for q in quads:
		var qi := q % n
		var qj := q / n
		for c: Vector2i in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]:
			var k := (qj + c.y) * (n + 1) + qi + c.x
			if vid[k] < 0:
				vid[k] = base.size()
				base.append(Vector2(qi + c.x - m, qj + c.y - m) * step)
	var nv := base.size()
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	verts.resize(nv * layers)
	uvs.resize(nv * layers)
	var idx := PackedInt32Array()
	for li in layers:
		var k := layers - 1 - li  # сверху вниз
		var frac := float(k + 1) / layers
		var o := li * nv
		for v in nv:
			verts[o + v] = Vector3(base[v].x, 0.0, base[v].y)
			uvs[o + v] = Vector2(frac, 0.0)
		for q in quads:
			var qi := q % n
			var qj := q / n
			var a := o + vid[qj * (n + 1) + qi]
			var b := o + vid[qj * (n + 1) + qi + 1]
			var c := o + vid[(qj + 1) * (n + 1) + qi]
			var d := o + vid[(qj + 1) * (n + 1) + qi + 1]
			idx.append_array(PackedInt32Array([a, b, c, b, d, c]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh_out := ArrayMesh.new()
	mesh_out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh_out


## Маска стеблей: импортированная текстура (мипмапы), нет файла — та же маска, собранная на лету.
static func load_mask() -> Texture2D:
	if ResourceLoader.exists(MASK_PATH):
		var t: Texture2D = load(MASK_PATH)
		if t != null:
			return t
	var img := mask_image(MASK_SIZE)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


## Шумовая маска стеблей, бесшовная плитка size×size (тексель — «стебель»-кустик ~1,5 см при
## mask_tile_m = 4 м). R — высота стебля, доля высоты травы класса 0..1 (0 — пусто между кустиками);
## G — ранг стебля 0..1 (густота: стебель есть, если ранг < доли пучков класса × густоты);
## B — разброс тона 0..1. Кустики: высота = огибающая куртины (≈15 см) × случайная доля, у края
## куртины ниже, между куртинами просветы. Детерминирована (seed).
static func mask_image(size: int) -> Image:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261015
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	# куртины: центры на сетке 10×10 клеток с дрожанием (бесшовно — расстояние по тору)
	var cs := 10
	var cells := size / cs
	var centers: Array[Vector3] = []  # x, y, радиус
	for cj in cells:
		for ci in cells:
			centers.append(
				Vector3(
					(ci + rng.randf()) * cs, (cj + rng.randf()) * cs, rng.randf_range(0.45, 0.85) * cs
				)
			)
	for y in size:
		for x in size:
			var env := 0.0
			var tone := 0.5
			var ci := x / cs
			var cj := y / cs
			for dj in range(-1, 2):
				for di in range(-1, 2):
					var c: Vector3 = centers[posmod(cj + dj, cells) * cells + posmod(ci + di, cells)]
					var dx := fposmod(x - c.x + size * 0.5, size) - size * 0.5
					var dy := fposmod(y - c.y + size * 0.5, size) - size * 0.5
					var e := 1.0 - Vector2(dx, dy).length() / c.z
					if e > env:
						env = e
						tone = fposmod(c.x * 0.137 + c.y * 0.071, 1.0)
			var h := 0.0
			if env > 0.0 and rng.randf() < 0.85:
				h = clampf(sqrt(env) * rng.randf_range(0.55, 1.0), 0.0, 1.0)
			elif rng.randf() < 0.12:
				h = rng.randf_range(0.1, 0.45)  # одиночные низкие стебли между куртинами
			img.set_pixel(x, y, Color(h, rng.randf(), clampf(tone * 0.7 + rng.randf() * 0.3, 0.0, 1.0), 1.0))
	return img
