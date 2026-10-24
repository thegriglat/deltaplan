extends TestCase
## Гонка маски поверхности (CR-18): рабочий поток читает forest_at/mask_r/mask_g/class_at,
## пока главный поток меняет маску (большая → малая → большая) и вырезает поляны.
## Ошибки выхода за массив (SCRIPT ERROR) тест не ловит прямо — берётся согласованность
## значений: читатель видит либо старую, либо новую маску целиком (значения из известного набора).
## Запуск: godot --headless --path . res://tests/run_tests.tscn -- --filter=test_surface_mask_race

const BIG := 400
const SMALL := 8
const ROUNDS := 300

var _stop := false
var _bad := 0
var _reads := 0
var _sl: SurfaceLayer


func _mask(n: int, r: int, g: int) -> Image:
	var d := PackedByteArray()
	d.resize(n * n * 2)
	for k in n * n:
		d[k * 2] = r
		d[k * 2 + 1] = g
	return Image.create_from_data(n, n, false, Image.FORMAT_RG8, d)


func _reader() -> void:
	var seed_v := 12345
	while not _stop:
		seed_v = (seed_v * 1103515245 + 12345) & 0x7fffffff
		var x := float(seed_v % 5000) - 500.0
		seed_v = (seed_v * 1103515245 + 12345) & 0x7fffffff
		var z := float(seed_v % 5000) - 500.0
		var sl := _sl
		var r := sl.mask_r(x, z)
		var g := sl.mask_g(x, z)
		var f := sl.forest_at(x, z)
		var c := sl.class_at(x, z)
		# маски однородные: R ∈ {0, 1}, G ∈ {0, 0.2}; класс — 0..CLASS_COUNT-1
		if not (r == 0.0 or is_equal_approx(r, 1.0)) or not (g == 0.0 or is_equal_approx(g, 0.2)):
			_bad += 1
		if f < 0.0 or f > 1.0 or c < 0 or c >= SurfaceLayer.CLASS_COUNT:
			_bad += 1
		_reads += 1


func test_reader_vs_writer() -> void:
	var cls := PackedByteArray()
	cls.resize(50 * 50)
	cls.fill(SurfaceLayer.FOREST)
	_sl = SurfaceLayer.from_classes("race", 50, 50, 25.0, 0.0, 0.0, cls)
	_sl.set_forest_mask(_mask(BIG, 255, 51), 10.0, 0.0, 0.0)
	var tid := WorkerThreadPool.add_task(_reader)
	for i in ROUNDS:
		_sl.set_forest_mask(_mask(SMALL, 255, 51), 10.0, 0.0, 0.0)
		_sl.replace_in_circle(float(i % 40) * 20.0, 300.0, 60.0, SurfaceLayer.FOREST, SurfaceLayer.GRASS)
		_sl.set_forest_mask(_mask(BIG, 255, 51), 10.0, 0.0, 0.0)
		_sl.replace_in_circle(float(i % 40) * 20.0, 400.0, 60.0, SurfaceLayer.GRASS, SurfaceLayer.FOREST)
		if i % 50 == 0:
			OS.delay_msec(1)
	_stop = true
	WorkerThreadPool.wait_for_task_completion(tid)
	check(_reads > 0, "читатель отработал")
	check(_bad == 0, "ни одного несогласованного чтения маски (%d из %d)" % [_bad, _reads])


func test_clearing_applies_to_snapshot() -> void:
	var cls := PackedByteArray()
	cls.resize(10 * 10)
	cls.fill(SurfaceLayer.FOREST)
	var s := SurfaceLayer.from_classes("clr", 10, 10, 25.0, 0.0, 0.0, cls)
	s.set_forest_mask(_mask(40, 255, 0), 10.0, 0.0, 0.0)
	check(s.mask_r(100.0, 100.0) > 0.99, "до поляны лес")
	s.replace_in_circle(100.0, 100.0, 30.0, SurfaceLayer.FOREST, SurfaceLayer.GRASS)
	check(s.mask_r(100.0, 100.0) == 0.0, "в поляне леса нет")
	check(s.class_at(100.0, 100.0) == SurfaceLayer.GRASS, "класс в поляне — луг")
	check(s.mask_r(380.0, 380.0) > 0.99, "вдали лес остался")
	check(s.forest_mask_image().get_data().size() == 40 * 40 * 2, "образ маски согласован")


func test_small_mask_no_overrun() -> void:
	var cls := PackedByteArray()
	cls.resize(4)
	var s := SurfaceLayer.from_classes("tiny", 2, 2, 25.0, 0.0, 0.0, cls)
	s.set_forest_mask(_mask(1, 255, 0), 10.0, 0.0, 0.0)
	check(s.mask_r(5.0, 5.0) == 0.0, "маска 1×1 — 0, без выхода за массив")
