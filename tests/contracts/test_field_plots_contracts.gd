extends TestCase
## Контракт К10 (docs/contracts/easter-eggs.md): FieldPlots — зеркало участков полей шейдера рельефа.
## Эталон hash12 посчитан один раз формулой шейдера во float32 (numpy), значения зафиксированы здесь.

const REF := [
	[0, 0, 0.0],
	[1, 0, 0.8985977172851562],
	[0, 1, 0.9709186553955078],
	[3, -2, 0.8526611328125],
	[-5, 7, 0.412109375],
	[12, 40, 0.63616943359375],
	[-100, 55, 0.232421875],
	[4095, 4095, 0.7564697265625],
	[4097, -4097, 0.264739990234375],
	[1234, -567, 0.713623046875],
	[33, 19, 0.64013671875],
]
## hash12(cell + 7.0) и hash12(cell + 19.1) (float32).
const REF_OFFS := [
	[3, -2, 0.26324462890625, 0.780029296875],
	[12, 40, 0.859375, 0.54180908203125],
	[-5, 7, 0.6978759765625, 0.279296875],
]


func _fp() -> FieldPlots:
	return FieldPlots.new(Vector2(260.0, 140.0))


func test_hash12_reference() -> void:
	for r in REF:
		var v := FieldPlots.hash12(Vector2(r[0], r[1]))
		check(absf(v - float(r[2])) < 1e-6, "hash12(%s,%s)=%s, эталон %s" % [r[0], r[1], v, r[2]])


func test_offset_hashes() -> void:
	var fp := _fp()
	for r in REF_OFFS:
		var c := Vector2i(r[0], r[1])
		check(absf(fp.brightness(c) - (0.85 + 0.3 * float(r[2]))) < 1e-6, "brightness %s" % c)
		var ax := fp.rows_axis(c)
		var want := Vector2(1, 0) if float(r[3]) < 0.5 else Vector2(0, 1)
		check(ax == want, "rows_axis %s = %s, ждали %s" % [c, ax, want])
		check(is_equal_approx(ax.length(), 1.0), "rows_axis единичный")


func test_point_inside_rect() -> void:
	var fp := _fp()
	var rng := RandomNumberGenerator.new()
	rng.seed = 10
	for i in 400:
		var x := rng.randf_range(-20000.0, 20000.0)
		var z := rng.randf_range(-20000.0, 20000.0)
		var c := fp.cell_at(x, z)
		var r := fp.rect(c).grow(0.01)
		check(r.has_point(Vector2(x, z)), "точка (%s,%s) вне rect %s" % [x, z, fp.rect(c)])
		check(fp.rect(c).get_center().is_equal_approx(fp.center(c)), "center = центр rect")


func test_row_shift() -> void:
	var fp := _fp()
	# внутри полосы из 6 рядов границы по x не сдвигаются между соседними рядами
	check(fp.rect(Vector2i(0, 0)).position == Vector2(0, 0), "ряд 0")
	check(fp.rect(Vector2i(2, 5)).position == Vector2(520, 700), "ряд 5 той же полосы")
	# ряд 6 — новая полоса: x_min = (cell.x - 0.37) * 260
	var r6 := fp.rect(Vector2i(0, 6))
	check(absf(r6.position.x + 0.37 * 260.0) < 1e-3, "ряд 6 сдвинут на 0.37: %s" % r6.position)
	check(absf(r6.position.y - 840.0) < 1e-3, "z_min ряда 6")
	check(fp.cell_at(r6.position.x + 1.0, r6.position.y + 1.0) == Vector2i(0, 6), "cell_at ряда 6")
	check(fp.cell_at(r6.position.x - 1.0, r6.position.y + 1.0) == Vector2i(-1, 6), "слева от ряда 6")
	var r12 := fp.rect(Vector2i(0, 12))
	check(absf(r12.position.x + 0.74 * 260.0) < 1e-3, "ряд 12 сдвинут на 0.74")
	var rm := fp.rect(Vector2i(0, -1))  # полоса -1: сдвиг -(-0.37)
	check(absf(rm.position.x - 0.37 * 260.0) < 1e-3, "ряд -1 (полоса -1): %s" % rm.position)
	check(fp.cell_at(rm.position.x + 1.0, rm.position.y + 1.0) == Vector2i(0, -1), "cell_at ряда -1")


func test_kind_thresholds() -> void:
	var fp := _fp()
	var seen := {}
	for i in 60:
		for j in 60:
			var c := Vector2i(i - 30, j - 30)
			var fh := fp.tone(c)
			var k := fp.kind(c)
			seen[k] = true
			if fh < 0.45:
				check(k == FieldPlots.STANDING, "STANDING fh=%s" % fh)
			elif fh < FieldPlots.MOWN_MIN:
				check(k == FieldPlots.GREEN, "GREEN fh=%s" % fh)
			else:
				check(k == FieldPlots.MOWN, "MOWN fh=%s" % fh)
	check(seen.size() == 3, "встречаются все три класса: %s" % seen.keys())
	check(FieldPlots.STANDING_MAX == 0.45, "порог колосьев 0.45")


func test_size_from_config() -> void:
	var fp := FieldPlots.from_world_config()
	var a: Array = Config.value("world", "terrain_look.field_size_m")
	check(fp.size_m == Vector2(float(a[0]), float(a[1])), "размер из world.json: %s" % fp.size_m)
