extends TestCase
## ON-2: расширение AirOnnx (контракт O2). Модель-пустышка с двумя входами (maps, nums)
## и двумя выходами (native/air_onnx/test/make_dummy_model.py): совпадение с эталоном
## ORT Python ≤ 1e-5, имена, формы, метаданные, run из рабочего потока; ошибки — коды
## и пустой ответ без падения. Расширение не собрано (нет air_onnx.gdextension) — пропуск.

const ADDON := "res://addons/air_onnx/"
const EXT := ADDON + "air_onnx.gdextension"
const LIB_LINUX := ADDON + "bin/linux/libair_onnx.so"
const LIB_WINDOWS := ADDON + "bin/windows/air_onnx.dll"
const DATA := "res://native/air_onnx/test/"
const MODEL := DATA + "dummy_two_inputs.onnx"
const C := 3
const H := 12
const W := 12
const N_NUM := 5
const C_OUT := 2


## "" — класс есть; "skip" — не собрано; иначе причина падения. Обычно расширение уже
## зарегистрировано импортом после сборки; если сборка свежее импорта — грузим вручную.
static func _ensure_extension() -> String:
	if ClassDB.class_exists("AirOnnx"):
		return ""
	var lib := LIB_WINDOWS if OS.get_name() == "Windows" else LIB_LINUX
	if not FileAccess.file_exists(EXT) or not FileAccess.file_exists(lib):
		return "skip"
	var st := GDExtensionManager.load_extension(EXT)
	if st != GDExtensionManager.LOAD_STATUS_OK and st != GDExtensionManager.LOAD_STATUS_ALREADY_LOADED:
		return "load_extension: статус %d" % st
	return "" if ClassDB.class_exists("AirOnnx") else "класс AirOnnx не зарегистрирован"


## true — можно тестировать; false — пропуск (не собрано) или падение (не грузится).
func _ready_or_skip(test: String) -> bool:
	var why := _ensure_extension()
	if why == "skip":
		print("    skip air_onnx::%s: расширение не собрано (native/air_onnx/build.sh)" % test)
		return false
	if why != "":
		failures.append(why)
		return false
	return true


## Входы — те же формулы, что в make_dummy_model.py.
static func _inputs() -> Dictionary:
	var maps := PackedFloat32Array()
	maps.resize(C * H * W)
	for i in maps.size():
		maps[i] = fmod(i * 0.6180339887, 1.0) * 2.0 - 1.0
	var nums := PackedFloat32Array()
	nums.resize(N_NUM)
	for i in nums.size():
		nums[i] = fmod(i * 0.4142135623 + 0.3, 1.0) * 2.0 - 1.0
	return {"maps": maps, "nums": nums}


static func _max_diff(a: PackedFloat32Array, b: PackedFloat32Array, offset: int) -> float:
	var d := 0.0
	for i in a.size():
		d = maxf(d, absf(a[i] - b[offset + i]))
	return d


## Имена, формы и метаданные модели-пустышки.
func _check_model_info(p: Object) -> void:
	check(p.call("input_names") == PackedStringArray(["maps", "nums"]), "входы")
	check(p.call("output_names") == PackedStringArray(["out", "aux"]), "выходы")
	var maps_shape: PackedInt64Array = p.call("input_shape", "maps")
	check(maps_shape == PackedInt64Array([1, C, H, W]), "форма maps %s" % [maps_shape])
	check(p.call("input_shape", "nums") == PackedInt64Array([1, N_NUM]), "форма nums")
	check(p.call("output_shape", "out") == PackedInt64Array([1, C_OUT, H, W]), "форма out")
	check(p.call("output_shape", "aux") == PackedInt64Array([1, C_OUT]), "форма aux")
	var none: PackedInt64Array = p.call("input_shape", "нет")
	check(none.is_empty(), "форма неизвестного имени — пусто")
	var md: Dictionary = p.call("metadata")
	check(md.get("deltaplan.test", "") == "двухвходовая пустышка", "метаданные %s" % [md])
	check(md.get("deltaplan.agl", "") == "10,20,40", "метаданные agl")


