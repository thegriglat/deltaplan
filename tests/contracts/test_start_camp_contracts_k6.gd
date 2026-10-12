extends TestCase
## Контракт SC-K6: маска примятой травы (GrassField.set_trample_mask / trample_at,
## WorldObjects.trample_mask): формат R8, привязка тексель <-> мир, края, вне маски.


func _grass_with(w: int, h: int, origin: Vector2, cell: float, px: Dictionary) -> GrassField:
	var img := Image.create(w, h, false, Image.FORMAT_R8)
	for k in px:
		var v: Vector2i = k
		img.set_pixel(v.x, v.y, Color(float(px[k]) / 255.0, 0, 0))
	var g := GrassField.new()
	g.set_trample_mask(img, origin, cell)
	return g


func test_texel_to_world() -> void:
	# тексель (3, 2): x в [10 + 3*0.5, +0.5), z в [-4 + 2*0.5, +0.5); центр = (11.75, -2.75)
	var g := _grass_with(8, 6, Vector2(10, -4), 0.5, {Vector2i(3, 2): 255})
	approx(g.trample_at(11.75, -2.75), 1.0, 0.001, "центр текселя")
	check(g.trample_at(11.75, -2.75) > g.trample_at(11.3, -2.75), "спад к соседнему центру")
	approx(g.trample_at(12.25, -2.75), 0.0, 0.001, "центр соседнего текселя справа")
	approx(g.trample_at(11.75, -2.25), 0.0, 0.001, "центр соседнего текселя ниже по z")
	approx(g.trample_at(12.0, -2.5), 0.25, 0.001, "угол четырёх текселей: билинейно 1/4")
	g.free()


func test_edges_and_outside() -> void:
	var g := _grass_with(4, 4, Vector2(0, 0), 1.0, {Vector2i(0, 0): 255, Vector2i(3, 3): 128})
	approx(g.trample_at(0.0, 0.0), 1.0, 0.001, "угол маски: значение крайнего текселя")
	approx(g.trample_at(0.1, 0.1), 1.0, 0.001, "внутри крайнего текселя")
	approx(g.trample_at(3.99, 3.99), 128.0 / 255.0, 0.001, "противоположный угол")
	approx(g.trample_at(-0.01, 1.0), 0.0, 0.0001, "левее маски")
	approx(g.trample_at(1.0, -0.01), 0.0, 0.0001, "выше маски (z)")
	approx(g.trample_at(4.0, 1.0), 0.0, 0.0001, "правее маски (край не включён)")
	approx(g.trample_at(1.0, 4.5), 0.0, 0.0001, "ниже маски")
	g.free()


func test_null_and_wrong_format_clear_mask() -> void:
	var g := _grass_with(4, 4, Vector2.ZERO, 1.0, {Vector2i(1, 1): 255})
	approx(g.trample_at(1.5, 1.5), 1.0, 0.001, "маска стоит")
	g.set_trample_mask(null, Vector2.ZERO, 1.0)
	approx(g.trample_at(1.5, 1.5), 0.0, 0.0001, "null снимает маску")
	g.set_trample_mask(Image.create(4, 4, false, Image.FORMAT_RGB8), Vector2.ZERO, 1.0)
	approx(g.trample_at(1.5, 1.5), 0.0, 0.0001, "не R8 — маски нет")
	g.free()


func test_trample_mask_dictionary() -> void:
	var wo := WorldObjects.new()
	wo.cfg = {
		"trample": {"enabled": true},
		"tents": {"types": {"dome2": {"half_size_m": [0.8, 1.3]}}},
	}
	var start := Vector3(500.0, 10.0, -300.0)
	wo.camp = [
		{"type": "dome2", "position": Vector3(520.0, 10.0, -300.0), "basis": Basis(), "yaw": 0.0}
	]
	var m := wo.trample_mask(start)
	var img: Image = m.image
	check(img.get_format() == Image.FORMAT_R8, "формат R8")
	check(img.get_width() == 512 and img.get_height() == 512, "256 м / 0,5 м = 512 текселей")
	approx(float(m.cell_m), 0.5, 1e-6, "cell_m")
	var o: Vector2 = m.origin
	approx(o.x, 500.0 - 128.0, 1e-3, "origin.x")
	approx(o.y, -300.0 - 128.0, 1e-3, "origin.y")
	var g := GrassField.new()
	g.set_trample_mask(img, o, float(m.cell_m))
	check(g.trample_at(520.0, -300.0) > 0.85, "под палаткой почти до земли")
	check(g.trample_at(500.0, -300.0) > 0.4, "круг разбега у старта")
	check(g.trample_at(510.0, -300.0) > 0.5, "тропинка палатка - старт")
	approx(g.trample_at(520.0, -290.0), 0.0, 0.001, "в стороне от палатки нетронуто")
	var ring := g.trample_at(520.0, -300.0 + 1.3 + 0.75)
	check(ring > 0.0 and ring < 0.9, "кольцо спада вокруг палатки: %.2f" % ring)
	g.free()
	wo.free()
	wo = WorldObjects.new()
	wo.cfg = {"trample": {"enabled": false}}
	check(wo.trample_mask(start).is_empty(), "выключено в конфиге - пустой словарь")
	wo.free()
