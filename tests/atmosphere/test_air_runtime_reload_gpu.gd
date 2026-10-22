extends TestCase
## AirRuntime: повторные загрузки места в одном процессе (CR-6, группа B отчётов о вылетах):
## N загрузок подряд со сменой места (ключа) и ветра на одном общем RenderingDevice — каждая
## считается, после stop() на RD нет буферов задач (кроме ядер), память RD не растёт; включённый
## «упрощённый ветер» отдаёт RD и не создаёт его заново.
## tools/gpu_tests.sh --filter=air_runtime_reload

const LOADS := 5
## Ветер по загрузкам: {u10 м/с, откуда °}. Смена > допусков — каждый раз пересчёт поля.
const WINDS: Array[Vector2] = [Vector2(3, 150), Vector2(5, 200), Vector2(3, 150), Vector2(6, 90), Vector2(4, 150)]
## Допустимый рост памяти RD между загрузками, байт (аллокатор округляет блоки).
const MEM_SLACK := 8 * 1024 * 1024

var _c := {}


func needs_gpu() -> bool:
	return true


func _cond() -> Dictionary:
	return _c


static func _atmo(detail: HeightLayer) -> Atmosphere:
	var w: Dictionary = Config.get_config("weather/medium").duplicate(true)
	w.wind_speed_kmh = Units.to_kmh(3.0)
	w.wind_from_deg = 150.0
	w.thermal_mode = "static"
	w.static_thermals = []
	var a := Atmosphere.new()
	a.visuals_enabled = false
	a.configure(Config.get_config("atmosphere"), w)
	a.set_ground(func(x: float, z: float) -> float: return detail.sample(x, z), _sun)
	a.set_thermal_mode("static")
	a.turbulence_enabled = false
	a.wave.enabled = false
	a.step(0.01)
	return a


static func _sun(_x: float, _z: float) -> float:
	return 1.0


func test_reload_place_n_times() -> void:
	var lw := TestAirPlace.load_detail("ongudai")
	var loc0 := TestAirPlace.load_loc("ongudai")
	var detail: HeightLayer = lw[0]
	var atmo := _atmo(detail)
	var rt := AirRuntime.new()
	rt.baked_enabled = false  # считается каждая загрузка, а не берётся из файла
	await Engine.get_main_loop().process_frame
	(Engine.get_main_loop() as SceneTree).root.add_child(rt)
	var gpu := rt._gpu
	check(gpu != null and gpu.rd != null, "RD создан при появлении узла")
	if gpu == null or gpu.rd == null:
		rt.queue_free()
		atmo.free()
		return
	var mem0 := -1
	for i in LOADS:
		var loc := loc0.duplicate(true)
		loc.month = 6
		loc.day = i + 1  # другой ключ места: setup() делает stop() и освобождает клипмап
		_c = {hour = 12.0, u10 = WINDS[i].x, wdir = WINDS[i].y, t_max = NAN, sky = "clear"}
		rt.setup(atmo, {detail = detail, water = lw[1], loc = loc}, _cond)
		check(rt._clip == null, "загрузка %d: клипмап прежнего места отпущен" % [i + 1])
		var ok: bool = await rt.load_field()
		check(ok, "загрузка %d: поле посчитано (%s)" % [i + 1, rt.last_error])
		check(rt._gpu == gpu and gpu.rd != null, "загрузка %d: тот же живой RD" % [i + 1])
		check(atmo.is_air_field_on(), "загрузка %d: поле в атмосфере" % [i + 1])
		rt.stop()
		check(gpu._owned.size() == gpu._base, "загрузка %d: после stop() на RD нет буферов задач (%d)" % [i + 1, gpu._owned.size() - gpu._base])
		var mem: int = gpu.rd.get_memory_usage(RenderingDevice.MEMORY_TOTAL)
		if mem0 < 0:
			mem0 = mem
		check(mem <= mem0 + MEM_SLACK, "загрузка %d: память RD не растёт (%d МБ, первая %d МБ)" % [i + 1, mem >> 20, mem0 >> 20])
		if not ok:
			break
	rt.queue_free()
	atmo.free()


## «Упрощённый ветер» включён после запуска: RD отдаётся и заново не создаётся.
func test_simple_wind_releases_rd() -> void:
	var lw := TestAirPlace.load_detail("ongudai")
	var loc := TestAirPlace.load_loc("ongudai")
	var detail: HeightLayer = lw[0]
	var atmo := _atmo(detail)
	var rt := AirRuntime.new()
	await Engine.get_main_loop().process_frame
	(Engine.get_main_loop() as SceneTree).root.add_child(rt)
	check(rt._gpu != null, "режим «расчёт»: RD есть")
	var saved: Variant = Config._cache.get("atmosphere")
	var cfg: Dictionary = Config.get_config("atmosphere").duplicate(true)
	cfg.air_model = cfg.get("air_model", {}).duplicate(true)
	cfg.air_model.enabled = "off"
	Config._cache["atmosphere"] = cfg
	_c = {hour = 12.0, u10 = 3.0, wdir = 150.0, t_max = NAN, sky = "clear"}
	rt.setup(atmo, {detail = detail, water = lw[1], loc = loc}, _cond)
	check(rt._gpu == null, "«упрощённый» после запуска: RD отдан")
	check(rt._device() == null, "«упрощённый»: RD заново не создаётся")
	check(rt.unavailable_reason() == "air_model.enabled = off", "расчёт выключен: %s" % rt.unavailable_reason())
	if saved != null:
		Config._cache["atmosphere"] = saved
	else:
		Config.reload()
	rt.queue_free()
	atmo.free()
