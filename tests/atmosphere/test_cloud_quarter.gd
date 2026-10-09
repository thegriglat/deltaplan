extends TestCase
## Марш облаков по четвертям (PF-7): за 4 кадра обхода (CloudCompositorEffect.QUARTER_ORDER)
## луч проходит через каждый пиксель буфера облаков, в том числе на нечётном краю; за кадр —
## не больше одного луча на блок 2×2. Формула пикселя — как в cloud_raymarch_cs и
## cloud_temporal_cs: min(q·2 + смещение, low − 1).


static func _pixel(q: Vector2i, ofs: Vector2i, low: Vector2i) -> Vector2i:
	return (q * 2 + ofs).min(low - Vector2i.ONE)


func test_order_is_permutation() -> void:
	var seen := {}
	for o: Vector2i in CloudCompositorEffect.QUARTER_ORDER:
		check(o.x in [0, 1] and o.y in [0, 1], "смещение %s в блоке 2×2" % o)
		seen[o] = true
	check(seen.size() == 4, "4 разных смещения за обход")


func test_cover_all_pixels() -> void:
	for low: Vector2i in [Vector2i(960, 540), Vector2i(653, 368), Vector2i(1, 1), Vector2i(7, 3)]:
		var qn := (low + Vector2i.ONE) / 2
		var hit := {}
		for o: Vector2i in CloudCompositorEffect.QUARTER_ORDER:
			var frame := {}
			for qy in qn.y:
				for qx in qn.x:
					var p := _pixel(Vector2i(qx, qy), o, low)
					check(p.x >= 0 and p.y >= 0, "пиксель в буфере")
					frame[p] = true
					hit[p] = true
			# Свежесть в сборке (cloud_temporal_cs): пиксель свежий, если он — пиксель своей ячейки.
			var bad := 0
			for y in low.y:
				for x in low.x:
					var p := Vector2i(x, y)
					if (_pixel(p / 2, o, low) == p) != frame.has(p):
						bad += 1
			check(bad == 0, "%s %s: свежесть пикселя узнаётся (ошибок %d)" % [low, o, bad])
		check(hit.size() == low.x * low.y, "%s: покрыты все пиксели за 4 кадра (%d из %d)" % [
			low, hit.size(), low.x * low.y])
