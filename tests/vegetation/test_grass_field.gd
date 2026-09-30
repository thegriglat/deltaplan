extends TestCase
## Тесты формул GrassField (без GPU — статические функции повторяют grass.gdshader,
## см. комментарии рядом с каждой функцией в scripts/terrain/grass_field.gd).

const AREA_RADIUS := 30.0
const FAR_DENSITY_MIN := 0.12
const THIN_START_K := 0.1
const THIN_END_K := 0.85
const FULL_M := 0.4
const ZERO_M := 1.2
const PRESS_RADIUS := 1.5


## Вершин травы в кольце 20–30 м в 5–8 раз меньше, чем в 0–10 м на единицу площади
## (усреднение плотности по кольцу с весом на площадь, как в шейдере).
func test_far_thinning_ratio() -> void:
	var near := _ring_avg_density(0.0, 10.0)
	var far := _ring_avg_density(20.0, 30.0)
	var ratio := near / far
	check(ratio >= 5.0 and ratio <= 8.0, "ratio 0-10 / 20-30 = %.2f (ждали 5..8)" % ratio)


func _ring_avg_density(r0: float, r1: float, n: int = 400) -> float:
	var num := 0.0
	var den := 0.0
	for i in n:
		var r := r0 + (r1 - r0) * (float(i) + 0.5) / n
		var w := r  # весом на площадь кольца (2*pi*r*dr, множитель сокращается)
		num += (
			GrassField
			. far_density(r, AREA_RADIUS, FAR_DENSITY_MIN, THIN_START_K, THIN_END_K)
			* w
		)
		den += w
	return num / den


func test_press_full_at_low_agl() -> void:
	var f := GrassField.press_factor(0.0, PRESS_RADIUS, 0.2, FULL_M, ZERO_M)
	check(f > 0.99, "приминание у ног пилота на земле должно быть полным: %.3f" % f)


func test_press_zero_above_1_2m() -> void:
	var f := GrassField.press_factor(0.0, PRESS_RADIUS, 1.5, FULL_M, ZERO_M)
	check(f < 0.01, "пилот в 1,5 м над землёй — приминания быть не должно: %.3f" % f)


func test_press_zero_far_from_pilot() -> void:
	var f := GrassField.press_factor(10.0, PRESS_RADIUS, 0.0, FULL_M, ZERO_M)
	check(f < 0.01, "далеко от пилота — приминания нет: %.3f" % f)


## Точка в прямоугольнике посадки — скошено, в 1 м за краем — нет.
func test_landing_rect_inside_and_outside() -> void:
	var center := Vector2(100.0, -50.0)
	var axis_deg := 30.0
	var length_m := 200.0
	var width_m := 30.0
	check(
		GrassField.in_landing_rect(center, center, axis_deg, length_m, width_m),
		"центр площадки — внутри"
	)
	var axis3 := TerrainGeo.heading_vector(axis_deg)
	var axis2 := Vector2(axis3.x, axis3.z)
	var right3 := axis3.cross(Vector3.UP)
	var right2 := Vector2(right3.x, right3.z)
	var edge_in := center + axis2 * (length_m * 0.5 - 1.0)
	check(
		GrassField.in_landing_rect(edge_in, center, axis_deg, length_m, width_m), "1 м до края — внутри"
	)
	var edge_out := center + axis2 * (length_m * 0.5 + 1.0)
	check(
		not GrassField.in_landing_rect(edge_out, center, axis_deg, length_m, width_m),
		"1 м за краем по длине — снаружи"
	)
	var side_out := center + right2 * (width_m * 0.5 + 1.0)
	check(
		not GrassField.in_landing_rect(side_out, center, axis_deg, length_m, width_m),
		"1 м за краем по ширине — снаружи"
	)


