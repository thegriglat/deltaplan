extends TestCase
## Пасхалка «рулоны сена» (EE-4): подходящие участки, детерминизм по координатам, ряды вдоль rows_axis,
## горка, сезон, число экземпляров и время кадра, доля сельской местности с рулонами.
## godot --headless --path . res://tests/run_tests.tscn -- --filter=egg_hay_bales

const LOCATIONS := ["altai", "askarovo", "aushkul", "ongudai"]

static var _cache := {}


class Objs:
	extends Node
	var camp: Array[Dictionary] = []


func _cfg() -> Dictionary:
	return Config.get_config("easter_eggs").eggs.hay_bales


func _load(id: String) -> Dictionary:
	if not _cache.has(id):
		var t := Terrain.new()
		t.location_id = ""
		t.load_location(id)
		_cache[id] = {"terrain": t, "place": EggPlace.build(t, Objs.new())}
	return _cache[id]


func _ctx(id: String, month := 7) -> EggContext:
	var d := _load(id)
	var pl: EggPlace = d.place
	var c := EggContext.new()
	c.world_key = "HB|" + id
	c.place = pl
	c.terrain = d.terrain
	c.height_at = pl.height_at
	c.month = month
	var s := pl.start_sites()
	if not s.is_empty():
		c.pilot_pos = Vector3(s[0].position.x, s[0].position.y + 100.0, s[0].position.z)
	return c


## Участки с рулонами в круге r вокруг (cx, cz): [{cell, plan}].
func _scan(id: String, key: String, cx: float, cz: float, r: float) -> Array:
	var pl: EggPlace = _load(id).place
	var fp := FieldPlots.from_world_config()
	var cfg := _cfg()
	var out: Array = []
	var y0 := int(floorf((cz - r) / fp.size_m.y))
	var y1 := int(floorf((cz + r) / fp.size_m.y))
	for cy in range(y0, y1 + 1):
		var sh := floorf(float(cy) / FieldPlots.BAND_ROWS) * FieldPlots.ROW_SHIFT
		for x in range(int(floorf((cx - r) / fp.size_m.x + sh)), int(floorf((cx + r) / fp.size_m.x + sh)) + 1):
			var cell := Vector2i(x, cy)
			if fp.center(cell).distance_to(Vector2(cx, cz)) > r:
				continue
			var p := EggHayBales.plan_cell(cell, fp, pl, cfg, key)
			if not p.is_empty():
				out.append({"cell": cell, "plan": p})
	return out


func _start(id: String) -> Vector2:
	var c := _ctx(id)
	return Vector2(c.pilot_pos.x, c.pilot_pos.z)


## Все участки с рулонами вокруг старта по всем локациям (кэшируется).
func _all(key_suffix := "") -> Array:
	var out: Array = []
	for id in LOCATIONS:
		var s := _start(id)
		for e in _scan(id, "HB|" + id + key_suffix, s.x, s.y, 4000.0):
			e.loc = id
			out.append(e)
	return out


func _run_node(ctx: EggContext, frames_max := 400) -> EggHayBales:
	var e := EggHayBales.new()
	var rng := RandomNumberGenerator.new()
	e.begin(ctx, _cfg(), rng, 0.0)
	for i in frames_max:
		ctx.t += 0.05
		e.update(ctx)
		if e.rebuilds > 0 and not e._job_on:
			break
	return e


# ---------------------------------------------------------------- участки


