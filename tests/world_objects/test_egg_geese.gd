extends Node
## Пасхалка «клин гусей» (EE-6): сезон по месяцу и широте, пролёт насквозь, строй, звук,
## детерминизм расписания, плотность по миру (доля полётов с клином в пик), CPU.
## godot --headless --path . res://tests/run_tests.tscn -- --filter=egg_geese

var failures: PackedStringArray = []
var metrics := {}  # peak_flights_with_geese_share, cpu_ms_geese — в вывод теста


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _cfg() -> Dictionary:
	return Config.get_config("easter_eggs").eggs.geese


func _ctx(t: float, month := 4, lat := 51.0, key := "K") -> EggContext:
	var c := EggContext.new()
	c.t = t
	c.world_key = key
	c.month = month
	c.lat_deg = lat
	c.pilot_pos = Vector3(0.0, 300.0, 0.0)
	return c


func _egg(sd: int, month := 4, lat := 51.0, cfg := {}) -> EggGeese:
	var e := EggGeese.new()
	var c := _cfg().duplicate(true)
	c.merge(cfg, true)
	e.t0 = 100.0
	e.lifetime_s = float(c.lifetime_s)
	var rng := RandomNumberGenerator.new()
	rng.seed = ("G|%d" % sd).hash()
	add_child(e)
	e.begin(_ctx(100.0, month, lat), c, rng, 100.0)
	return e


## Сезон (вес > 0) для всех месяцев: ровно март–май и сентябрь–ноябрь, на юге сдвиг на полгода.
func test_season_months_and_heading() -> void:
	var cfg := _cfg()
	for m in range(1, 13):
		var n := EggGeese.season(m, 51.0, cfg)
		var s := EggGeese.season(m, -34.0, cfg)
		var in_n := m in [3, 4, 5, 9, 10, 11]
		var in_s := m in [3, 4, 5, 9, 10, 11]
		check((float(n.weight) > 0.0) == in_n, "север, месяц %d" % m)
		check((float(s.weight) > 0.0) == in_s, "юг, месяц %d" % m)
		check(
			(
				EggGeese.can_appear(_ctx(0.0, m, 51.0), cfg)
				== in_n
			),
			"can_appear месяц %d" % m
		)
	check(float(EggGeese.season(4, 51.0, cfg).weight) == 1.0, "апрель — пик")
	check(float(EggGeese.season(10, 51.0, cfg).weight) == 1.0, "октябрь — пик")
	check(float(EggGeese.season(3, 51.0, cfg).weight) < 1.0, "март — край")
	for m in [7, 8, 1, 12, 6, 2]:
		check(not EggGeese.can_appear(_ctx(0.0, m), cfg), "вне сезона %d — нет" % m)
	# курс: весна — на север (−Z), осень — на юг (+Z); юг зеркально
	var sp := EggGeese.dir_of(float(EggGeese.season(4, 51.0, cfg).heading_deg))
	var au := EggGeese.dir_of(float(EggGeese.season(10, 51.0, cfg).heading_deg))
	check(sp.z < -0.7 and sp.x >= 0.0, "весна: север/северо-восток %s" % sp)
	check(au.z > 0.7 and au.x <= 0.0, "осень: юг/юго-запад %s" % au)
	var sps := EggGeese.dir_of(float(EggGeese.season(10, -34.0, cfg).heading_deg))
	var aus := EggGeese.dir_of(float(EggGeese.season(4, -34.0, cfg).heading_deg))
	check(sps.z > 0.7, "юг, весна (октябрь): на юг %s" % sps)
	check(aus.z < -0.7, "юг, осень (апрель): на север %s" % aus)


## Курс клина в мире: весной/осенью и зеркально на юге (по фактической траектории).
func test_flock_course() -> void:
	var cases := [[4, 51.0, -1.0], [10, 51.0, 1.0], [10, -34.0, 1.0], [4, -34.0, -1.0]]
	for c in cases:
		var north_ok := 0
		var total := 0
		for sd in 40:
			var e := _egg(sd, c[0], c[1])
			if not e.is_ghost():
				total += 1
				var d := e.center_at(100.0).direction_to(e.center_at(160.0))
				if d.z * float(c[2]) > 0.5:
					north_ok += 1
			e.queue_free()
		check(total > 10 and north_ok == total, "курс %s: %d/%d" % [str(c), north_ok, total])


