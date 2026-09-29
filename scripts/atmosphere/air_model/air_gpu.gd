class_name AirGpu
extends RefCounted
## Строительные блоки модели воздуха на локальном RenderingDevice (AM-02, docs/air_model_gpu.md).
## Все операции только записываются в текущий список вычислений (без ожидания GPU); выполнение —
## submit() / sync() (порциями — AirGpuJob). Барьер — после каждого запуска ядра.
## Поля — буферы float32, раскладка (NZ, NY, NX): индекс (k·NY + j)·NX + i. Шаблон — 7 плоскостей
## по N (0 центр, 1 −x, 2 +x, 3 −y, 4 +y, 5 −z, 6 +z). Скаляры (редукции) — буфер scalars
## (SCALARS чисел), читаются на CPU только после sync().

enum Vec { FILL, COPY, SCALE, AXPY, XPAY, AXPBY, MUL }
enum Red { SUM, MAXABS, DOT }

const DIR := "res://scripts/atmosphere/air_model/"
const SHADERS := ["air_vec", "air_reduce", "air_stencil", "air_line", "air_line_mp", "air_mg"]
const SCALARS := 64
const RED_GROUPS := 1024
const LINE_MAX := 1024

var rd: RenderingDevice
var error := ""
var scalars := RID()
var dispatches := 0

var _shader := {}
var _pipe := {}
var _sets := {}
var _owned: Array[RID] = []
var _scratch := {}
var _part := RID()
var _dummy := RID()
var _cl := -1


## Создать локальный RD и собрать ядра. false — error объясняет (нет RD, ошибка компиляции).
func init() -> bool:
	if DisplayServer.get_name() == "headless":
		error = "нет RenderingDevice: headless"
		return false
	rd = RenderingServer.create_local_rendering_device()
	if rd == null:
		error = "нет RenderingDevice (драйвер без Vulkan/D3D12 или режим совместимости)"
		return false
	for s in SHADERS:
		var file := load(DIR + s + ".glsl") as RDShaderFile
		if file == null:
			error = "нет ядра %s.glsl" % s
			return false
		var spirv := file.get_spirv()
		if spirv == null or spirv.compile_error_compute != "":
			error = "ошибка компиляции %s.glsl: %s" % [
				s, spirv.compile_error_compute if spirv else "нет SPIR-V"
			]
			return false
		var sh := rd.shader_create_from_spirv(spirv, s)
		if not sh.is_valid():
			error = "драйвер не принял ядро %s.glsl" % s
			return false
		_shader[s] = sh
	scalars = buffer(SCALARS)
	_part = buffer(RED_GROUPS)
	_dummy = buffer(4)
	return true


## Освободить всё (буферы, наборы, конвейеры, ядра) и сам RD.
func release() -> void:
	if rd == null:
		return
	if _cl >= 0:
		rd.compute_list_end()
		_cl = -1
	for s in _sets.values():
		if rd.uniform_set_is_valid(s):
			rd.free_rid(s)
	for b in _owned:
		rd.free_rid(b)
	for p in _pipe.values():
		rd.free_rid(p)
	for s in _shader.values():
		rd.free_rid(s)
	_sets.clear()
	_owned.clear()
	_pipe.clear()
	_shader.clear()
	_scratch.clear()
	rd.free()
	rd = null


# ---------------------------------------------------------------- буферы


## Буфер из n float32 (данные — по желанию; без данных — нули).
func buffer(n: int, data := PackedFloat32Array()) -> RID:
	var bytes := data.to_byte_array() if data.size() == n else PackedByteArray()
	if bytes.is_empty():
		bytes.resize(n * 4)
	var b := rd.storage_buffer_create(n * 4, bytes)
	_owned.append(b)
	return b


func free_buffer(b: RID) -> void:
	for k in _sets.keys():
		if String(k).contains("#%d," % b.get_id()):
			rd.free_rid(_sets[k])
			_sets.erase(k)
	_owned.erase(b)
	rd.free_rid(b)


func upload(b: RID, data: PackedFloat32Array, offset := 0) -> void:
	_close_list()
	var bytes := data.to_byte_array()
	rd.buffer_update(b, offset * 4, bytes.size(), bytes)