func test_suitable_cells_only() -> void:
	var fp := FieldPlots.from_world_config()
	var n := 0
	var n_mown := 0
	var n_meadow := 0
	for e in _all():
		var pl: EggPlace = _load(e.loc).place
		var r := fp.rect(e.cell)
		var want := SurfaceLayer.CROP if e.plan.type == "mown" else SurfaceLayer.GRASS
		if e.plan.layout == "rows":
			for t in e.plan.xf:
				check(pl.surface_at(t.origin.x, t.origin.z) == want, "%s %s: рулон на нужном покрове" % [e.loc, e.cell])
				check(r.grow(0.5).has_point(Vector2(t.origin.x, t.origin.z)), "рулон внутри участка")
		else:
			var o: Vector3 = e.plan.xf[0].origin
			check(pl.surface_at(o.x, o.z) == want, "%s %s: горка на нужном покрове" % [e.loc, e.cell])
		if e.plan.type == "mown":
			n_mown += 1
			check(fp.kind(e.cell) == FieldPlots.MOWN, "скошенный участок")
			check(fp.tone(e.cell) >= FieldPlots.MOWN_MIN + 0.03 - 1e-6, "с запасом от порога")
		else:
			n_meadow += 1
			check(float(pl.nearest_place(r.get_center().x, r.get_center().y).dist_m) <= 2500.0, "луг у посёлка")
		for t in e.plan.xf:
			check(is_finite(t.origin.y), "рулон на рельефе")
		n += 1
	print("         участков с рулонами: %d (скошенных %d, луговых %d)" % [n, n_mown, n_meadow])
	check(n > 0, "рулоны нашлись хоть где-то")


func test_deterministic_by_coordinates() -> void:
	var fp := FieldPlots.from_world_config()
	var a := _all()
	var b := _all()
	check(a.size() == b.size(), "два прогона — то же число участков")
	for i in mini(a.size(), b.size()):
		var pa: Dictionary = a[i].plan
		var pb: Dictionary = b[i].plan
		check(a[i].cell == b[i].cell and pa.layout == pb.layout and pa.xf.size() == pb.xf.size(), "то же")
		if pa.xf.size() == pb.xf.size() and pa.xf.size() > 0:
			check(pa.xf[0] == pb.xf[0] and pa.xf[-1] == pb.xf[-1], "те же трансформы")
	var other := _all("|другой")
	var diff := other.size() != a.size()
	if not diff:
		for i in a.size():
			if a[i].cell != other[i].cell or a[i].plan.xf.size() != other[i].plan.xf.size():
				diff = true
				break
	check(diff, "другой ключ мира — другая раскладка")
	# не зависит от позиции пилота: тот же участок из другого скана
	if not a.is_empty():
		var e: Dictionary = a[0]
		var c := fp.center(e.cell)
		var again := _scan(e.loc, "HB|" + e.loc, c.x + 500.0, c.y - 300.0, 1500.0)
		var found := false
		for x in again:
			if x.cell == e.cell:
				found = x.plan.xf.size() == e.plan.xf.size() and x.plan.xf[0] == e.plan.xf[0]
		check(found, "тот же участок — те же рулоны при другом центре обзора")


func test_rows_parallel_to_axis() -> void:
	var n_rows := 0
	for e in _all():
		var p: Dictionary = e.plan
		if p.layout != "rows":
			continue
		n_rows += 1
		var ax: Vector2 = p.axis
		var pp := Vector2(-ax.y, ax.x)
		var by_row := {}
		for i in p.xf.size():
			var o: Vector3 = p.xf[i].origin
			var rk: int = p.row[i]
			if not by_row.has(rk):
				by_row[rk] = []
			by_row[rk].append(Vector2(o.x, o.z))
		var qs: Array = []
		for rk in by_row:
			var pts: Array = by_row[rk]
			var qmin := 1e9
			var qmax := -1e9
			var amin := 1e9
			var amax := -1e9
			for v in pts:
				qmin = minf(qmin, v.dot(pp))
				qmax = maxf(qmax, v.dot(pp))
				amin = minf(amin, v.dot(ax))
				amax = maxf(amax, v.dot(ax))
			check(qmax - qmin <= 2.0 * 0.6 + 0.01, "ряд %d прямой вдоль rows_axis (разброс поперёк %.2f)" % [rk, qmax - qmin])
			if pts.size() >= 2:
				var steps: Array = []
				var sorted := pts.duplicate()
				sorted.sort_custom(func(u, v): return u.dot(ax) < v.dot(ax))
				for k in range(1, sorted.size()):
					steps.append(sorted[k].dot(ax) - sorted[k - 1].dot(ax))
				for s in steps:
					check(s >= 20.0 - 3.1, "шаг вдоль ряда ≥ ~17 м (%.1f)" % s)
			qs.append((qmin + qmax) * 0.5)
		qs.sort()
		for k in range(1, qs.size()):
			check(qs[k] - qs[k - 1] >= 15.0 - 1.3, "ряды не теснее ~14 м")
		# ось рулона поперёк ряда: локальная X ⟂ rows_axis (с разбросом поворота)
		for t in p.xf:
			var xa: Vector3 = t.basis.x
			var h := Vector2(xa.x, xa.z).normalized()
			check(absf(h.dot(ax)) < sin(deg_to_rad(8.0) + deg_to_rad(16.0)), "ось рулона поперёк ряда")
	print("         участков с рядами: %d" % n_rows)
	check(n_rows > 0, "рядовые раскладки нашлись")


