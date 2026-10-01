extends TestCase
## Пустырь вокруг точки старта (SF-1, docs/start_fixes_contracts.md → К1 v2):
## радиус R = start_search.clearing_radius_m ≥ 2 × длины разбега (живой прогон GroundRun),
## после Terrain.add_start_clearing в круге нет леса и деревьев (лес → луг), кустарник, кусты и
## трава — как были, за кругом лес остаётся.

const Sim := preload("res://tests/flight/flight_sim.gd")

static var _terrain: Terrain
## Предел разбега в самом тесте, с: в игре срыва по времени нет (К3 v3), пилот бежит, сколько
## нужно; для L_run пустыря 10 с бега с места — заведомо дальше любого разумного разбега.
const RUN_MAX_S := 10.0

static var _spot: Dictionary = {}


## Длина разбега, м: горизонтальная дистанция от старта с места до отрыва в штиль на склоне
## slope_deg (курс — вниз по склону, трапеция нейтрально) при эталонной массе крыла. Не взлетел
## (срыв или дольше RUN_MAX_S) — дистанция к этому моменту. {dist, time, took_off}.
static func run_length(wing: String, slope_deg: float) -> Dictionary:
	var k := tan(deg_to_rad(slope_deg))
	var ground := func(_x: float, z: float) -> float: return 1000.0 + k * z  # вниз на север
	var calm := func(_p: Vector3) -> Vector3: return Vector3.ZERO
	var m := Sim.make(wing)
	m.reset_on_ground(Vector3(0, 1000.0, 0), 0.0)
	var t_max := RUN_MAX_S
	var inp := Sim.input(0.0, 0.0, true)
	var t := 0.0
	while t < t_max and m.mode == FlightModel.Mode.GROUND:
		m.step(Sim.DT, inp, calm, ground)
		t += Sim.DT
	var d := Vector2(m.position.x, m.position.z).length()
	return {
		"dist": d,
		"time": t,
		"took_off": m.mode == FlightModel.Mode.AIR,
		"failure": m.takeoff_failure,
	}


func test_radius_covers_two_runs() -> void:
	var ss: Dictionary = Config.get_config("game").start_search
	var slope := float(ss.min_slope_deg)
	var r := float(ss.clearing_radius_m)
	var longest := 0.0
	var who := ""
	for p in Config.list_configs("wings"):
		var w := String(p).get_file()
		var run := run_length(w, slope)
		print(
			(
				"  L_run %-14s %5.1f м за %4.1f с (%s)"
				% [w, run.dist, run.time, "отрыв" if run.took_off else "срыв " + run.failure]
			)
		)
		if float(run.dist) > longest:
			longest = float(run.dist)
			who = w
	check(longest > 5.0, "разбег измерен: %.1f м" % longest)
	check(
		r >= 2.0 * longest,
		"R = %.0f м ≥ 2·L_run = 2·%.1f м (%s, склон %.0f°)" % [r, longest, who, slope]
	)


func _ongudai() -> Terrain:
	if _terrain == null:
		_terrain = Terrain.new()
		_terrain.location_id = ""
		_terrain.load_location("ongudai")
	return _terrain


## Доля леса (forest_at ≥ 0,5) по сетке step внутри круга r вокруг c.
static func _forest_share(t: Terrain, c: Vector2, r: float, step: float) -> float:
	var n := 0
	var f := 0
	var k := int(r / step)
	for j in range(-k, k + 1):
		for i in range(-k, k + 1):
			var q := c + Vector2(i, j) * step
			if q.distance_to(c) > r:
				continue
			n += 1
			if t.forest_at(q.x, q.y) >= 0.5:
				f += 1
	return float(f) / maxi(n, 1)


