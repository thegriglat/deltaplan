extends TestCase
## SL-19 (SL-К5 v1): CPU-зеркало хеша «дерево в клетке» — эталон PCG2D посчитан независимо (python, 32-бит).

const REF := [
	[Vector2i(0, 0), 417608103, 90043601],
	[Vector2i(1, 0), 2647388618, 2239437279],
	[Vector2i(0, 1), 2313183303, 4026777116],
	[Vector2i(-1, -1), 505842200, 1816539540],
	[Vector2i(123, -457), 950953772, 2445393575],
	[Vector2i(-1000, 2000), 3230363909, 359089774],
	[Vector2i(65535, -65536), 2451472064, 2252029466],
	[Vector2i(-2147483648, 2147483647), 1112179373, 2678089288],
	[Vector2i(37, 91), 675739336, 2299807814],
	[Vector2i(-5, 3), 3027533690, 4077716739],
]


func test_hash_reference() -> void:
	for r in REF:
		var h := TreeCell.hash(r[0])
		check(TreeCell.hx(h) == r[1] and TreeCell.hy(h) == r[2], "PCG2D %s: %d %d" % [r[0], TreeCell.hx(h), TreeCell.hy(h)])


func test_present_offset_pos() -> void:
	# (0,0): h.x & 255 = 417608103 & 255 = 167; (1,0): 2647388618 & 255 = 202
	check(TreeCell.present(Vector2i(0, 0), 168) and not TreeCell.present(Vector2i(0, 0), 167), "present: порог d8")
	check(not TreeCell.present(Vector2i(1, 0), 202) and TreeCell.present(Vector2i(1, 0), 203), "present: порог d8 (1,0)")
	check(not TreeCell.present(Vector2i(5, 5), 0) , "d8 = 0 — нет дерева")
	var hx := 417608103
	var hy := 90043601
	var ex := (float((hx >> 8) & 0xFFF) / 4096.0 - 0.5) * 0.8
	var ey := (float((hy >> 8) & 0xFFF) / 4096.0 - 0.5) * 0.8
	var o := TreeCell.offset(Vector2i(0, 0))
	approx(o.x, ex, 1e-6, "offset.x")
	approx(o.y, ey, 1e-6, "offset.y")
	# отрицательный индекс: хеш 3027533690 > 2^31 — биты, а не знак
	var h := TreeCell.hash(Vector2i(-5, 3))
	var o2 := TreeCell.offset(Vector2i(-5, 3))
	approx(o2.x, (float((3027533690 >> 8) & 0xFFF) / 4096.0 - 0.5) * 0.8, 1e-6, "offset.x при бите знака")
	approx(o2.y, (float((4077716739 >> 8) & 0xFFF) / 4096.0 - 0.5) * 0.8, 1e-6, "offset.y при бите знака")
	check(h.x < 0 and h.y < 0, "Vector2i хранит 32 бита знаковыми")
	var p := TreeCell.pos(Vector2i(-5, 3), 8.0)
	approx(p.x, (-5 + 0.5 + o2.x) * 8.0, 1e-5, "pos.x")
	approx(p.y, (3 + 0.5 + o2.y) * 8.0, 1e-5, "pos.y")
	check(TreeCell.cell_of(p.x, p.y, 8.0) == Vector2i(-5, 3), "позиция в своей клетке")


func test_set_properties() -> void:
	# 10^4 клеток: позиция внутри клетки (±0,4), доля present ≈ d8/256, набор не зависит от «камеры»
	var n := 0
	var pres := 0
	for j in 100:
		for i in 100:
			var c := Vector2i(i - 50, j - 50)
			var p := TreeCell.pos(c, 8.0)
			check(TreeCell.cell_of(p.x, p.y, 8.0) == c, "дерево в своей клетке")
			n += 1
			if TreeCell.present(c, 204):
				pres += 1
	approx(float(pres) / n, 204.0 / 256.0, 0.02, "доля деревьев ≈ d8/256")
	check(TreeCell.variant(TreeCell.hash(Vector2i(3, 4)), 8) < 8, "вариант в диапазоне")


func test_hash2_reference() -> void:
	var ref := [
		[Vector2i(0, 0), 3950707002, 1804504796],
		[Vector2i(-5, 3), 2398967729, 1290884097],
		[Vector2i(123, -457), 3273034277, 241142256],
		[Vector2i(-1, -1), 1722971982, 3424893512],
	]
	for r in ref:
		var h2 := TreeCell.hash2(TreeCell.hash(r[0]))
		check(TreeCell.hx(h2) == r[1] and TreeCell.hy(h2) == r[2], "hash2 %s" % r[0])
	var h2 := TreeCell.hash2(TreeCell.hash(Vector2i(0, 0)))
	approx(TreeCell.height_t(h2), float(3950707002 & 0xFFFF) / 65536.0, 1e-9, "height_t")
	approx(TreeCell.color_t(h2), float(1804504796 & 0xFFFF) / 65536.0, 1e-9, "color_t")


func test_texel_forest_edges() -> void:
	# маска 10 м: 0 — лес, 1 — не лес, 2 — вода (G ≥ 0,35), 3 — лес; origin (0, 0)
	var img := Image.create(4, 1, false, Image.FORMAT_RG8)
	img.set_pixel(0, 0, Color(200 / 255.0, 0 / 255.0, 0.0))
	img.set_pixel(1, 0, Color(127 / 255.0, 0 / 255.0, 0.0))
	img.set_pixel(2, 0, Color(200 / 255.0, 90 / 255.0, 0.0))
	img.set_pixel(3, 0, Color(128 / 255.0, 88 / 255.0, 0.0))
	var p := TreePlacer.new()
	p.density = 0.8
	p.water_max = 0.35
	p.set_forest_mask(img, Vector2.ZERO, 10.0)
	check(p.texel_forest(0.1, 5.0) and p.texel_forest(9.9, 0.0), "тексель 0 — лес")
	check(not p.texel_forest(10.1, 5.0) and not p.texel_forest(19.9, 5.0), "тексель 1 — не лес")
	check(not p.texel_forest(25.0, 5.0), "тексель 2 — вода")
	check(p.texel_forest(35.0, 5.0), "тексель 3: R = 128, G = 88 < 89,25 — лес")
	check(p.d8_at(5.0, 5.0) == 204 and p.d8_at(15.0, 5.0) == 0, "d8: лес — 204, иначе 0")
