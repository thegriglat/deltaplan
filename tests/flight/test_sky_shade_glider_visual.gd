extends TestCase
## Узел SkyShade у визуала планера (PH-8, PH-К7): декаль на слое, видимом обеим камерам; чёрная
## (без цвета); пятно сходится к ногам у земли и пропадает выше h_max; один узел, без теней.

const GLIDER_SCENE := preload("res://scenes/glider/glider.tscn")
const GROUND := 10.0


func _glider(h_above: float) -> Glider:
	var g: Glider = GLIDER_SCENE.instantiate()
	g.auto_start = Glider.AutoStart.NONE
	Engine.get_main_loop().current_scene.add_child(g)
	g.setup("training", 80.0)
	g.set_ground_fn(func(_x: float, _z: float) -> float: return GROUND)
	g.set_air_fn(func(_p: Vector3) -> Vector3: return Vector3.ZERO)
	g.reset_in_air(Vector3(0, GROUND + h_above, 0), 0.0)
	g._process(1.0 / 60.0)
	return g


func test_sky_shade_glider_visual_node_and_layers() -> void:
	var g := _glider(3.0)
	var ss := g.visual.sky_shade
	check(ss != null, "у визуала есть SkyShade")
	if ss == null:
		g.free()
		return
	check(g.visual.find_children("*", "Decal", true, false).size() == 1, "ровно одна декаль")
	var d := ss.get_node("Decal") as Decal
	ss._process(1.0 / 60.0)
	check(d.visible, "декаль видна у земли")
	# слой 1 рисуют и кабинная (все, кроме скрытого), и внешние камеры (все, кроме «только кабина»)
	var hidden_bit := 1 << (int(Config.value("camera", "cockpit.hidden_layer", 20)) - 1)
	check((d.layers & 1) != 0, "слой 1")
	check((d.layers & (0xFFFFF & ~hidden_bit)) != 0, "видна кабинной камере")
	check((d.layers & (0xFFFFF & ~GliderVisual.COCKPIT_ONLY_LAYER)) != 0, "видна внешним камерам")
	check(d.texture_albedo is ImageTexture, "текстура процедурная")
	var img := ss._img
	var mid := img.get_pixel(SkyShade.TEX_N / 2, SkyShade.TEX_N / 2)
	check(mid.r == 0.0 and mid.g == 0.0 and mid.b == 0.0, "нейтрально: только затемнение, цвета нет")
	check(mid.a > 0.05, "в середине пятна затемнение: %.3f" % mid.a)
	var corner := img.get_pixel(0, 0)
	check(corner.a < 0.01, "край текстуры прозрачен (%.3f)" % corner.a)
	g.free()


func test_sky_shade_glider_visual_center_darkening_grows_toward_ground() -> void:
	var g := _glider(1.5)
	var ss := g.visual.sky_shade
	ss._process(1.0 / 60.0)
	var near_a: float = ss._img.get_pixel(SkyShade.TEX_N / 2, SkyShade.TEX_N / 2).a
	var h_low: float = ss.last_h
	g.reset_in_air(Vector3(0, GROUND + 9.0, 0), 0.0)
	g._process(1.0 / 60.0)
	ss._bake_t = 0.0
	ss._process(1.0 / 60.0)
	var far_a: float = ss._img.get_pixel(SkyShade.TEX_N / 2, SkyShade.TEX_N / 2).a
	check(ss.last_h > h_low + 4.0, "высота обновилась: %.1f -> %.1f" % [h_low, ss.last_h])
	check(near_a > far_a, "у земли пятно плотнее: %.3f > %.3f" % [near_a, far_a])
	g.free()


func test_sky_shade_glider_visual_hidden_above_h_max() -> void:
	var g := _glider(30.0)
	var ss := g.visual.sky_shade
	ss._process(1.0 / 60.0)
	check(not (ss.get_node("Decal") as Decal).visible, "выше h_max декали нет")
	g.free()


func test_sky_shade_glider_visual_cost_bounded() -> void:
	# цена: пересчёт текстуры не чаще bake_hz, пока высота не меняется — не пересчитывается вовсе
	var g := _glider(3.0)
	var ss := g.visual.sky_shade
	ss._process(1.0 / 60.0)
	var b0: int = ss.bakes
	for i in 120:
		ss._process(1.0 / 60.0)
	check(ss.bakes - b0 <= 1, "без изменения h текстура не пересчитывается: +%d" % (ss.bakes - b0))
	g.free()