## Старт «с карты» в лесу: пригодный склон (StartPlacement, как Game._choose_start) в глубине
## леса, вдали от встроенных стартов. {position, heading_deg}.
func _forest_launch(t: Terrain, r: float) -> Dictionary:
	if not _spot.is_empty():
		return _spot
	var cfg: Dictionary = Config.get_config("game").start_search
	var b := t.detail_bounds().grow(-2.0 * r)
	var best := -1.0
	var sites := t.get_start_sites()
	var step := 150.0
	for j in int(b.size.y / step):
		for i in int(b.size.x / step):
			var x := b.position.x + i * step
			var z := b.position.y + j * step
			if t.forest_at(x, z) < 0.5:
				continue
			var near := false
			for s in sites:
				near = (
					near or Vector2(s.position.x, s.position.z).distance_to(Vector2(x, z)) < 3.0 * r
				)
			if near:
				continue
			var e := StartPlacement.evaluate(t.height_at, x, z, cfg)
			if not e.ok:
				continue
			var share := _forest_share(t, Vector2(x, z), r, 20.0)
			if share > best:
				best = share
				_spot = e
				if share > 0.95:
					return _spot
	return _spot


func test_clearing_after_load() -> void:
	var t := _ongudai()
	check(t.trees is TerrainTreeModels and t.impostors != null, "деревья-модели и импостеры есть")
	var r := Terrain.start_clearing_radius_m()
	var spot := _forest_launch(t, r)
	check(not spot.is_empty(), "нашлась точка старта в лесу")
	if spot.is_empty():
		return
	var c := Vector2(spot.position.x, spot.position.z)
	var share0 := _forest_share(t, c, r, 10.0)
	print(
		(
			"  старт в лесу: %s, курс %.0f°, склон %.1f°, доля леса в R %.2f"
			% [c, spot.heading_deg, spot.slope_deg, share0]
		)
	)
	check(share0 > 0.5, "до пустыря — лес: доля %.2f" % share0)
	var tm := t.trees as TerrainTreeModels
	var before_trees := _count_within(_tree_positions(tm, c), c, r)
	var before_imp := t.impostors.present_positions(c, 0.0, r).size()
	check(
		before_trees + before_imp > 50,
		"до пустыря деревья в круге: %d + %d" % [before_trees, before_imp]
	)
	# кольцо снаружи — запомнить
	var ring := PackedVector2Array()
	for k in 72:
		for d in [r + 30.0, r + 80.0, r + 200.0]:
			ring.append(c + Vector2.from_angle(TAU * k / 72.0) * d)
	var ring_before := PackedFloat32Array()
	for q in ring:
		ring_before.append(t.forest_at(q.x, q.y))
	var grid := _grid(c, r, 5.0)
	var cls_before := PackedInt32Array()
	for q in grid:
		cls_before.append(t.surface_at(q.x, q.y))
	var rev := t.surface_revision
	var t0 := Time.get_ticks_usec()
	t.add_start_clearing(c.x, c.y, r)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	print("  add_start_clearing R=%.0f м: %.1f мс" % [r, ms])
	check(t.surface_revision == rev + 1, "версия карты поверхности выросла")
	_check_forest_gone(t, grid, cls_before)
	var trees_in := _count_within(_tree_positions(tm, c), c, r)
	check(trees_in == 0, "деревьев-моделей в круге: %d" % trees_in)
	var imp_in := t.impostors.present_positions(c, 0.0, r).size()
	check(imp_in == 0, "импостеров в круге: %d" % imp_in)
	var lone := _count_within(_scatter_positions(t, c, r, true), c, r)
	check(lone == 0, "одиночных деревьев (ShrubScatter) в круге: %d" % lone)
	var changed := 0
	var forest_left := 0
	for i in ring.size():
		var f := t.forest_at(ring[i].x, ring[i].y)
		if f != ring_before[i]:
			changed += 1
		if f >= 0.5:
			forest_left += 1
	check(changed == 0, "за кругом лес не тронут: изменилось %d из %d" % [changed, ring.size()])
	check(
		forest_left > ring.size() / 4,
		"за кругом лес остаётся: %d из %d" % [forest_left, ring.size()]
	)
	# разбег с пустыря не кончается кронами: разбег и первые 100 м полёта
	for wind in [0.0, 3.0]:
		var run := _run_from(t, spot, wind)
		check(run.crash == "", "ветер %.0f м/с: без удара о кроны (%s)" % [wind, run.crash])
		print("  разбег, ветер %.0f м/с: %s, пройдено %.0f м" % [wind, run.result, run.dist])


