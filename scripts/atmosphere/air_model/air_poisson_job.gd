class_name AirPoissonJob
extends AirGpuJob
## Решение ∇·(K∇φ) = f V-циклами порциями (AM-02) — пример наследника AirGpuJob и проверка
## каркаса; в итерации Пикара (AM-03) давление — один V-цикл на итерацию, тем же AirMultigrid.
## Шаг — один V-цикл. Невязка max|f − Cφ| / max|f| — в конце каждой порции (одно число с GPU).
## neumann: все грани закрыты → оператор вырожден: f и φ центрируются по активным клеткам.

const S_RES := 0
const S_F := 1
const S_SUM := 2
const S_CNT := 3

var dims := Vector3i.ZERO
var tol := 1e-5
var max_cycles := 200
var neumann := true
## Входы (CPU): грани cx, cy, cz, активность, правая часть.
var cx := PackedFloat32Array()
var cy := PackedFloat32Array()
var cz := PackedFloat32Array()
var active := PackedFloat32Array()
var rhs := PackedFloat32Array()
## Итог: невязка после последней порции, φ после result().
var residual := INF
var mg := AirMultigrid.new()
var phi := RID()
var f := RID()


func _setup() -> bool:
	var n := dims.x * dims.y * dims.z
	if n <= 0 or rhs.size() != n or active.size() != n:
		error = "AirPoissonJob: размеры входов не сходятся"
		return false
	var bcx := gpu.buffer(cx.size(), cx)
	var bcy := gpu.buffer(cy.size(), cy)
	var bcz := gpu.buffer(cz.size(), cz)
	var act := gpu.buffer(n, active)
	f = gpu.buffer(n, rhs)
	phi = gpu.buffer(n)
	mg.build(gpu, bcx, bcy, bcz, act, dims)
	if neumann:
		_center(f, act, n)
	gpu.reduce(AirGpu.Red.MAXABS, f, n, S_F)
	return true


func _center(x: RID, act: RID, n: int) -> void:
	gpu.reduce(AirGpu.Red.DOT, x, n, S_SUM, act)
	gpu.reduce(AirGpu.Red.SUM, act, n, S_CNT)
	gpu.axpy(-1.0, act, x, n, S_SUM, S_CNT)


func _record_step(_i: int) -> void:
	mg.vcycle(phi, f)


func _record_chunk_end() -> void:
	var lev: Dictionary = mg.levels[0]
	var n := dims.x * dims.y * dims.z
	if neumann:
		_center(phi, lev.act, n)
	gpu.stencil(lev.c, phi, f, lev.r, dims)
	gpu.reduce(AirGpu.Red.MAXABS, lev.r, n, S_RES)


func _after_sync() -> bool:
	var fm := gpu.read_scalar(S_F)
	residual = gpu.read_scalar(S_RES) / maxf(fm, 1e-30)
	if residual <= tol:
		return true
	if steps_done >= max_cycles:
		error = "V-циклы не сошлись за %d (невязка %.2e)" % [max_cycles, residual]
	return false


func _total_steps() -> int:
	return max_cycles


func _first_step_ms() -> float:
	return 2.0


## φ на CPU (после is_done()).
func result() -> PackedFloat32Array:
	return gpu.download(phi)