## Чтение буфера. Ждёт GPU, если есть незавершённая работа, — в порциях звать только после sync().
func download(b: RID, n := -1, offset := 0) -> PackedFloat32Array:
	_close_list()
	var bytes := rd.buffer_get_data(b, offset * 4, n * 4 if n >= 0 else 0)
	return bytes.to_float32_array()


func read_scalar(i: int) -> float:
	return download(scalars, 1, i)[0]


# ---------------------------------------------------------------- выполнение


func submit() -> void:
	_close_list()
	rd.submit()


func sync() -> void:
	rd.sync()


## Метка времени GPU (между списками вычислений).
func stamp(name: String) -> void:
	_close_list()
	rd.capture_timestamp(name)


func _close_list() -> void:
	if _cl >= 0:
		rd.compute_list_end()
		_cl = -1


func _pipeline(shader: String, spec: Array) -> RID:
	var key := shader + str(spec)
	if _pipe.has(key):
		return _pipe[key]
	var consts: Array[RDPipelineSpecializationConstant] = []
	for i in spec.size():
		var c := RDPipelineSpecializationConstant.new()
		c.constant_id = i
		c.value = spec[i]
		consts.append(c)
	var p := rd.compute_pipeline_create(_shader[shader], consts)
	_pipe[key] = p
	return p


func _uniforms(shader: String, bufs: Array) -> RID:
	var key := shader
	for b in bufs:
		key += "#%d," % (b as RID).get_id()
	if _sets.has(key):
		return _sets[key]
	var us: Array[RDUniform] = []
	for i in bufs.size():
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.binding = i
		u.add_id(bufs[i])
		us.append(u)
	var s := rd.uniform_set_create(us, _shader[shader], 0)
	_sets[key] = s
	return s


static func _pc(i0: Array, i1 := [], f := []) -> PackedByteArray:
	var ints := PackedInt32Array()
	for a in [i0, i1]:
		for q in 4:
			ints.append(int(a[q]) if q < a.size() else 0)
	var fl := PackedFloat32Array()
	for q in 4:
		fl.append(float(f[q]) if q < f.size() else 0.0)
	var b := ints.to_byte_array()
	b.append_array(fl.to_byte_array())
	return b


func _dispatch(shader: String, spec: Array, bufs: Array, pc: PackedByteArray, groups: int) -> void:
	if _cl < 0:
		_cl = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(_cl, _pipeline(shader, spec))
	rd.compute_list_bind_uniform_set(_cl, _uniforms(shader, bufs), 0)
	rd.compute_list_set_push_constant(_cl, pc, pc.size())
	rd.compute_list_dispatch(_cl, clampi(groups, 1, 65535), 1, 1)
	rd.compute_list_add_barrier(_cl)
	dispatches += 1


static func _groups(n: int) -> int:
	return clampi(ceili(n / 256.0), 1, 65535)


# ---------------------------------------------------------------- поэлементные


## Y = op(X, Y); множитель a = f · S[sa] / S[sb] (sa, sb < 0 — без скаляра из буфера).
func vec(op: Vec, x: RID, y: RID, n: int, a := 1.0, b := 0.0, sa := -1, sb := -1) -> void:
	_dispatch(
		"air_vec", [op], [x if x.is_valid() else _dummy, y, scalars],
		_pc([n], [sa, sb], [a, b]), _groups(n)
	)


func fill(y: RID, n: int, value := 0.0) -> void:
	vec(Vec.FILL, RID(), y, n, 1.0, value)


func copy(x: RID, y: RID, n: int) -> void:
	vec(Vec.COPY, x, y, n)


func axpy(a: float, x: RID, y: RID, n: int, sa := -1, sb := -1) -> void:
	vec(Vec.AXPY, x, y, n, a, 0.0, sa, sb)


# ---------------------------------------------------------------- редукции


## S[out] = Σx (SUM), max|x| (MAXABS) или Σx·y (DOT) — деревом, без атомиков.
func reduce(op: Red, x: RID, n: int, out: int, y := RID()) -> void:
	var g := clampi(ceili(n / 256.0), 1, RED_GROUPS)
	var bufs := [x, y if y.is_valid() else x, _part, scalars]
	_dispatch("air_reduce", [op, 0], bufs, _pc([n, out]), g)
	_dispatch("air_reduce", [op, 1], bufs, _pc([g, out]), 1)