func test_air_onnx_matches_ort_python() -> void:
	if not _ready_or_skip("matches_ort_python"):
		return
	var ref := FileAccess.get_file_as_bytes(DATA + "dummy_two_inputs_ref.bin").to_float32_array()
	var n_out := C_OUT * H * W
	check(ref.size() == n_out + C_OUT, "эталон: %d чисел" % ref.size())
	var x := _inputs()
	var p: Object = ClassDB.instantiate("AirOnnx")
	check(p.call("get_intra_op_threads") == 4, "потоки по умолчанию — 4")
	for threads in [1, 4]:
		p.call("set_intra_op_threads", threads)
		var rc: int = p.call("load", MODEL)
		check(rc == 0, "load: %d %s" % [rc, p.call("last_error")])
		if rc != 0:
			return
		_check_model_info(p)
		var y: Dictionary = p.call("run", x)
		var out: PackedFloat32Array = y.get("out", PackedFloat32Array())
		var aux: PackedFloat32Array = y.get("aux", PackedFloat32Array())
		var sizes_ok := y.size() == 2 and out.size() == n_out and aux.size() == C_OUT
		check(sizes_ok, "run: %s, %s" % [y.keys(), p.call("last_error")])
		if not sizes_ok:
			return
		var dmax := maxf(_max_diff(out, ref, 0), _max_diff(aux, ref, n_out))
		var dtxt := String.num_scientific(dmax)
		check(dmax <= 1e-5, "потоки %d: max|Δ| = %s > 1e-5" % [threads, dtxt])
		print("    air_onnx: потоки %d — max|Δ| = %s" % [threads, dtxt])
	# run из рабочего потока (WorkerThreadPool) — тот же результат.
	var box := {}
	var task := WorkerThreadPool.add_task(func() -> void: box["y"] = p.call("run", x))
	WorkerThreadPool.wait_for_task_completion(task)
	var yt: Dictionary = box.get("y", {})
	var out_t: PackedFloat32Array = yt.get("out", PackedFloat32Array())
	var ok_t := out_t.size() == n_out and _max_diff(out_t, ref, 0) <= 1e-5
	check(ok_t, "run из рабочего потока: %s" % p.call("last_error"))


func _run_fails(q: Object, inputs: Dictionary, what: String) -> void:
	var y: Dictionary = q.call("run", inputs)
	check(y.is_empty() and q.call("last_error") != "", what + " — {} и last_error")


func test_air_onnx_errors() -> void:
	if not _ready_or_skip("errors"):
		return
	var x := _inputs()
	var q: Object = ClassDB.instantiate("AirOnnx")
	_run_fails(q, x, "run без модели")
	check(q.call("load", DATA + "нет_такого.onnx") == 1, "нет файла — код 1")
	var rc: int = q.call("load", DATA + "make_dummy_model.py")
	check(rc == 2, "не-ONNX — код 2: %d %s" % [rc, q.call("last_error")])
	check((q.call("input_names") as PackedStringArray).is_empty(), "после ошибки входов нет")
	check(q.call("load", MODEL) == 0, "load: " + str(q.call("last_error")))
	var short: PackedFloat32Array = (x["maps"] as PackedFloat32Array).duplicate()
	short.resize(short.size() - 1)
	_run_fails(q, {"maps": short, "nums": x["nums"]}, "неверная длина")
	_run_fails(q, {"maps": x["maps"]}, "нет входа nums")
	_run_fails(q, {"maps": x["maps"], "nums": x["nums"], "mapz": x["maps"]}, "лишний вход")
	var f64 := PackedFloat64Array([0, 0, 0, 0, 0])
	_run_fails(q, {"maps": x["maps"], "nums": f64}, "вход не PackedFloat32Array")
	# После ошибок сессия жива.
	var y: Dictionary = q.call("run", x)
	check(y.size() == 2 and q.call("last_error") == "", "run после ошибок")
