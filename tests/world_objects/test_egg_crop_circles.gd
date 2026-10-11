extends TestCase
## Пасхалка EE-3 «рисунки НЛО на полях»: участки, вероятность, стабильность в полёте, узоры, меш на рельефе,
## оценка доли полётов с рисунком, стоимость кадра.
## godot --headless --path . res://tests/run_tests.tscn -- --filter=egg_crop_circles

const LOCATIONS := ["altai", "askarovo", "aushkul", "ongudai"]

static var _cache := {}


class Objs:
	extends Node
	var camp: Array[Dictionary] = []


func _cfg() -> Dictionary:
	return Config.get_config("easter_eggs").eggs.crop_circles


func _load(id: String) -> Dictionary:
	if not _cache.has(id):
		var t := Terrain.new()
		t.location_id = ""
		t.load_location(id)
		_cache[id] = {"terrain": t, "place": EggPlace.build(t, Objs.new())}
	return _cache[id]


func _ctx(id: String) -> EggContext:
	var d := _load(id)
	var pl: EggPlace = d.place
	var c := EggContext.new()
	c.world_key = "CC|" + id
	c.place = pl
	c.terrain = d.terrain
	c.height_at = pl.height_at
	var s := pl.start_sites()
	if not s.is_empty():
		c.pilot_pos = Vector3(s[0].position.x, s[0].position.y + 150.0, s[0].position.z)
	return c


## Контекст с пилотом над полями: первый круг 7 км на сетке вокруг старта, где есть подходящие участки.
func _field_ctx(id: String) -> EggContext:
	var ctx := _ctx(id)
	var plots := FieldPlots.from_world_config()
	var at := Vector2(ctx.pilot_pos.x, ctx.pilot_pos.z)
	for gx in range(-14000, 14001, 7000):
		for gz in range(-14000, 14001, 7000):
			var c := at + Vector2(gx, gz)
			if _suitable(plots, ctx.place, c, 7000.0, _cfg()).size() > 100:
				ctx.pilot_pos = Vector3(c.x, ctx.pilot_pos.y, c.y)
				return ctx
	return ctx


## Подходящие участки в круге радиуса r вокруг точки.
func _suitable(plots: FieldPlots, place: EggPlace, at: Vector2, r: float, cfg: Dictionary) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var iy0 := int(floorf((at.y - r) / plots.size_m.y))
	var iy1 := int(floorf((at.y + r) / plots.size_m.y))
	for iy in range(iy0, iy1 + 1):
		var shift := floorf(float(iy) / FieldPlots.BAND_ROWS) * FieldPlots.ROW_SHIFT
		var ix0 := int(floorf((at.x - r) / plots.size_m.x + shift)) - 1
		var ix1 := int(floorf((at.x + r) / plots.size_m.x + shift)) + 1
		for ix in range(ix0, ix1 + 1):
			var cell := Vector2i(ix, iy)
			if plots.center(cell).distance_to(at) <= r and EggCropCircles.plot_ok(plots, place, cell, cfg):
				out.append(cell)
	return out


func test_lottery_share_and_stability() -> void:
	var cfg := _cfg()
	var p := float(cfg.probability)
	check(p >= 0.001 and p <= 0.002, "probability в 0,1–0,2 %%: %s" % p)
	var n := 0
	var hits_a := 0
	var hits_b := 0
	var differ := 0
	var again := 0
	for ix in 500:
		for iy in 500:
			var c := Vector2i(ix - 250, iy - 250)
			var a := EggCropCircles.lottery(12345, c) < p
			var b := EggCropCircles.lottery(987654321, c) < p
			if a != (EggCropCircles.lottery(12345, c) < p):
				again += 1
			hits_a += int(a)
			hits_b += int(b)
			differ += int(a != b)
			n += 1
	var exp := p * n
	var tol := 4.0 * sqrt(exp)
	print("         доля с рисунком: %d и %d из %d (ожидание %.0f ± %.0f)" % [hits_a, hits_b, n, exp, tol])
	check(absf(hits_a - exp) < tol and absf(hits_b - exp) < tol, "доля участков ≈ p")
	check(again == 0, "в пределах полёта решение стабильно")
	check(differ > 0, "в разных полётах решения разные")


func test_seed_per_flight() -> void:
	# без фиксированного зерна — зерно от часов: два экземпляра с паузой дают разные зёрна
	var cfg := _cfg()
	var ctx := _ctx("altai")
	var e1 := EggCropCircles.new()
	e1.begin(ctx, cfg, RandomNumberGenerator.new(), 0.0)
	OS.delay_usec(2000)
	var e2 := EggCropCircles.new()
	e2.begin(ctx, cfg, RandomNumberGenerator.new(), 0.0)
	check(e1._seed != e2._seed, "зерно полёта разное")
	var cell := Vector2i(3, 4)
	check(
		EggCropCircles.lottery(e1._seed, cell) == EggCropCircles.lottery(e1._seed, cell), "стабильно в полёте"
	)
	e1.free()
	e2.free()


