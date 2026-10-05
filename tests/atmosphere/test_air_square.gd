extends TestCase
## Квадрат воздуха AQ-1 (C2 v7): область 38,4 км вокруг точки старта целиком внутри слоя detail
## рантайма (геометрия — `TerrariumLoader._plan_layer`, конфиг world.json → runtime_terrain, без сети)
## на всех широтах; клетка = ровно dx на земле. Без GPU.


static func _detail_cfg() -> Dictionary:
	var cfg: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://configs/world.json"))
	for lc: Dictionary in cfg.runtime_terrain.layers:
		if String(lc.id) == "detail":
			return lc
	return {}


## Геометрия слоя detail на широте lat: {n, spacing, ox, oz}.
static func _plan(lat: float, lc: Dictionary) -> Dictionary:
	var ld := TerrariumLoader.new()
	var z := TerrariumLoader.layer_zoom(lc, lat)
	var p := ld._plan_layer(
		"detail", lat, 86.13, z, float(lc.size_km) * 1000.0, int(lc.chunk_cells)
	)
	ld.free()
	var o: Vector2 = p.origin
	return {n = int(p.n), spacing = float(p.spacing), ox = o.x, oz = o.y, z = z}


## Минимальный запас (м) узлов области [−L/2, L/2 − 25] до края слоя по четырём сторонам.
static func _margin(g: Dictionary) -> float:
	var half := AirPlace.DOMAIN_L / 2.0
	var lo := -half  # x и y первого узла
	var hi := half - AirPlace.NODE_STEP  # последний узел
	var ext := (int(g.n) - 1) * float(g.spacing)
	var mx := minf(lo - float(g.ox), float(g.ox) + ext - hi)
	# z = −y: узлы по z от −hi до −lo
	var mz := minf(-hi - float(g.oz), float(g.oz) + ext + lo)
	return minf(mx, mz)


func test_ongudai_domain_in_runtime_layer() -> void:
	var lc := _detail_cfg()
	check(not lc.is_empty(), "world.json: слой detail")
	var g := _plan(50.79, lc)
	var n := int(g.n)
	var hs := PackedFloat32Array()
	hs.resize(n * n)
	for j in n:
		for i in n:
			var x := float(g.ox) + i * float(g.spacing)
			var y := -(float(g.oz) + j * float(g.spacing))
			hs[j * n + i] = 1500.0 + 0.05 * x - 0.03 * y + 200.0 * sin(x * 0.0004)
	var l := HeightLayer.from_heights("detail", n, n, float(g.spacing), float(g.ox), float(g.oz), hs)
	var m := _margin(g)
	print("Онгудай: zoom %d, шаг %.3f м, слой %d², запас %.1f м" % [g.z, g.spacing, n, m])
	check(m >= 0.0, "область целиком в слое, запас %.1f м" % m)
	var loc := {id = "ongudai_geom", center_lat = 50.79, center_lon = 86.13, utc_offset_h = 7}
	var c := AirPlace.domain_case(l, null, loc, 400.0, 12.0, 3.0, 150.0, NAN, "clear", false)
	check(c != null, "domain_case не пустой")
	if c == null:
		return
	approx(c.dx, 400.0, 0.0, "dx = 400")
	check(c.nx == 96 and c.ny == 96, "96 × 96")
	approx(c.x0, -19200.0, 0.0, "x0 = −19 200")
	approx(c.y0, -19200.0, 0.0, "y0 = −19 200")
	# гладкое поле: среднее по клетке ≈ значение в её среднем узле (sin выпукло: допуск 1 м)
	var i := 40
	var j := 17
	var xm := c.x0 + 400.0 * i + 187.5
	var ym := c.y0 + 400.0 * j + 187.5
	var e := 1500.0 + 0.05 * xm - 0.03 * ym + 200.0 * sin(xm * 0.0004)
	approx(c.hc[j * 96 + i], e, 1.0, "клетка (40, 17) ≈ высота в среднем узле")


func test_latitude_sweep_margin() -> void:
	var lc := _detail_cfg()
	var worst := INF
	var worst_lat := 0.0
	var lats: Array[float] = []
	for k in range(-70, 71):
		lats.append(float(k))
	for k in 20:
		lats.append(82.0 + 0.1 * k)
	lats.append(83.9)
	lats.append(50.79)
	for lat in lats:
		var m := _margin(_plan(lat, lc))
		if m < worst:
			worst = m
			worst_lat = lat
		if m < 0.0:
			check(false, "широта %.2f°: область вылезает за слой на %.1f м" % [lat, -m])
	print("свип широт: минимальный запас %.1f м на %.1f°" % [worst, worst_lat])
	check(worst >= 0.0, "область 38,4 км в слое на всех широтах, мин. запас %.1f м" % worst)


func test_block_mean_timing_and_edges() -> void:
	# Узел ровно на краю слоя допустим, за краем — пусто.
	var n := 1665
	var hs := PackedFloat32Array()
	hs.resize(n * n)
	hs.fill(100.0)
	var s := 24.0
	var half := 0.5 * (n - 1) * s
	var l := HeightLayer.from_heights("detail", n, n, s, -half, -half, hs)
	var t0 := Time.get_ticks_usec()
	var hc := AirPlace.block_mean(l, -19200.0, -19200.0, 400.0, 96, 96)
	print("block_mean 96² на слое 1665²: %.2f с" % ((Time.get_ticks_usec() - t0) / 1.0e6))
	check(hc.size() == 96 * 96 and absf(hc[0] - 100.0) < 1.0e-9, "плоский слой — та же высота")
	var tight := HeightLayer.from_heights("detail", n, n, s, -19200.0, -19200.0, hs)
	# узлы x: −19 200 … 18 775; слой от −19 200 на 1664·24 = 39 936 → до 20 736: влезает
	check(AirPlace.block_mean(tight, -19200.0, -19200.0, 400.0, 96, 96).size() == 96 * 96, "узел на краю — внутри")
	check(AirPlace.block_mean(tight, -19225.0, -19200.0, 400.0, 96, 96).is_empty(), "за краем — пусто")
	check(AirPlace.block_mean(l, -19200.0, -19190.0, 400.0, 96, 96).is_empty(), "не кратно 25 м — пусто")