func test_pile_geometry() -> void:
	var n_piles := 0
	for e in _all():
		var p: Dictionary = e.plan
		if p.layout != "pile":
			continue
		n_piles += 1
		var tiers: PackedInt32Array = p.tier
		var cnt := {}
		for tv in tiers:
			cnt[tv] = int(cnt.get(tv, 0)) + 1
		var depth: int = cnt[0] / (3 if cnt.has(2) else 4)
		var shape: Array = [3, 2, 1] if cnt.has(2) else [4, 3]
		for ti in shape.size():
			check(cnt.get(ti, 0) == shape[ti] * depth, "ярус %d: %d×%d" % [ti, shape[ti], depth])
		# верхний ярус: ~1,3 м над нижним и между двумя нижними того же среза
		for i in p.xf.size():
			if p.tier[i] != 1:
				continue
			var o: Vector3 = p.xf[i].origin
			var below: Array = []
			for j in p.xf.size():
				if p.tier[j] == 0 and p.row[j] == p.row[i]:
					below.append(p.xf[j].origin)
			below.sort_custom(func(u, v): return u.distance_to(o) < v.distance_to(o))
			check(below.size() >= 2, "под вторым ярусом два рулона")
			if below.size() >= 2:
				var up: Vector3 = (p.xf[i].basis.y)
				var dh: float = (o - below[0]).dot(up)
				check(absf(dh - 1.3) < 0.1, "второй ярус на ~1,3 м (%.2f)" % dh)
				var mid: Vector3 = (below[0] + below[1]) * 0.5
				check(Vector2(o.x - mid.x, o.z - mid.z).length() < 0.35, "между двумя нижними")
				check(absf(below[0].distance_to(below[1]) - 1.55) < 0.1, "нижние касаются боками")
			break
		if n_piles >= 6:
			break
	check(n_piles > 0, "горки нашлись")


# ---------------------------------------------------------------- сезон


func test_season() -> void:
	var pick: Dictionary = {}
	for e in _all():
		if not pick.has(e.plan.layout):
			pick[e.plan.layout] = e
	check(pick.size() == 2, "нашлись обе раскладки")
	var cfg := _cfg()
	if pick.size() < 2:
		return
	# вне сезона обеих раскладок — пусто
	var e0: Dictionary = pick.rows
	var c0 := FieldPlots.from_world_config().center(e0.cell)
	for m in [1, 2, 3, 4, 5, 12]:
		var ctx := _ctx(e0.loc, m)
		ctx.pilot_pos = Vector3(c0.x, 500.0, c0.y)
		var node := _run_node(ctx)
		check(node.instances == 0, "месяц %d: рулонов нет (%d)" % [m, node.instances])
		check(not EggHayBales.can_appear(ctx, cfg), "месяц %d: can_appear ложно" % m)
		node.free()
	var ctx7 := _ctx(e0.loc, 7)
	check(EggHayBales.can_appear(ctx7, cfg), "июль: можно")
	# месяцы 10–11: только горки (число экземпляров не больше, чем в июле; рядов нет)
	ctx7.pilot_pos = Vector3(c0.x, 500.0, c0.y)
	var n7 := _run_node(ctx7)
	var ctx10 := _ctx(e0.loc, 10)
	ctx10.pilot_pos = ctx7.pilot_pos
	var n10 := _run_node(ctx10)
	check(n10.instances < n7.instances, "октябрь: рядов нет, остались только горки (%d < %d)" % [n10.instances, n7.instances])
	n7.free()
	n10.free()
	var cp := FieldPlots.from_world_config().center(pick.pile.cell)
	var ctx11 := _ctx(pick.pile.loc, 11)
	ctx11.pilot_pos = Vector3(cp.x, 500.0, cp.y)
	var n11 := _run_node(ctx11)
	check(n11.instances >= pick.pile.plan.xf.size(), "ноябрь: горки на месте (%d)" % n11.instances)
	n11.free()


