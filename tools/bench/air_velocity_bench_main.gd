extends Node
## Замер Atmosphere.air_velocity_at, мкс/вызов (docs/guide/air-model.md), и побитное сравнение с
## сохранённым прогоном. Не игровой код. Мир — эталонный мир отпечатка без рельефа из данных
## (FingerprintWorld.make: растр места 25 м, поле Пикара считает крейт), t = 0, 6400 точек (сетка
## 40 × 40 × 4 высоты над рельефом), болтанка в воздухе включена (SAMPLE_FULL).
##   XDG_DATA_HOME=$(mktemp -d) godot --headless --path . \
##     res://tools/bench/air_velocity_bench.tscn -- [--smoke] [--kayancha] [--out=<файл>] \
##     [--compare=<файл>]
##   --out / --compare — записать / сравнить air_velocity_at и mean_wind_at (float64 подряд)
##   --kayancha — способ базы AM-00: Онгудай, Каянча, 75 м, 100 000 вызовов в точке (поле Пикара
##             на месте считает крейт: минуты ожидания READY)
##   --smoke — быстрая проверка вызовов: сетка 4 × 4 × 4, по одному повтору, без Каянчи
## Печатает: «air_velocity_at: X мкс/вызов (лучший из 5, N вызовов)».

const FingerprintWorld := preload("res://tests/atmosphere/fingerprint_world.gd")


func _ready() -> void:
	var out := ""
	var cmp := ""
	var args := OS.get_cmdline_user_args()
	for a in args:
		if a.begins_with("--out="):
			out = a.substr(6)
		elif a.begins_with("--compare="):
			cmp = a.substr(10)
	var smoke := args.has("--smoke")
	if args.has("--kayancha") and not smoke:
		await _kayancha()
		return
	var a := FingerprintWorld.make()
	if not a.is_ready():
		print("air_velocity_bench: атмосфера не готова: %s" % [a.status()])
		get_tree().quit(1)
		return
	add_child(a)  # _exit_tree останавливает фоновую работу крейта
	var n := 4 if smoke else 40
	var pts: Array[Vector3] = []
	var center := Vector2(AtmoFingerprint.CENTER.x, AtmoFingerprint.CENTER.z)
	var step_m := 300.0 * 40.0 / n
	for i in n:
		for j in n:
			for hh in [5.0, 40.0, 300.0, 1500.0]:
				var x := center.x + (i - (n - 1) / 2.0) * step_m
				var z := center.y + (j - (n - 1) / 2.0) * step_m
				pts.append(Vector3(x, AtmoFingerprint.height(x, z) + hh, z))
	var vals := PackedFloat64Array()
	for p in pts:
		var v := a.air_velocity_at(p)
		var m := a.mean_wind_at(p)
		vals.append_array([v.x, v.y, v.z, m.x, m.y, m.z])
	if out != "":
		var f := FileAccess.open(out, FileAccess.WRITE)
		f.store_buffer(vals.to_byte_array())
		f.close()
	if cmp != "":
		var ref := FileAccess.get_file_as_bytes(cmp).to_float64_array()
		var nd := 0
		for i in mini(ref.size(), vals.size()):
			if ref[i] != vals[i]:
				nd += 1
		print("air_velocity_bench: %d значений, отличий от эталона %d" % [ref.size(), nd])
	print(
		(
			"air_velocity_at: %.2f мкс/вызов (лучший из %d, %d вызовов)"
			% [_bench(a, pts, 1 if smoke else 5), 1 if smoke else 5, 4 * pts.size()]
		)
	)
	remove_child(a)
	a.free()
	get_tree().quit(0)


func _bench(a: Atmosphere, pts: Array[Vector3], repeats: int) -> float:
	var best := 1.0e9
	for r in repeats:
		var t0 := Time.get_ticks_usec()
		for k in 4:
			for p in pts:
				a.air_velocity_at(p)
		best = minf(best, float(Time.get_ticks_usec() - t0) / (4.0 * pts.size()))
	return best


## Способ базы AM-00 (docs/archive/plan/air-model-baseline.md → §3): Онгудай, старт Каянча, 75 м над
## землёй, ветер 20 км/ч в склон, 100 000 вызовов в одной точке.
func _kayancha() -> void:
	var terrain := Terrain.new()
	terrain.location_id = ""
	add_child(terrain)
	if not terrain.load_location("ongudai"):
		print("air_velocity_bench: нет рельефа ongudai")
		get_tree().quit(1)
		return
	terrain.wait_relief()
	var site: Dictionary = terrain.get_start_sites()[0]
	var loc: Dictionary = Config.get_config("locations/ongudai")
	var a := Atmosphere.new()
	a.visuals_enabled = false
	add_child(a)
	var place: AirPlaceData = await a.place_from_terrain(terrain, float(loc.utc_offset_h), 7, 15)
	if place == null:
		print("air_velocity_bench: нет слоя detail у рельефа")
		get_tree().quit(1)
		return
	var pos0: Vector3 = site.position
	a.configure(4242)
	a.set_conditions(
		{
			"forecast":
			{
				"temperature_c": 26.0,
				"wind_speed_kmh": 20.0,
				"wind_from_deg": float(site.heading_deg),
				"sky": "clear",
			},
			"start_hour": 12.0,
			"speed": 1.0,
			"quantum_h": 1.0,
		}
	)
	a.load_place(place)
	a.set_focus(pos0)
	a.start_at(0.0)
	while not a.is_ready() and a.status().state != Atmosphere.STATE_FAILED:
		a.pump(8000)
		await get_tree().process_frame
	if not a.is_ready():
		print("air_velocity_bench: FAILED %s" % [a.status()])
		get_tree().quit(1)
		return
	var p := Vector3(pos0.x, terrain.height_at(pos0.x, pos0.z) + 75.0, pos0.z)
	var best := 1.0e9
	for r in 3:
		var t0 := Time.get_ticks_usec()
		for i in 100000:
			a.air_velocity_at(p)
		best = minf(best, float(Time.get_ticks_usec() - t0) / 100000.0)
	print(
		(
			"air_velocity_at Каянча 75 м: %.2f мкс/вызов (лучший из 3 × 100 000), v = %s"
			% [best, a.air_velocity_at(p)]
		)
	)
	remove_child(a)
	a.free()
	terrain.free()
	get_tree().quit(0)