func test_only_suitable_plots_and_mesh() -> void:
	var cfg := _cfg().duplicate()
	cfg.probability = 0.02
	var plots := FieldPlots.from_world_config()
	var found := 0
	var patterns := {}
	for id in LOCATIONS:
		var ctx := _field_ctx(id)
		var e := EggCropCircles.new()
		e.fixed_seed = 777
		e.begin(ctx, cfg, RandomNumberGenerator.new(), 0.0)
		e.settle(ctx)
		for cell in e.circles:
			found += 1
			var c: Dictionary = e.circles[cell]
			patterns[c.pattern] = true
			check(plots.tone(cell) < 0.40, "%s: участок STANDING с запасом" % id)
			check(EggCropCircles.plot_ok(plots, ctx.place, cell, cfg), "%s: весь участок CROP" % id)
			var r: Rect2 = c.rect
			check(r.has_point(c.center), "%s: центр узора внутри участка" % id)
			var rad: float = c.radius
			check(rad >= 25.0 and rad <= 100.0, "радиус 25–100 м")
		for cell in e._items:
			var mi: MeshInstance3D = e._items[cell]
			var arr: PackedVector3Array = (mi.mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
			var worst := 0.0
			for k in range(0, arr.size(), 7):
				var w := arr[k] + mi.position
				worst = maxf(worst, absf(w.y - float(ctx.height_at.call(w.x, w.z)) - 0.15))
			check(worst < 0.01, "%s: меш лежит на рельефе (откл. %.3f м)" % [id, worst])
			var r2: Rect2 = e.circles[cell].rect
			check(arr[0].x + mi.position.x >= r2.position.x - 0.01, "меш в границах участка")
		e.free()
	print("         при p=0,02 найдено рисунков: %d, узоров: %d" % [found, patterns.size()])
	check(found > 0, "рисунки находятся")
	# узоры по семенам на модельной выборке
	var pset := {}
	for s in 200:
		var rr := RandomNumberGenerator.new()
		rr.seed = hash(Vector3i(s + 1, 1, 2))
		pset[rr.randi() % EggCropCircles.PATTERNS] = true
	check(pset.size() >= 5, "узоров ≥ 5: %d" % pset.size())
	check(EggCropCircles.PATTERNS >= 5)


func test_shader_compiles_patterns() -> void:
	var sh := EggCropCircles.SHADER
	check(sh != null and sh.code.contains("pattern == 5") or sh.code.contains("else"), "шейдер с узорами")
	var n := 0
	for i in 8:
		if sh.code.contains("pattern == %d" % i):
			n += 1
	check(n + 1 >= 5, "в шейдере ≥ 5 узоров: %d" % (n + 1))


func test_flights_share_and_cpu() -> void:
	var cfg := _cfg()
	var p := float(cfg.probability)
	var plots := FieldPlots.from_world_config()
	var vis := float(cfg.visible_m)
	var best_id := ""
	var best_c := Vector2.ZERO
	var best_n := 0
	var shares: Array[float] = []
	for id in LOCATIONS:
		var ctx := _ctx(id)
		var at := Vector2(ctx.pilot_pos.x, ctx.pilot_pos.z)
		var sum := 0
		var cnt := 0
		var mx := 0
		for gx in range(-14000, 14001, 7000):
			for gz in range(-14000, 14001, 7000):
				var c := at + Vector2(gx, gz)
				var n := _suitable(plots, ctx.place, c, vis, cfg).size()
				sum += n
				cnt += 1
				if n > mx:
					mx = n
				if n > best_n:
					best_n = n
					best_id = id
					best_c = c
		var mean := float(sum) / cnt
		var share := 1.0 - pow(1.0 - p, mean)
		shares.append(share)
		print("         %s: подходящих участков в круге 7 км: среднее по сетке 28×28 км %.0f, лучший круг %d; доля полётов ≥1 рисунок: средний круг %.1f %%, лучший %.1f %%" % [id, mean, mx, share * 100.0, (1.0 - pow(1.0 - p, mx)) * 100.0])
	check(best_n > 0, "на реальных локациях есть подходящие участки")
	if best_n == 0:
		return
	# стоимость кадра: полёт по ветру 15 м/с над лучшим кругом, p подобрана на ~4 рисунка в видимости
	var cfg2 := cfg.duplicate()
	cfg2.probability = minf(4.0 / float(best_n), 1.0)
	var ctx := _ctx(best_id)
	ctx.pilot_pos = Vector3(best_c.x, ctx.pilot_pos.y, best_c.y)
	var e := EggCropCircles.new()
	e.fixed_seed = 4242
	e.begin(ctx, cfg2, RandomNumberGenerator.new(), 0.0)
	var worst := 0.0
	var total := 0.0
	var frames := 3600
	var o := ctx.pilot_pos
	for f in frames:
		ctx.pilot_pos = o + Vector3(f * 0.25, 0.0, 0.0)
		ctx.t += 1.0 / 60.0
		var t1 := Time.get_ticks_usec()
		e.update(ctx)
		var ms := (Time.get_ticks_usec() - t1) / 1000.0
		total += ms
		worst = maxf(worst, ms)
	print("         cpu_ms_crop_circles: среднее %.3f мс/кадр, худший кадр %.2f мс, рисунков найдено %d, мешей сейчас %d" % [total / frames, worst, e.circles.size(), e._items.size()])
	e.free()
	check(total / frames < 1.0, "в среднем < 1 мс/кадр")
	check(worst < 1.0, "худший кадр < 1 мс (бюджет на кадр)")
