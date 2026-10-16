class_name GrassStoneScene
extends RefCounted
## Сцена для проверок «трава не на породе рельефа» (GR-25, G2 v2): синтетический рельеф с выпуклой
## вершиной (выходы породы: −лапласиан на 35 м ≫ outcrop_convex_k) и обрывом (скалы круче
## rock_slope_deg, ниже — осыпь), весь луг; вид — configs/world.json → terrain_look.

const N := 72
const STEP := 5.0
const ORIGIN := -180.0

var layer: HeightLayer
var height_tex: ImageTexture
var surface: SurfaceLayer
var surface_tex: ImageTexture
var look: Dictionary


static func height(x: float, z: float) -> float:
	# купол 45 м (σ 55 м) у начала координат и обрыв 35 м на x 70…90 м (уклон ~60°)
	var dome := 45.0 * exp(-(x * x + z * z) / (2.0 * 55.0 * 55.0))
	var cliff := 35.0 * smoothstep(70.0, 90.0, x)
	return 300.0 + dome - cliff


static func build() -> GrassStoneScene:
	var s := GrassStoneScene.new()
	var hs := PackedFloat32Array()
	hs.resize(N * N)
	var img := Image.create(N, N, false, Image.FORMAT_RF)
	for j in N:
		for i in N:
			var h := height(ORIGIN + i * STEP, ORIGIN + j * STEP)
			hs[j * N + i] = h
			img.set_pixel(i, j, Color(h, 0, 0))
	s.layer = HeightLayer.from_heights("t", N, N, STEP, ORIGIN, ORIGIN, hs)
	s.height_tex = ImageTexture.create_from_image(img)
	var sn := 36
	var ss := 10.0
	var cls := PackedByteArray()
	cls.resize(sn * sn)
	cls.fill(SurfaceLayer.GRASS)
	var simg := Image.create(sn, sn, false, Image.FORMAT_R8)
	simg.fill(Color(SurfaceLayer.GRASS / 255.0, 0, 0))
	s.surface = SurfaceLayer.from_classes("s", sn, sn, ss, ORIGIN, ORIGIN, cls)
	s.surface_tex = ImageTexture.create_from_image(simg)
	s.look = Config.get_config("world").get("terrain_look", {})
	return s


## Параметры рельефа и вида — в материал (как GrassField.setup: apply_look_params + set_surface).
func apply(m: ShaderMaterial) -> void:
	m.set_shader_parameter("height_tex", height_tex)
	m.set_shader_parameter("layer_origin", Vector2(ORIGIN, ORIGIN))
	m.set_shader_parameter("layer_spacing", STEP)
	m.set_shader_parameter("layer_texels", Vector2(N, N))
	TerrainRenderer.apply_look_params(m, look)
	TerrainRenderer.set_surface(m, surface, surface_tex)