# ---------------------------------------------------------------- шаблон


## r = b − C·x (op 0) или r = C·x (op 1); dims = Vector3i(NX, NY, NZ).
func stencil(c: RID, x: RID, b: RID, r: RID, dims: Vector3i, apply := false) -> void:
	var n := dims.x * dims.y * dims.z
	_dispatch(
		"air_stencil", [1 if apply else 0], [c, x, b if b.is_valid() else x, r],
		_pc([dims.x, dims.y, dims.z]), _groups(n)
	)


# ---------------------------------------------------------------- прогонки


## Потоков на линию для длины n (степень 2, ≤ 256, отрезок ≥ 2 точек).
static func line_tpl(n: int) -> int:
	var t := 1
	while t * 2 <= mini(256, n / 2):
		t *= 2
	return t


## Прогонки по линиям направления dir (0 x, 1 y, 2 z) шаблона C: parity 0/1 — зебра (на месте
## в x), −1 — все линии «по Якоби» (выход в xo ≠ x). Линии > 1024 — многопроходная.
## Один буфер не привязывается дважды: граф RD тогда теряет запись и не ставит барьер.
func line(c: RID, x: RID, b: RID, dims: Vector3i, dir: int, parity: int, xo := RID()) -> void:
	if parity >= 0 or not xo.is_valid():
		xo = _dummy
	var n := dims[dir]
	var n1 := dims.y if dir == 0 else dims.x
	var n2 := dims.y if dir == 2 else dims.z
	var nlines := n1 * n2 if parity < 0 else ((n1 + 1) / 2) * n2
	var i0 := [dims.x, dims.y, dims.z, dir]
	if n <= LINE_MAX:
		var tpl := line_tpl(n)
		_dispatch(
			"air_line", [0, tpl], [c, x, b, xo], _pc(i0, [parity, nlines, n]),
			ceili(nlines * tpl / 256.0)
		)
		return
	# Многопроходная: S отрезков на линию, сведённая система 2S ≤ 1024 строк.
	var s := mini(LINE_MAX / 2, n / 2)
	var w := _scratch_buf("w%d" % dir, nlines * n * 3)
	var r := _scratch_buf("r%d" % dir, nlines * 2 * s * 4)
	var xr := _scratch_buf("xr%d" % dir, nlines * 2 * s)
	var pc := _pc(i0, [parity, nlines, n, s])
	var g := ceili(nlines * s / 64.0)
	_dispatch("air_line_mp", [1], [c, x, b, xo, w, r], pc, g)
	var tpl2 := line_tpl(2 * s)
	_dispatch(
		"air_line", [2, tpl2], [r, _dummy, _dummy, xr], _pc(i0, [0, nlines, 2 * s]),
		ceili(nlines * tpl2 / 256.0)
	)
	_dispatch("air_line_mp", [3], [c, x, b, xo, w, xr], pc, g)


## Зебра по направлениям dirs: для каждого — чётные, затем нечётные линии (как прикидка).
func zebra(c: RID, x: RID, b: RID, dims: Vector3i, dirs := [2, 0, 1]) -> void:
	for d in dirs:
		line(c, x, b, dims, d, 0)
		line(c, x, b, dims, d, 1)


func _scratch_buf(key: String, n: int) -> RID:
	var k := "%s:%d" % [key, n]
	if not _scratch.has(k):
		_scratch[k] = buffer(n)
	return _scratch[k]


# ---------------------------------------------------------------- многосеточный (air_mg.glsl)


## Ядро air_mg.glsl: входы in0..in2 (RID() — не нужен), активность act, выход out; fine —
## размеры мелкого уровня; total — число выходных элементов (для числа групп).
func mg_op(op: int, ins: Array, act: RID, out: RID, fine: Vector3i, total: int, f := 0.0) -> void:
	var b := []
	for q in 3:
		b.append(ins[q] if q < ins.size() and (ins[q] as RID).is_valid() else _dummy)
	b.append(act if act.is_valid() else _dummy)
	b.append(out)
	_dispatch("air_mg", [op], b, _pc([fine.x, fine.y, fine.z], [], [f]), _groups(total))
