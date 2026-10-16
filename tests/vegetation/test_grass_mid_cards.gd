extends TestCase
## Атлас карточек-пучков (G4 v4, GR-21, GrassMidCards): без GPU — проверка данных атласа.
## (1) Кайма: у каждого кадра на мипе 0 полосы MARGIN_PX сбоку и сверху прозрачны, на мипах 1–3 —
##     крайний столбец и строка сверху почти прозрачны (контур квада не проступает вдали).
## (2) Под нулевой альфой — тон травинок (серый 0,8–1), не чёрный и не чужой цвет.
## (3) Поправка покрытия по мипам: множители ≥ 1, не убывают с мипом; на мипе 3 с поправкой доля
##     пикселей выше порога — как на мипе 0 (±30 %), без поправки — заметно меньше.
## (4) Средняя модуляция видимых пикселей — 0,7…1,1 (нормировка в шейдере обратная).


func _layers() -> Array[Image]:
	return GrassMidCards._layer_images(GrassMidCards.load_atlas())


func test_atlas_is_array_with_mipmaps() -> void:
	var a := GrassMidCards.load_atlas()
	check(a is Texture2DArray, "атлас — Texture2DArray")
	check(a.get_layers() == GrassMidCards.VARIANTS, "кадров")
	check(a.get_width() == GrassMidCards.CELL_PX, "кадр, px")
	check(a.has_mipmaps(), "мипмапы")


func test_atlas_margin_transparent() -> void:
	var m := GrassMidCards.MARGIN_PX
	for img in _layers():
		var w := img.get_width()
		var worst := 0.0
		for y in w:
			for x in w:
				if x < m or x >= w - m or y < m:
					worst = maxf(worst, img.get_pixel(x, y).a)
		check(worst < 0.1, "кайма мипа 0 прозрачна: альфа до %.3f" % worst)
		for k in range(1, 4):
			var mip := img.duplicate() as Image
			var sz := w >> k
			_to_mip(mip, k)
			var edge := 0.0
			for i in sz:
				edge = maxf(edge, maxf(mip.get_pixel(0, i).a, mip.get_pixel(sz - 1, i).a))
				edge = maxf(edge, mip.get_pixel(i, 0).a)
			check(edge < 0.15, "мип %d: край кадра почти прозрачен, альфа до %.3f" % [k, edge])


func test_atlas_tone_under_zero_alpha() -> void:
	for img in _layers():
		var w := img.get_width()
		var lo := 1.0
		var chroma := 0.0
		for y in w:
			for x in w:
				var c := img.get_pixel(x, y)
				lo = minf(lo, c.r)
				chroma = maxf(chroma, maxf(absf(c.r - c.g), absf(c.r - c.b)))
		check(chroma < 0.06, "серый тон: разница каналов до %.3f" % chroma)
		check(lo > 0.7, "тон не ниже 0,7 (и под нулевой альфой): %.3f" % lo)


func test_coverage_scales() -> void:
	var a := GrassMidCards.load_atlas()
	var s := GrassMidCards.coverage_scales(a)
	check(s.size() == GrassMidCards.MIP_LEVELS, "уровней")
	for k in s.size():
		check(s[k] >= 1.0, "множитель мипа %d ≥ 1: %.3f" % [k, s[k]])
		if k > 0:
			check(s[k] >= s[k - 1] - 0.05, "не убывает: мип %d %.3f" % [k, s[k]])
	var cut := GrassMidCards.ALPHA_CUT
	var c0 := 0.0
	var c3 := 0.0
	var c3s := 0.0
	var n0 := 0
	var n3 := 0
	for img in _layers():
		var w := img.get_width()
		for y in w:
			for x in w:
				c0 += 1.0 if img.get_pixel(x, y).a > cut else 0.0
				n0 += 1
		var mip := img.duplicate() as Image
		_to_mip(mip, 3)
		var sz := w >> 3
		for y in sz:
			for x in sz:
				var al := mip.get_pixel(x, y).a
				c3 += 1.0 if al > cut else 0.0
				c3s += 1.0 if al * s[3] > cut else 0.0
				n3 += 1
	var f0 := c0 / n0
	var f3 := c3 / n3
	var f3s := c3s / n3
	print("    cards: покрытие мип 0 %.3f, мип 3 %.3f, с поправкой ×%.2f %.3f; множители %s" % [f0, f3, s[3], f3s, s])
	check(absf(f3s / f0 - 1.0) < 0.3, "мип 3 с поправкой: %.3f против %.3f" % [f3s, f0])


func test_mean_modulation() -> void:
	var m := GrassMidCards.mean_modulation(GrassMidCards.load_atlas(), Vector2(0.8, 1.1))
	print("    cards: средняя модуляция видимых пикселей %.3f" % m)
	check(m > 0.7 and m < 1.1, "средняя модуляция %.3f" % m)


## Оставить в img только мип k (как картинку sz×sz).
func _to_mip(img: Image, k: int) -> void:
	var off := img.get_mipmap_offset(k)
	var sz := img.get_width() >> k
	var data := img.get_data().slice(off, off + sz * sz * 4)
	img.set_data(sz, sz, false, Image.FORMAT_RGBA8, data)


## GR-25: атлас полос (strip) — кадры STRIP_CELL с мипмапами, кайма сверху (MARGIN_PX/2) и по торцам
## (MARGIN_PX) прозрачна, у торцов стебли ниже (огибающая): верхняя половина у торцов почти пуста.
func test_strip_atlas() -> void:
	var a := GrassMidCards.load_atlas("strip")
	var cs := GrassMidCards.STRIP_CELL
	check(a.get_layers() == GrassMidCards.VARIANTS, "кадров полосы")
	check(a.get_width() == cs.x and a.get_height() == cs.y, "кадр полосы %dx%d" % [a.get_width(), a.get_height()])
	check(a.has_mipmaps(), "мипмапы полосы")
	var m := GrassMidCards.MARGIN_PX
	for img in GrassMidCards._layer_images(a):
		var worst := 0.0
		var end_top := 0.0
		var mid_top := 0.0
		for y in cs.y:
			for x in cs.x:
				var al := img.get_pixel(x, y).a
				if x < m or x >= cs.x - m or y < m / 2:
					worst = maxf(worst, al)
				if y < cs.y / 2:
					if x < m + cs.x / 20 or x >= cs.x - m - cs.x / 20:
						end_top += al
					elif absf(x - cs.x * 0.5) < cs.x / 20:
						mid_top += al
		check(worst < 0.1, "кайма полосы прозрачна: альфа до %.3f" % worst)
		check(end_top < mid_top, "у торцов стебли ниже: %.1f против %.1f" % [end_top, mid_top])
	var s := GrassMidCards.coverage_scales(a)
	check(s.size() == GrassMidCards.MIP_LEVELS and s[0] >= 1.0, "поправка покрытия полосы")
	var mm := GrassMidCards.mean_modulation(a, Vector2(0.8, 1.1))
	check(mm > 0.7 and mm < 1.1, "средняя модуляция полосы %.3f" % mm)