# ---------------------------------------------------------------- числа


func test_numbers() -> void:
	var cfg := _cfg()
	var inst_max := 0
	var worst_frame := 0.0
	var steady_sum := 0.0
	var steady_n := 0
	var rebuild_ms := 0.0
	var share_hits := 0
	var share_total := 0
	for id in LOCATIONS:
		var ctx := _ctx(id, 7)
		var s := _start(id)
		var pl: EggPlace = ctx.place
		var rng := RandomNumberGenerator.new()
		rng.seed = ("share|" + id).hash()
		var fp := FieldPlots.from_world_config()
		# доля сельской местности (поле или луг) с рулонами в радиусе видимости: считаем по участкам
		var all := _scan(id, ctx.world_key, s.x, s.y, 6000.0)
		var R: float = cfg.visible_m
		for k in 200:
			var a := rng.randf() * TAU
			var d := sqrt(rng.randf()) * 4500.0
			var x := s.x + cos(a) * d
			var z := s.y + sin(a) * d
			var sf := pl.surface_at(x, z)
			if sf != SurfaceLayer.CROP and sf != SurfaceLayer.GRASS:
				continue
			share_total += 1
			for e in all:
				if fp.center(e.cell).distance_to(Vector2(x, z)) <= R:
					share_hits += 1
					break
		# кадры: пилот летит, камера сдвигается
		var node := EggHayBales.new()
		node.begin(ctx, cfg, rng, 0.0)
		var pos := Vector2(s.x, s.y)
		var dir := Vector2(1, 0.3).normalized()
		var steady_us := 0
		var steady_f := 0
		for f in 1500:
			ctx.t += 0.016
			pos += dir * 0.3  # ~19 м/с
			ctx.pilot_pos = Vector3(pos.x, 300.0, pos.y)
			var was_job: bool = node._job_on
			node.update(ctx)
			worst_frame = maxf(worst_frame, node.last_update_us / 1000.0)
			if was_job or node._job_on:
				rebuild_ms = maxf(rebuild_ms, node.last_update_us / 1000.0)
			elif f > 60:
				steady_us += node.last_update_us
				steady_f += 1
			inst_max = maxi(inst_max, node.instances)
		steady_sum += steady_us
		steady_n += steady_f
		print("         %s: экземпляров %d, пересборок %d" % [id, node.instances, node.rebuilds])
		node.free()
	var mean_ms := steady_sum / maxf(steady_n, 1) / 1000.0
	var share := float(share_hits) / maxf(share_total, 1)
	print("         instances_max=%d  cpu_ms_hay_bales: среднее %.4f, пересборка (худший кадр) %.2f, худший вообще %.2f" % [inst_max, mean_ms, rebuild_ms, worst_frame])
	print("         rural_share_with_bales=%.3f (%d из %d точек)" % [share, share_hits, share_total])
	check(inst_max > 0, "экземпляры есть")
	check(inst_max <= 20000, "экземпляров не больше 20000")
	check(rebuild_ms < 8.0, "кадр пересборки < 8 мс (%.2f)" % rebuild_ms)
