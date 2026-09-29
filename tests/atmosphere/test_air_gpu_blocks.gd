extends TestCase
## Строительные блоки модели воздуха на GPU (AM-02) против эталона float64
## (tools/research/air3d/gpu_block_refs.py → tests/atmosphere/fixtures/air_model/blocks/).
## Нужен настоящий RenderingDevice: tools/gpu_tests.sh --filter=test_air_gpu.
## В headless пропускается.
## Замеры времени блоков: AIR_GPU_BENCH=1 tools/gpu_tests.sh --filter=test_air_gpu_blocks.

const FIX := "res://tests/atmosphere/fixtures/air_model/blocks/"
const TOL := 1e-5


func needs_gpu() -> bool:
	return true


static func load_case(name: String) -> Dictionary:
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(FIX + name + ".json"))
	var all := FileAccess.get_file_as_bytes(FIX + name + ".bin").to_float32_array()
	var data := {}
	for k in meta.arrays:
		var o: Array = meta.arrays[k]
		data[k] = all.slice(int(o[0]), int(o[0]) + int(o[1]))
	meta.data = data
	var d: Array = meta.dims
	meta.v = Vector3i(int(d[0]), int(d[1]), int(d[2]))
	return meta


## max|a − b| / max|b|.
static func rel_err(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	if a.size() != b.size():
		return INF
	var e := 0.0
	var m := 0.0
	for i in b.size():
		e = maxf(e, absf(a[i] - b[i]))
		m = maxf(m, absf(b[i]))
	return e / maxf(m, 1e-30)


## Число в виде 1.23e-06 (у % в GDScript нет %e).
static func sci(v: float) -> String:
	if v == 0.0 or is_nan(v) or is_inf(v):
		return str(v)
	var e := floori(log(absf(v)) / log(10.0))
	return "%.2fe%+03d" % [v / pow(10.0, e), e]


func _gpu() -> AirGpu:
	var g := AirGpu.new()
	if not g.init():
		failures.append("AirGpu.init: " + g.error)
		return null
	return g


func _row(table: Array, block: String, size: String, err: float) -> void:
	table.append([block, size, err])
	check(err <= TOL, "%s %s: отн. ошибка %s > %s" % [block, size, sci(err), sci(TOL)])


func test_blocks_vs_reference() -> void:
	var g := _gpu()
	if g == null:
		return
	var table := []
	_vec_blocks(g, table)
	for name in ["lines", "lines_long", "lines_mp_x", "lines_mp_y"]:
		_line_blocks(g, name, table)
	_mg_blocks(g, table)
	g.release()
	print("  блок | размер | отн. ошибка")
	for r in table:
		print("  %s | %s | %s" % [r[0], r[1], sci(r[2])])


func _vec_blocks(g: AirGpu, table: Array) -> void:
	var c := load_case("vec")
	var dat: Dictionary = c.data
	var x: PackedFloat32Array = dat.x
	var n := x.size()
	var bx := g.buffer(n, x)
	var bp := g.buffer(n, dat.p)
	var y := g.buffer(n)
	var ops := [
		["axpy", AirGpu.Vec.AXPY, float(c.a), 0.0],
		["xpay", AirGpu.Vec.XPAY, float(c.b), 0.0],
		["axpby", AirGpu.Vec.AXPBY, 1.3, -0.4],
		["scale", AirGpu.Vec.SCALE, 2.5, 0.0],
		["mul", AirGpu.Vec.MUL, 1.0, 0.0],
	]
	for o in ops:
		g.upload(y, dat.y)
		g.vec(o[1], bx, y, n, o[2], o[3])
		g.submit()
		g.sync()
		_row(table, o[0], str(n), rel_err(g.download(y), dat[o[0]]))
	# редукции: сумма — относительно Σ|·| (у суммы разных знаков относительная ошибка не определена)
	var by := g.buffer(n, dat.y)
	var red: Dictionary = c.reductions
	var n2 := int(c.n2)
	g.reduce(AirGpu.Red.SUM, bp, n, 0)
	g.reduce(AirGpu.Red.SUM, bx, n, 1)
	g.reduce(AirGpu.Red.MAXABS, bx, n, 2)
	g.reduce(AirGpu.Red.DOT, bx, n, 3, by)
	g.reduce(AirGpu.Red.SUM, bp, n2, 4)
	g.reduce(AirGpu.Red.DOT, bx, n2, 5, by)
	g.submit()
	g.sync()
	var s := g.download(g.scalars, 6)
	var rows := [
		["sum (x>0)", s[0], red.sum_p, red.sum_p, n],
		["sum (±)", s[1], red.sum_x, red.sumabs_x, n],
		["max|x|", s[2], red.maxabs_x, red.maxabs_x, n],
		["dot", s[3], red.dot_xy, red.sumabs_xy, n],
		["sum (x>0)", s[4], red.sum_p_n2, red.sum_p_n2, n2],
		["dot", s[5], red.dot_xy_n2, red.sumabs_xy_n2, n2],
	]
	for r in rows:
		_row(table, r[0], str(r[4]), absf(r[1] - r[2]) / absf(r[3]))


func _line_blocks(g: AirGpu, name: String, table: Array) -> void:
	var c := load_case(name)
	var dat: Dictionary = c.data
	var d: Vector3i = c.v
	var n := d.x * d.y * d.z
	var sz := "%dx%dx%d" % [d.x, d.y, d.z]
	var bc := g.buffer(7 * n, dat.C)
	var bb := g.buffer(n, dat.b)
	var x := g.buffer(n)
	var xo := g.buffer(n)
	if dat.has("resid"):
		g.upload(x, dat.x0)
		g.stencil(bc, x, bb, xo, d)
		g.submit()
		g.sync()
		_row(table, "resid7", sz, rel_err(g.download(xo), dat.resid))
		g.stencil(bc, x, bb, xo, d, true)
		g.submit()
		g.sync()
		_row(table, "apply7", sz, rel_err(g.download(xo), dat.apply))
	for dir in 3:
		var nm: String = ["x", "y", "z"][dir]
		if not dat.has("zebra_" + nm):
			continue
		var kind := "многопр." if d[dir] > AirGpu.LINE_MAX else "разд."
		g.upload(x, dat.x0)
		g.line(bc, x, bb, d, dir, 0)
		g.line(bc, x, bb, d, dir, 1)
		g.submit()
		g.sync()
		_row(table, "прогонка %s зебра (%s, n=%d)" % [nm, kind, d[dir]], sz,
			rel_err(g.download(x), dat["zebra_" + nm]))
		g.upload(x, dat.x0)
		g.line(bc, x, bb, d, dir, -1, xo)
		g.submit()
		g.sync()
		_row(table, "прогонка %s все линии (%s)" % [nm, kind], sz,
			rel_err(g.download(xo), dat["all_" + nm]))


func _mg_blocks(g: AirGpu, table: Array) -> void:
	var c := load_case("mg")
	var dat: Dictionary = c.data
	var d: Vector3i = c.v
	var n := d.x * d.y * d.z
	var sz := "%dx%dx%d" % [d.x, d.y, d.z]
	var mg := AirMultigrid.new()
	var act := g.buffer(n, dat.act)
	mg.build(
		g, g.buffer(dat.cx.size(), dat.cx), g.buffer(dat.cy.size(), dat.cy),
		g.buffer(dat.cz.size(), dat.cz), act, d
	)
	var f := g.buffer(n, dat.f)
	var x := g.buffer(n)
	mg.vcycle(x, f)
	g.submit()
	g.sync()
	check(mg.levels.size() == (c.levels as Array).size(), "число уровней как в эталоне")
	_row(table, "шаблон уровня 0", sz, rel_err(g.download(mg.levels[0].c), dat.C0))
	_row(table, "шаблон уровня 1", "%dx%dx%d" % [d.x / 2, d.y / 2, d.z],
		rel_err(g.download(mg.levels[1].c), dat.C1))
	_row(table, "V-цикл ×1", sz, rel_err(g.download(x), dat.x1))
	for _i in 4:
		mg.vcycle(x, f)
	g.submit()
	g.sync()
	_row(table, "V-цикл ×5", sz, rel_err(g.download(x), dat.x5))