## Вне сезона: призрак или нет планировщика; клинов в расписании нет совсем.
func test_off_season_nothing() -> void:
	var s := _sched()
	for t in range(0, 7200, 5):
		s.step(_ctx(float(t), 7))
	check(s.spawn_log.is_empty(), "июль: нет клиньев")
	s.queue_free()
	var s2 := _sched()
	for t in range(0, 7200, 5):
		s2.step(_ctx(float(t), 4))
	check(not s2.spawn_log.is_empty(), "апрель: есть клинья")
	s2.queue_free()


func _sched(sound := true) -> EasterEggs:
	var e := EasterEggs.new()
	e.cfg = Config.get_config("easter_eggs").duplicate(true)
	for id in e.cfg.eggs:
		if e.cfg.eggs[id] is Dictionary and id != "geese":
			(e.cfg.eggs[id] as Dictionary)["enabled"] = false
	if not sound:
		(e.cfg.eggs.geese as Dictionary)["sound"] = ""
	add_child(e)
	return e


## Клин проходит область насквозь: вне видимости в начале и в конце, строй держится весь пролёт.
func test_pass_through_and_formation() -> void:
	var cfg := _cfg()
	var vis := float(cfg.vis_m)
	var crossed := 0
	var total := 0
	var ng := 0
	for sd in 60:
		var e := _egg(sd)
		if e.is_ghost():
			ng += 1
			e.queue_free()
			continue
		total += 1
		var life := 2.0 * float(cfg.half_len_m) / 15.0
		var dmin := INF
		var t := 100.0
		var first_far := false
		var last_far := false
		var maxr := 0.0
		var minsep := INF
		var n := e.bird_count()
		check(n >= 20 and n <= 40, "птиц %d" % n)
		var step := 0
		while e.update(_ctx(t)):
			var d := e.position.distance_to(Vector3(0, 300, 0))
			if t == 100.0:
				first_far = d > vis + 500.0
			dmin = minf(dmin, d)
			last_far = d > vis + 500.0
			if step % 6 == 0:
				var bp := e.bird_positions()
				if e.get_child(0) is MultiMeshInstance3D and (e.get_child(0) as Node3D).visible:
					for i in bp.size():
						maxr = maxf(maxr, bp[i].z)  # длина клина
						for j in range(i + 1, bp.size()):
							minsep = minf(minsep, bp[i].distance_to(bp[j]))
			t += 1.0
			step += 1
			if t > 100.0 + life + 5.0:
				break
		check(first_far and last_far, "вход и выход за видимостью (сид %d)" % sd)
		check(t - 100.0 <= float(cfg.lifetime_s) + 1.0, "жизнь ≤ lifetime_s")
		if dmin < vis:
			crossed += 1
			check(maxr < 105.0 and maxr > 40.0, "длина клина 50–100 м: %.0f" % maxr)
			check(minsep > 1.2, "птицы не слипаются: %.2f" % minsep)
		e.queue_free()
	check(total > 10, "клиньев по сидам: %d (призраков %d)" % [total, ng])
	check(crossed >= 1, "хотя бы один клин прошёл через зону видимости")