func _tree_positions(tm: TerrainTreeModels, c: Vector2) -> PackedVector2Array:
	tm.rebuild_now(c)
	var out := PackedVector2Array()
	for b in tm.placer.buffers.size():
		var buf := tm.placer.buffers[b]
		for k in tm.placer.counts[b]:
			out.append(Vector2(buf[k * TreePlacer.STRIDE + 3], buf[k * TreePlacer.STRIDE + 11]))
	return out


static func _count_within(pos: PackedVector2Array, c: Vector2, r: float) -> int:
	var n := 0
	for p in pos:
		if p.distance_to(c) <= r:
			n += 1
	return n


## Узлы сетки step внутри круга r вокруг c.
static func _grid(c: Vector2, r: float, step: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var k := int(r / step)
	for j in range(-k, k + 1):
		for i in range(-k, k + 1):
			var q := c + Vector2(i, j) * step
			if q.distance_to(c) <= r:
				out.append(q)
	return out


## Инварианты К1 v2 по сетке: леса нет (forest_at = 0, класс не FOREST), кустарник — где был,
## бывший лес — луг (GRASS; на крутом — скалы BARE, как у любого луга).
func _check_forest_gone(t: Terrain, grid: PackedVector2Array, before: PackedInt32Array) -> void:
	var forest := 0
	var shrub_lost := 0
	var was_forest := 0
	var now_grass := 0
	for i in grid.size():
		var q := grid[i]
		var cls := t.surface_at(q.x, q.y)
		if t.forest_at(q.x, q.y) != 0.0 or cls == SurfaceLayer.FOREST:
			forest += 1
		if before[i] == SurfaceLayer.SHRUB and cls != SurfaceLayer.SHRUB:
			shrub_lost += 1
		if before[i] == SurfaceLayer.FOREST:
			was_forest += 1
			if cls == SurfaceLayer.GRASS or cls == SurfaceLayer.BARE:
				now_grass += 1
	check(forest == 0, "в круге R нет леса (forest_at, surface_at): узлов %d" % forest)
	check(shrub_lost == 0, "кустарник в круге сохранён: пропало узлов %d" % shrub_lost)
	check(
		was_forest == 0 or now_grass == was_forest,
		"бывший лес — луг: %d из %d" % [now_grass, was_forest]
	)


## Кусты (trees = false) или одиночные деревья (true) ShrubScatter во всех тайлах, задевающих круг.
func _scatter_positions(t: Terrain, c: Vector2, r: float, trees: bool) -> PackedVector2Array:
	var s := ShrubScatter.new()
	s.terrain = t
	var cfg: Dictionary = Config.get_config("vegetation").shrubs
	check(s.setup(cfg), "модели кустов загружены")
	s._check_key()
	var out := PackedVector2Array()
	var tile := float(cfg.trees.tile_m) if trees else float(cfg.tile_m)
	for j in range(floori((c.y - r) / tile), floori((c.y + r) / tile) + 1):
		for i in range(floori((c.x - r) / tile), floori((c.x + r) / tile) + 1):
			var d: Dictionary = s.build_tree_tile(i, j) if trees else s.build_tile(i, j)
			var xf: PackedFloat32Array = d.xf
			for n in xf.size() / 12:
				out.append(Vector2(xf[n * 12 + 3], xf[n * 12 + 11]))
	s.free()
	return out


## Разбег (sport, эталонная масса, трапеция нейтрально) с точки spot вниз по склону при встречном
## ветре wind, до 100 м полёта после отрыва; CollisionCheck — каждый шаг, как в Game.
func _run_from(t: Terrain, spot: Dictionary, wind: float) -> Dictionary:
	var m := Sim.make("sport")
	m.reset_on_ground(spot.position, float(spot.heading_deg))
	var hd := TerrainGeo.heading_vector(float(spot.heading_deg))
	var air := func(_p: Vector3) -> Vector3: return -hd * wind
	var cc := CollisionCheck.new()
	cc.setup(null, t.forest_at, m.span, float(Config.value("flight", "visual.hang_height_m", 2.0)))
	var inp := Sim.input(0.0, 0.0, true)
	var p0 := Vector2(spot.position.x, spot.position.z)
	var lift_d := -1.0
	var out := {"crash": "", "result": "", "dist": 0.0}
	var time := 0.0
	while time < 60.0:
		m.step(Sim.DT, inp, air, t.height_at)
		time += Sim.DT
		var d := Vector2(m.position.x, m.position.z).distance_to(p0)
		out.dist = d
		var hit := cc.check(m.telemetry)
		if not hit.is_empty():
			out.crash = String(hit.reason)
			break
		if m.mode == FlightModel.Mode.FAILED:
			out.result = "срыв " + m.takeoff_failure
			break
		if m.mode == FlightModel.Mode.AIR and lift_d < 0.0:
			lift_d = d
			inp = Sim.input()
		if lift_d >= 0.0 and d > lift_d + 100.0:
			out.result = "отрыв на %.0f м, 100 м полёта" % lift_d
			break
		if lift_d >= 0.0 and m.mode != FlightModel.Mode.AIR:
			out.result = "сел через %.0f м" % d
			break
	return out


## Рельеф с карты — без маски 10 м (лес только по классам): пустырь по карте классов,
## кустарник (каждый 7-й узел) остаётся.
func test_clearing_no_mask() -> void:
	var n := 161
	var hs := PackedFloat32Array()
	hs.resize(n * n)
	for j in n:
		for i in n:
			hs[j * n + i] = 800.0 + 0.3 * (j - 80) * 25.0
	var cls := PackedByteArray()
	cls.resize(n * n)
	for j in n:
		for i in n:
			cls[j * n + i] = SurfaceLayer.FOREST if (i + j) % 7 != 0 else SurfaceLayer.SHRUB
	var t := Terrain.new()
	t.location_id = ""
	t.layers = [HeightLayer.from_heights("p", n, n, 25.0, -2000.0, -2000.0, hs)]
	var world: Dictionary = Config.get_config("world")
	t.refresh_sun()
	t.set_surfaces(
		[SurfaceLayer.from_classes("p", n, n, 25.0, -2000.0, -2000.0, cls)],
		world.surface,
		world.terrain_look
	)
	check(t.get_start_clearings().is_empty(), "встроенных стартов нет — пустырей нет")
	var r := Terrain.start_clearing_radius_m()
	var c := Vector2(130.0, -270.0)
	var grid := _grid(c, r, 5.0)
	var before := PackedInt32Array()
	var shrubs := 0
	for q in grid:
		before.append(t.surface_at(q.x, q.y))
		shrubs += 1 if before[before.size() - 1] == SurfaceLayer.SHRUB else 0
	check(shrubs > 50, "в круге есть кустарник: узлов %d" % shrubs)
	t.add_start_clearing(c.x, c.y, r)
	check(t.get_start_clearings() == [Vector3(c.x, c.y, r)], "пустырь записан")
	_check_forest_gone(t, grid, before)
	var bushes := _count_within(_scatter_positions(t, c, r, false), c, r)
	check(bushes > 0, "кусты в круге остались: %d" % bushes)
	var lone := _count_within(_scatter_positions(t, c, r, true), c, r)
	check(lone == 0, "одиночных деревьев в круге: %d" % lone)
	var outside := c + Vector2(r + 60.0, 0.0)
	check(t.forest_at(outside.x, outside.y) == 1.0, "за кругом лес")
	t.free()
