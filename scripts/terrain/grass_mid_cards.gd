class_name GrassMidCards
extends MultiMeshInstance3D
## Средняя дистанция травы, режим «cards» (G4, GR-7): карточки-пучки — planes пересекающихся
## вертикальных квадов на пучок, текстура — атлас нарисованных пучков травы
## (data/vegetation/grass_cards_atlas.png: variants кадров в ряд, серый тон × альфа, сжатие +
## мипмапы). Альфа — alpha scissor + alpha-to-coverage (при MSAA края пучков сглажены). Сетка пучков
## привязана к миру и едет за камерой (как у GrassField); положение, высота, цвет, ветер — в
## grass_mid_cards.gdshader, общие uniform'ы копируются из материала ближнего кольца.
## Параметры — configs/vegetation.json → grass.mid (общие) и grass.mid.cards.

const SHADER := preload("res://scripts/terrain/grass_mid_cards.gdshader")
const ATLAS_PATH := "res://data/vegetation/grass_cards_atlas.png"
## Кадр атласа, пикселей (квадрат). Пучок 0,5 м на 10 м при 1080p и FOV 75° — ≈35 px:
## 128 px — с запасом на близкий край и на 1440p, дальше работают мипмапы.
const CELL_PX := 128
## Кадров (вариантов пучка) в атласе.
const VARIANTS := 4

var camera: Camera3D
var material: ShaderMaterial
var _spacing: float = 0.45
var _last_cell := Vector2(INF, INF)


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
	material.set_shader_parameter("card_width_m", float(cc.get("width_m", 0.55)))
	material.set_shader_parameter("card_height_k", float(cc.get("height_k", 1.1)))
	material.set_shader_parameter("far_density_min", float(cc.get("far_density_min", 0.5)))
	material.set_shader_parameter("far_width_k", float(cc.get("far_width_k", 1.4)))
	material.set_shader_parameter("atlas_tex", load_atlas())
	material.set_shader_parameter("atlas_variants", VARIANTS)
	material.set_shader_parameter("atlas_cell_px", float(CELL_PX))
	material.set_shader_parameter("clump_reach_m", float(cc.get("width_m", 0.55)) * 0.5)
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


## Атлас: импортированная текстура (сжатие + мипмапы); нет файла — тот же атлас, собранный на лету
## (без сжатия, с мипмапами).
static func load_atlas() -> Texture2D:
	if ResourceLoader.exists(ATLAS_PATH):
		var t: Texture2D = load(ATLAS_PATH)
		if t != null:
			return t
	var img := atlas_image(CELL_PX, VARIANTS)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


## Атлас пучков: variants кадров cell×cell в ряд. В кадре — пучок травинок от корня у середины низа:
## 26–40 травинок, сужаются от ~2,5 % ширины кадра у корня к острому кончику, изогнуты наружу,
## высота 45–100 % кадра. RGB — тон травинки (серый 0,8–1, линейный; цвет и затенение к корню даёт
## шейдер по палитре луга и blade_shade), A — покрытие (растр 4×4 субпикселя на пиксель). Детерминирован.
static func atlas_image(cell: int, variants: int) -> Image:
	var ss := 4
	var big := cell * ss
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
			var root := Vector2(big * 0.5 + rng.randfn(0.0, big * 0.07), big - 1.0)
			var hgt := big * rng.randf_range(0.45, 0.98)
			var lean := rng.randfn(0.0, 0.22)  # наклон кончика, доля высоты
			var curl := rng.randfn(0.0, 0.1)
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
				if y < 0 or y >= big:
					continue
				for x in range(maxi(x0, 0), mini(x1, big - 1) + 1):
					if absf(x + 0.5 - c.x) <= hw:
						var k := y * big + x
						var tv := shade
						if cov[k] < 1.0 or tv > tone[k]:
							tone[k] = tv
						cov[k] = 1.0
		for py in cell:
			for px in cell:
				var a := 0.0
				var tsum := 0.0
				for sy in ss:
					for sx in ss:
						var k := (py * ss + sy) * big + px * ss + sx
						a += cov[k]
						tsum += tone[k] * cov[k]
				var g := tsum / a if a > 0.0 else 0.8
				img.set_pixel(v * cell + px, py, Color(g, g, g, a / (ss * ss)))
	return img
