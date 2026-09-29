class_name AirMultigrid
extends RefCounted
## V-цикл многосеточного метода для давления ∇·(K∇φ) = f на сетке с маской (AM-02).
## Оператор и огрубление — как в прикидке (tools/research/air3d/solver.py, класс MG; решение AM-01
## «маска, не σ-сетка» — tools/research/air3d/reference.md): 7-точечный шаблон из проводимостей
## граней c = K/h² (0 — закрыта), неактивная клетка — строка «1·φ = 0»; огрубление только по x, y
## (×2), пока NX, NY чётные и ≥ 6; грубые грани — сумма двух мелких / 8 (по z — среднее 4) и
## закрытие у неактивных; ограничение — среднее 2×2 × активность; продолжение — кусочно-
## постоянное × активность × corr; сглаживание — зебра-прогонки по z (pre/post раз), на самом
## грубом — coarse_sweeps раз по z, x, y. Другой оператор (например σ-сетка) — переопределить
## _level_stencil и/или _coarsen: V-цикл работает с любыми 7-точечными шаблонами уровней.

var gpu: AirGpu
## Уровни: {dims: Vector3i, c: RID (шаблон 7N), act: RID, r: RID, x: RID, f: RID (кроме 0-го)}.
var levels: Array[Dictionary] = []
var pre := 2
var post := 2
var coarse_sweeps := 20
var corr := 1.0


## Построить уровни на GPU из граней мелкого уровня: cx (NZ, NY, NX+1), cy (NZ, NY+1, NX),
## cz (NZ+1, NY, NX), act (NZ, NY, NX; 1 — воздух, 0 — земля).
## Только запись в список вычислений — без ожидания GPU.
func build(g: AirGpu, cx: RID, cy: RID, cz: RID, act: RID, dims: Vector3i) -> void:
	gpu = g
	levels.clear()
	var d := dims
	while true:
		var n := d.x * d.y * d.z
		var lev := {dims = d, act = act, c = gpu.buffer(7 * n), r = gpu.buffer(n)}
		_level_stencil(lev, cx, cy, cz)
		if not levels.is_empty():
			lev.x = gpu.buffer(n)
			lev.f = gpu.buffer(n)
		levels.append(lev)
		if d.x % 2 != 0 or d.y % 2 != 0 or d.x < 6 or d.y < 6:
			break
		var faces := _coarsen(d, cx, cy, cz, act)
		cx = faces[0]
		cy = faces[1]
		cz = faces[2]
		act = faces[3]
		d = Vector3i(d.x / 2, d.y / 2, d.z)


func _level_stencil(lev: Dictionary, cx: RID, cy: RID, cz: RID) -> void:
	var d: Vector3i = lev.dims
	gpu.mg_op(0, [cx, cy, cz], lev.act, lev.c, d, d.x * d.y * d.z)


## Грубые грани и активность уровня под d: [cx, cy, cz, act].
func _coarsen(d: Vector3i, cx: RID, cy: RID, cz: RID, act: RID) -> Array:
	var c := Vector3i(d.x / 2, d.y / 2, d.z)
	var nc := c.x * c.y * c.z
	var ac := gpu.buffer(nc)
	gpu.mg_op(1, [act], RID(), ac, d, nc)
	var n_x := (c.x + 1) * c.y * c.z
	var n_y := c.x * (c.y + 1) * c.z
	var n_z := c.x * c.y * (c.z + 1)
	var cxc := gpu.buffer(n_x)
	var cyc := gpu.buffer(n_y)
	var czc := gpu.buffer(n_z)
	gpu.mg_op(2, [cx], ac, cxc, d, n_x)
	gpu.mg_op(3, [cy], ac, cyc, d, n_y)
	gpu.mg_op(4, [cz], ac, czc, d, n_z)
	return [cxc, cyc, czc, ac]


## Один V-цикл: x ← x + приближённое решение C·e = f − C·x (x, f — поля мелкого уровня).
func vcycle(x: RID, f: RID, li := 0) -> void:
	var lev := levels[li]
	var d: Vector3i = lev.dims
	if li == levels.size() - 1:
		for _i in coarse_sweeps:
			gpu.zebra(lev.c, x, f, d, [2, 0, 1])
		return
	for _i in pre:
		gpu.zebra(lev.c, x, f, d, [2])
	gpu.stencil(lev.c, x, f, lev.r, d)
	var cl := levels[li + 1]
	var cd: Vector3i = cl.dims
	var nc := cd.x * cd.y * cd.z
	gpu.mg_op(5, [lev.r], cl.act, cl.f, d, nc)
	gpu.fill(cl.x, nc)
	vcycle(cl.x, cl.f, li + 1)
	gpu.mg_op(6, [cl.x], lev.act, x, d, d.x * d.y * d.z, corr)
	for _i in post:
		gpu.zebra(lev.c, x, f, d, [2])