## Густота (grass.density_pct): пучков на площадь ∝ густоте, 0 — трава выключена;
## 100 % в конфиге — вдвое чаще прежнего шага 0,3 м, травинки вдвое тоньше 0,05 м.
func test_density_scales_clump_count() -> void:
	var g: Dictionary = Config.get_config("vegetation").get("grass", {})
	var base := float(g.clump_spacing_m)
	check(absf(pow(0.3 / base, 2.0) - 2.0) < 0.1, "пучков вдвое больше прежнего: шаг %.3f" % base)
	check(is_equal_approx(float(g.blade_width_m), 0.025), "травинка 0,025 м")
	for pct in [50.0, 100.0, 150.0, 200.0]:
		var s := GrassField.spacing_for_density(base, GrassField.density_k({"density_pct": pct}))
		var ratio := pow(base / s, 2.0)
		check(absf(ratio - pct / 100.0) < 1e-3, "%.0f%%: пучков ×%.3f" % [pct, ratio])
	check(not GrassField.is_enabled({"enabled": true, "density_pct": 0}), "0 % — выключена")
	check(GrassField.is_enabled({"enabled": true, "density_pct": 10}), "10 % — включена")
	check(not GrassField.is_enabled({"enabled": false, "density_pct": 100}), "enabled=false")
	var presets: Dictionary = Config.get_config("game").get("graphics_presets", {})
	for p: String in {"low": 0, "medium": 100, "high": 150}:
		var v: Variant = presets[p].configs.vegetation.grass.density_pct
		check(int(v) == {"low": 0, "medium": 100, "high": 150}[p], "пресет %s: %s %%" % [p, v])


## Трава под пологом (К2 v2): grass.forest_density/forest_height_m/forest_shade доходят до
## материала ближнего и дальнего слоя; по умолчанию плотность > 0; при 0 — на FOREST травы нет,
## как до SF-2.
func test_forest_grass_reaches_material() -> void:
	var g: Dictionary = Config.get_config("vegetation").grass
	var fd := float(g.forest_density)
	check(fd > 0.0 and fd < 1.0, "forest_density по умолчанию в (0; 1): %.2f" % fd)
	var fh := GrassField._v2(g.forest_height_m)
	var bh := GrassField._v2(g.blade_height_m)
	check(fh.y < bh.y and fh.x < bh.x, "под пологом ниже луга: %s < %s" % [fh, bh])
	check(float(g.forest_shade) > 0.0 and float(g.forest_shade) <= 1.0, "forest_shade ≤ 1")
	for density in [fd, 0.0]:
		var cfg := g.duplicate(true)
		cfg.forest_density = density
		var gf := _make_field(cfg)
		for m in gf.materials():
			var v := float(m.get_shader_parameter("forest_density"))
			check(is_equal_approx(v, density), "uniform forest_density = %.2f (%.2f)" % [v, density])
			var h: Vector2 = m.get_shader_parameter("forest_height_m")
			check(h.is_equal_approx(fh), "uniform forest_height_m = %s" % h)
			check(
				is_equal_approx(float(m.get_shader_parameter("forest_shade")), float(g.forest_shade)),
				"uniform forest_shade"
			)
		check(gf.materials().size() == 2, "ближний и дальний слой")
		gf.free()
	var sd := float(g.shrub_density)
	check(GrassField.class_share(SurfaceLayer.FOREST, sd, fd) == fd, "FOREST — forest_density")
	check(GrassField.class_share(SurfaceLayer.FOREST, sd, 0.0) == 0.0, "0 — травы в лесу нет")
	check(GrassField.class_share(SurfaceLayer.GRASS, sd, 0.0) == 1.0, "луг — все пучки")
	check(GrassField.class_share(SurfaceLayer.SHRUB, sd, fd) == sd, "кустарник — shrub_density")
	check(GrassField.class_share(SurfaceLayer.WATER, sd, fd) == 0.0, "вода — нет")


func _make_field(cfg: Dictionary) -> GrassField:
	var hl := HeightLayer.from_heights("t", 4, 4, 10.0, 0.0, 0.0, PackedFloat32Array([
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
	var cls := PackedByteArray()
	cls.resize(16)
	cls.fill(SurfaceLayer.FOREST)
	var sl := SurfaceLayer.from_classes("t", 4, 4, 10.0, 0.0, 0.0, cls)
	var gf := GrassField.new()
	var spots: Array[Vector4] = []
	gf.setup(hl, hl.make_texture(), sl, sl.make_texture(), {}, cfg, spots)
	return gf
