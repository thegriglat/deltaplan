extends Node
## Фон меню: детерминированность по сиду, интервалы птиц, громкость, затухание при старте полёта.

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _cfg() -> Dictionary:
	return Config.get_config("audio").get("menu", {})


func _run(seed_value: int, seconds: float) -> Array:
	var m := MenuAmbientMix.new()
	m.setup(_cfg(), seed_value, 11)
	var out: Array = []
	var t := 0.0
	while t < seconds:
		var ev := m.advance(0.1, true)
		t += 0.1
		if not ev.is_empty():
			ev["t"] = t
			out.append(ev)
	return out


func test_deterministic_by_seed() -> void:
	var a := _run(7, 1200.0)
	var b := _run(7, 1200.0)
	var c := _run(8, 1200.0)
	check(a.size() > 10, "за 20 минут больше 10 криков (%d)" % a.size())
	check(str(a) == str(b), "один сид даёт то же расписание")
	check(str(a) != str(c), "другой сид даёт другое")


func test_bird_schedule_bounds() -> void:
	var cfg := _cfg()
	var iv: Array = cfg["birds_interval_s"]
	var db: Array = cfg["birds_db"]
	var pan := float(cfg["birds_pan"])
	for s in [1, 2, 3]:
		var ev := _run(s, 3000.0)
		var first: Array = cfg["birds_first_s"]
		check(float(ev[0]["t"]) >= float(first[0]) - 0.11 and float(ev[0]["t"]) <= float(first[1]) + 0.11, "первый крик в границах")
		var last := -1
		var pans := {}
		var dbs := {}
		for i in ev.size():
			check(int(ev[i]["clip"]) != last, "нет повтора подряд (сид %d, №%d)" % [s, i])
			last = int(ev[i]["clip"])
			check(absf(float(ev[i]["pan"])) <= pan + 1e-6, "панорама в границах")
			check(float(ev[i]["db"]) >= float(db[0]) and float(ev[i]["db"]) <= float(db[1]), "громкость крика в границах")
			pans[snappedf(float(ev[i]["pan"]), 0.2)] = true
			dbs[snappedf(float(ev[i]["db"]), 2.0)] = true
			if i > 0:
				var dt: float = float(ev[i]["t"]) - float(ev[i - 1]["t"])
				check(dt >= float(iv[0]) - 0.11 and dt <= float(iv[1]) + 0.11, "интервал %.1f в [%s]" % [dt, iv])
		check(pans.size() >= 4 and dbs.size() >= 3, "панорама и громкость разнообразны")


func test_levels_below_threshold() -> void:
	var cfg := _cfg()
	var m := MenuAmbientMix.new()
	m.setup(cfg, 3, 11)
	var hi := -999.0
	var lo := 999.0
	for i in 20000:  # 2000 с
		m.advance(0.1, true)
		hi = maxf(hi, maxf(m.wind_db(), m.grass_db()) + m.fade_db())
		lo = minf(lo, m.wind_db())
	check(hi <= -18.0 + 1e-6, "ветер не громче −18 дБ (%.1f)" % hi)
	check(hi >= -26.0, "и не пропадает совсем (%.1f)" % hi)
	var depth := float(cfg["gust_depth_db"])
	check(hi - lo > 0.5 * depth, "порывы заметны: размах %.1f дБ" % (hi - lo))
	check(float(cfg["birds_db"][1]) <= -9.0, "птицы тихие")


func test_fade_out_on_flight_start() -> void:
	var cfg := _cfg()
	var m := MenuAmbientMix.new()
	m.setup(cfg, 5, 11)
	for i in 100:
		m.advance(0.1, true)
	check(is_equal_approx(m.fade_gain(), 1.0), "после появления полная громкость")
	var fout := float(cfg["fade_out_s"])
	check(fout >= 0.5 and fout <= 1.5, "затухание около 1 с")
	var prev := m.fade_gain()
	for i in int(fout * 10.0):
		m.advance(0.1, false)
		check(m.fade_gain() < prev + 1e-9, "затухает монотонно")
		prev = m.fade_gain()
	check(m.fade_gain() <= 1e-6, "через fade_out_s тишина (%.3f)" % m.fade_gain())
	check(not m.audible(), "не слышно")
	check(m.advance(0.1, false).is_empty(), "птицы молчат")
	for i in 20:
		m.advance(0.1, true)  # возврат в меню: плавно, а не скачком
	check(m.fade_gain() > 0.0 and m.fade_gain() < 1.0, "возврат плавный (%.2f)" % m.fade_gain())
	for i in 40:
		m.advance(0.1, true)
	check(is_equal_approx(m.fade_gain(), 1.0), "и доходит до полной")


func test_node_loads_files_and_follows_flag() -> void:
	var n := MenuAmbient.new()
	n.force_active = true
	add_child(n)
	check(n._birds.size() == 11, "11 записей птиц загружено (%d)" % n._birds.size())
	check(n._wind.stream != null and n._grass.stream != null, "ветер загружен")
	for i in 40:
		n._process(0.1)
	check(n._playing, "играет в меню")
	check(n._wind.volume_db <= -18.0 + 1e-6, "плеер ветра ≤ −18 дБ (%.1f)" % n._wind.volume_db)
	n.force_active = false
	for i in 12:
		n._process(0.1)
	check(not n._playing, "после старта полёта остановлен")
	check(AudioServer.get_bus_index("MenuWind") >= 0, "шина MenuWind есть")
	n.free()
	OS.delay_msec(150)