## Звук: 1/r, слышен раньше, чем виден клин; шина Ambient (или Master без шины), луп.
func test_sound() -> void:
	var e: EggGeese = null
	for sd in 30:
		e = _egg(sd)
		if not e.is_ghost():
			break
		e.queue_free()
	check(e != null and not e.is_ghost(), "клин есть")
	var p: AudioStreamPlayer3D = null
	for c in e.get_children():
		if c is AudioStreamPlayer3D:
			p = c
	check(p != null, "есть AudioStreamPlayer3D")
	if p != null:
		check(p.attenuation_model == AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE, "1/r")
		check(p.max_distance >= 2500.0 and p.max_distance > float(_cfg().vis_m) * 2.0, "слышен дальше видимости")
		var gain_near := p.unit_size / 200.0
		var gain_far := p.unit_size / 2000.0
		check(gain_far < gain_near * 0.15, "затухает с расстоянием (1/r)")
		check(20.0 * log(p.unit_size / 1500.0) / log(10.0) > -30.0, "на 1,5 км не тише −30 дБ")
		check(p.stream is AudioStreamOggVorbis and (p.stream as AudioStreamOggVorbis).loop, "ogg с лупом")
		check(p.bus == &"Ambient" or AudioServer.get_bus_index("Ambient") < 0, "шина Ambient")
	e.queue_free()


## К7 п. 4: то же расписание при любом шаге и прыжке; другой ключ — другое.
func test_schedule_deterministic() -> void:
	var a := _run("S1", 5)
	var b := _run("S1", 1)
	var c := _run("S1", 1800)
	var d := _run("S2", 5)
	check(a.size() > 5, "клиньев %d" % a.size())
	check(a == b, "шаг 5 с и 1 с совпадают")
	var sub := true
	for x in c:
		sub = sub and (x in a)
	check(c.size() > 0 and sub, "прыжок: те же (id, t0), %d из %d" % [c.size(), a.size()])
	check(a != d, "другой сид — другое расписание")


func _run(key: String, step: int) -> Array:
	var s := _sched(false)
	var t := 0
	while t <= 7200:
		s.step(_ctx(float(t), 4, 51.0, key))
		t += step
	var out := s.spawn_log.duplicate()
	s.queue_free()
	return out


## Плотность: доля полётов (~1 ч, пилот случайно в 1,5 км от центра) с клином в 1 км, в пик.
func test_peak_flights_share_and_cpu() -> void:
	var s := _sched(false)
	var rng := RandomNumberGenerator.new()
	rng.seed = 424242
	var flights := 100
	var seen := 0
	var flocks := 0
	var dists := []
	for f in flights:
		s.reset()
		s.roll_count = 0
		var key := "peak|%d" % f
		var ang := rng.randf() * TAU
		var rr := sqrt(rng.randf()) * 1500.0
		var pilot := Vector3(cos(ang) * rr, 300.0, sin(ang) * rr)
		var got := false
		for t in range(0, 3600, 10):
			var c := _ctx(float(t), 4, 51.0, key)
			c.pilot_pos = pilot
			s.step(c)
			for e in s.active():
				if e is EggGeese and not (e as EggGeese).is_ghost():
					var d := e.position.distance_to(pilot)
					if d < 1000.0:
						got = true
		flocks += s.spawn_log.size()
		if got:
			seen += 1
	var share := float(seen) / flights
	metrics["peak_flights_with_geese_share"] = share
	print("peak_flights_with_geese_share=%.2f (клиньев на полёт в расписании %.1f)" % [share, float(flocks) / flights])
	check(share >= 0.6 and share <= 0.98, "доля полётов с клином в пик %.2f" % share)
	s.queue_free()
	# CPU: кадр с видимым клином (позы 20–40 птиц + MultiMesh)
	var e: EggGeese = null
	for sd in 30:
		e = _egg(sd)
		if not e.is_ghost():
			break
		e.queue_free()
	var pilot_c := Vector3(0, 300, 0)
	var n := 600
	var t0u := Time.get_ticks_usec()
	for i in n:
		var c := _ctx(100.0 + 200.0 + float(i) * 0.016)
		c.pilot_pos = e.center_at(300.0) + Vector3(200, 0, 0)
		e.update(c)
	var ms := float(Time.get_ticks_usec() - t0u) / 1000.0 / n
	metrics["cpu_ms_geese"] = ms
	print("cpu_ms_geese=%.3f (птиц %d)" % [ms, e.bird_count()])
	check(ms < 1.0, "CPU %.3f мс/кадр" % ms)
	e.queue_free()
	pilot_c = Vector3.ZERO
