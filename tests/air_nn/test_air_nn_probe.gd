extends TestCase
## NN-7а: пробник ONNX Runtime <-> Godot (контракт П5 v1, не финальный N5).
## Загружает GDExtension native/air_nn_probe (собирается native/air_nn_probe/build.sh), гоняет
## модель-пустышку и сравнивает с эталоном ORT Python (make_dummy_model.py) — допуск 1e-5.
## Расширение не собрано — тест пропускается с сообщением (общий набор не ломает).

const DIR := "res://native/air_nn_probe/"
const EXT := DIR + "bin/air_nn_probe.gdextension"
const C := 4
const H := 96
const W := 96
const N_RUNS := 50


static func _ensure_extension() -> String:
	if ClassDB.class_exists("AirNnProbe"):
		return ""
	var lib := DIR + "bin/" + ("windows/air_nn_probe.dll" if OS.get_name() == "Windows" else "linux/libair_nn_probe.so")
	if not FileAccess.file_exists(EXT) or not FileAccess.file_exists(lib):
		return "расширение не собрано (native/air_nn_probe/build.sh)"
	var st := GDExtensionManager.load_extension(EXT)
	if st != GDExtensionManager.LOAD_STATUS_OK and st != GDExtensionManager.LOAD_STATUS_ALREADY_LOADED:
		return "load_extension: статус %d" % st
	return "" if ClassDB.class_exists("AirNnProbe") else "класс AirNnProbe не зарегистрирован"


## Вход — та же формула, что в make_dummy_model.py.
static func _input() -> PackedFloat32Array:
	var x := PackedFloat32Array()
	x.resize(C * H * W)
	for i in x.size():
		x[i] = fmod(i * 0.6180339887, 1.0) * 2.0 - 1.0
	return x


func test_probe_matches_ort_python() -> void:
	var why := _ensure_extension()
	if why != "":
		if FileAccess.file_exists(EXT):
			failures.append(why)  # собрано, но не грузится — это падение
		else:
			print("    skip air_nn_probe: " + why)
		return
	var ref := FileAccess.get_file_as_bytes(DIR + "dummy_ref.bin").to_float32_array()
	check(ref.size() == 2 * H * W, "эталон: %d чисел" % ref.size())
	var x := _input()
	var shape := PackedInt64Array([1, C, H, W])
	for threads in [1, 4]:
		var p: Object = ClassDB.instantiate("AirNnProbe")
		p.call("set_intra_op_threads", threads)
		var rc: int = p.call("load", DIR + "dummy_conv.onnx")
		check(rc == 0, "load: %d %s" % [rc, p.call("last_error")])
		if rc != 0:
			return
		var y: PackedFloat32Array = p.call("run", x, shape)
		check(y.size() == ref.size(), "выход %d, эталон %d (%s)" % [y.size(), ref.size(), p.call("last_error")])
		if y.size() != ref.size():
			return
		check(p.call("output_shape") == PackedInt64Array([1, 2, H, W]), "форма %s" % [p.call("output_shape")])
		var dmax := 0.0
		for i in y.size():
			dmax = maxf(dmax, absf(y[i] - ref[i]))
		check(dmax <= 1e-5, "max|Δ| = %s > 1e-5" % String.num_scientific(dmax))
		var t0 := Time.get_ticks_usec()
		for k in N_RUNS:
			p.call("run", x, shape)
		var ms := (Time.get_ticks_usec() - t0) / 1000.0 / N_RUNS
		print("    air_nn_probe: потоки %d — max|Δ| = %s, run %.3f мс (среднее из %d)" % [threads, String.num_scientific(dmax), ms, N_RUNS])
	# Ошибки — пустой выход и сообщение.
	var q: Object = ClassDB.instantiate("AirNnProbe")
	check((q.call("run", x, shape) as PackedFloat32Array).is_empty(), "run без модели — пусто")
	check(q.call("load", DIR + "нет_такого.onnx") != 0, "load несуществующего — ошибка")
	check(q.call("load", DIR + "make_dummy_model.py") == 2, "load не-ONNX — код 2: " + str(q.call("last_error")))
	q.call("load", DIR + "dummy_conv.onnx")
	check((q.call("run", x, PackedInt64Array([1, C, H, W + 1])) as PackedFloat32Array).is_empty(), "неверная форма — пусто")
	check(q.call("last_error") != "", "неверная форма — есть last_error")
