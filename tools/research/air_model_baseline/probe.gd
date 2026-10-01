extends Node
## AM-00: базовые цифры для сравнения масштабов 2 и 3 (план docs/plan/air_model.md), переиспользуемо
## для AM-07/AM-08. Headless, детерминированно (фиксированный сид). Ничего не трогает в
## atmosphere.gd/thermal_field.gd/game.gd — только читает их через публичное API.
##
## Запуск:
##   godot --headless --path . res://tools/research/air_model_baseline/probe.tscn \
##     -- [--out=tools/research/air_model_baseline/out/baseline.json]
##
## Печатает таблицы в консоль и пишет JSON (--out) с теми же числами — для сравнения в AM-07/AM-08.

const SEED := 42
const LEE_SITES: Array[Dictionary] = [
	{"loc": "altai", "site": "sinyukha_west"},
	{"loc": "askarovo", "site": "biyagoda_west"},
	{"loc": "aushkul", "site": "aushtau_east"},
]
const THERMAL_LOCATIONS: Array[String] = ["ongudai", "aushkul"]
const WIND_KMH := 20.0
const LEE_SAMPLE_HZ := 20.0
const LEE_DURATION_S := 180.0
const LEE_D_RANGE_M := 1000.0
const LEE_D_STEP_M := 20.0
const LEE_AGL: Array[float] = [10.0, 20.0, 35.0, 50.0, 65.0, 80.0, 100.0]
const THERMAL_DT_S := 5.0
const THERMAL_DURATION_S := 4.0 * 3600.0  ## 4 «игровых» часа при постоянной погоде medium
const AIR_VELOCITY_CALLS := 100000


func _ready() -> void:
	var out_path := "tools/research/air_model_baseline/out/baseline.json"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out_path = a.substr(6)

	var result := {
		"seed": SEED,
		"wind_kmh": WIND_KMH,
		"air_velocity_timing": _bench_air_velocity(),
		"lee_zone": _lee_zone_stats(),
		"thermals_per_day": _thermal_day_stats(),
	}

	print("\n== air_velocity_at, мкс/вызов ==")
	print(result.air_velocity_timing)

	print("\n== Подветренная зона: СКО w и частота рывков ==")
	print("локация/старт | СКО w, м/с | рывков/мин | порог |dw/dt|, м/с²")
	for row: Dictionary in result.lee_zone:
		print(
			(
				"%s | %.3f | %.2f | %.3f"
				% [row.key, row.sigma_w, row.jerks_per_min, row.jerk_threshold]
			)
		)

	print("\n== Термики за день (медленная выборка, постоянная погода medium) ==")
	print("локация | N | сила ср., м/с | потолок AGL ср., м | расстояние до соседа ср., м")
	for row: Dictionary in result.thermals_per_day:
		print(
			(
				"%s | %d | %.2f | %.0f | %.0f"
				% [
					row.location,
					row.count,
					row.mean_strength_ms,
					row.mean_ceiling_agl_m,
					row.mean_neighbor_dist_m
				]
			)
		)

	var dir := out_path.get_base_dir()
	if dir != "" and not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(result, "  "))
		f.close()
		print("\nJSON: %s" % out_path)
	else:
		push_error("не удалось записать " + out_path)

	get_tree().quit(0)


## --- общее ---


func _make_atmo(terrain: Terrain, wind_kmh: float, wind_from_deg: float) -> Atmosphere:
	var w: Dictionary = Config.get_config("weather/medium").duplicate(true)
	w.wind_speed_kmh = wind_kmh
	w.wind_from_deg = wind_from_deg
	var atmo_cfg: Dictionary = Config.get_config("atmosphere").duplicate(true)
	var atmo := Atmosphere.new()
	atmo.visuals_enabled = false
	atmo.seed_value = SEED
	atmo.configure(atmo_cfg, w)
	atmo.turbulence_enabled = true
	atmo.set_ground(terrain.height_at, terrain.thermal_source_strength_at, terrain.surface_at)
	return atmo


func _load_terrain(loc_id: String) -> Terrain:
	var terrain := Terrain.new()
	terrain.location_id = ""
	if not terrain.load_location(loc_id):
		terrain.free()
		return null
	return terrain


## --- 1. время air_velocity_at ---


func _bench_air_velocity() -> Dictionary:
	var terrain := _load_terrain("ongudai")
	var site: Dictionary = terrain.get_start_sites()[0]  # kayancha_south
	var heading: float = float(site.heading_deg)
	var atmo := _make_atmo(terrain, WIND_KMH, heading)
	var pos0: Vector3 = site.position
	atmo.set_focus(pos0)
	atmo.step(1.0)
	var base_h := terrain.height_at(pos0.x, pos0.z)
	var p := Vector3(pos0.x, base_h + 75.0, pos0.z)

	var t0 := Time.get_ticks_usec()
	var acc := 0.0  # чтобы вызов не выкинул оптимизатор
	for i in AIR_VELOCITY_CALLS:
		acc += atmo.air_velocity_at(p).y
	var t1 := Time.get_ticks_usec()
	atmo.free()
	terrain.free()
	return {
		"location": "ongudai/kayancha_south",
		"calls": AIR_VELOCITY_CALLS,
		"us_per_call": float(t1 - t0) / float(AIR_VELOCITY_CALLS),
		"checksum": acc,
	}


## --- 2. подветренная зона: СКО и рывки ---


## Точка глубже всего под линией тени за гребнем (как test_ridge_starts._scan_lee_point).
func _scan_lee_point(terrain: Terrain, site: Dictionary, wind_kmh: float) -> Dictionary:
	var heading: float = float(site.heading_deg)
	var flipped := fposmod(heading + 180.0, 360.0)
	var atmo := _make_atmo(terrain, wind_kmh, flipped)
	var pos0: Vector3 = site.position
	atmo.set_focus(pos0)
	atmo.step(1.0)
	var away_dir := Vector2(sin(deg_to_rad(heading)), -cos(deg_to_rad(heading)))
	var best_depth := -1.0e9
	var best_p := Vector3.ZERO
	var d := -LEE_D_RANGE_M
	while d <= LEE_D_RANGE_M:
		var p2: Vector2 = Vector2(pos0.x, pos0.z) + away_dir * d
		var gh := terrain.height_at(p2.x, p2.y)
		var gs: Vector4 = atmo.ground.sample(p2.x, p2.y)
		for agl: float in LEE_AGL:
			var depth: float = gs.w - (gh + agl)
			if depth > best_depth:
				best_depth = depth
				best_p = Vector3(p2.x, gh + agl, p2.y)
		d += LEE_D_STEP_M
	atmo.free()
	return {"pos": best_p, "depth": best_depth, "flipped_heading": flipped}


## СКО вертикальной скорости и частота «рывков» в подветренной точке одного старта.
## «Рывок» — определение для этой базы и для сравнения масштаба 3 (AM-08): выброс мгновенного
## |dw/dt| (по временному ряду w в неподвижной точке при advected-шуме) за 3·σ(dw/dt) самого
## ряда производной (порог считается из самих данных, не абсолютным числом — не зависит от
## общего уровня болтанки, что и нужно для сравнения «до/после» ±20 % из плана).
func _lee_series_stats(atmo: Atmosphere, pos: Vector3) -> Dictionary:
	var dt := 1.0 / LEE_SAMPLE_HZ
	var n := int(LEE_DURATION_S * LEE_SAMPLE_HZ)
	var ws := PackedFloat32Array()
	ws.resize(n)
	atmo.set_focus(pos)
	for i in n:
		atmo.step(dt)
		ws[i] = atmo.air_velocity_at(pos).y

	var mean := 0.0
	for w in ws:
		mean += w
	mean /= n
	var var_w := 0.0
	for w in ws:
		var_w += (w - mean) * (w - mean)
	var_w /= n
	var sigma_w := sqrt(var_w)

	var dwdt := PackedFloat32Array()
	dwdt.resize(n - 1)
	var mean_d := 0.0
	for i in n - 1:
		dwdt[i] = (ws[i + 1] - ws[i]) / dt
		mean_d += dwdt[i]
	mean_d /= (n - 1)
	var var_d := 0.0
	for d in dwdt:
		var_d += (d - mean_d) * (d - mean_d)
	var_d /= (n - 1)
	var sigma_d := sqrt(var_d)
	var thresh := 3.0 * sigma_d
	var jerks := 0
	for d in dwdt:
		if absf(d - mean_d) > thresh:
			jerks += 1
	var jerks_per_min := float(jerks) / (LEE_DURATION_S / 60.0)
	return {"sigma_w": sigma_w, "jerks_per_min": jerks_per_min, "jerk_threshold": thresh}


func _lee_zone_stats() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for entry: Dictionary in LEE_SITES:
		var loc_id: String = entry.loc
		var site_id: String = entry.site
		var terrain := _load_terrain(loc_id)
		var site: Dictionary = {}
		for s: Dictionary in terrain.get_start_sites():
			if String(s.id) == site_id:
				site = s
				break
		var lee := _scan_lee_point(terrain, site, WIND_KMH)
		var heading: float = float(site.heading_deg)
		var flipped := fposmod(heading + 180.0, 360.0)
		var atmo := _make_atmo(terrain, WIND_KMH, flipped)
		var stats := _lee_series_stats(atmo, lee.pos)
		atmo.free()
		terrain.free()
		stats["key"] = "%s/%s" % [loc_id, site_id]
		stats["lee_pos"] = [lee.pos.x, lee.pos.y, lee.pos.z]
		stats["lee_depth_m"] = lee.depth
		out.append(stats)
	return out


## --- 3. термики за день ---


func _thermal_day_stats() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for loc_id in THERMAL_LOCATIONS:
		var terrain := _load_terrain(loc_id)
		var site: Dictionary = terrain.get_start_sites()[0]
		var atmo := _make_atmo(terrain, 12.0, 270.0)  # weather/medium по умолчанию
		var focus: Vector3 = site.position
		var seen: Dictionary = {}  # id -> {strength, ceiling_agl, pos} — для силы/потолка за день
		## Расстояние до соседа считаем не по всем термикам за день (один и тот же источник
		## переживает много циклов за 4 часа — «соседи» получились бы почти в одной точке), а по
		## срезам: раз в snapshot_every шагов берём термики, живые ОДНОВРЕМЕННО (atmo.field.thermals
		## на этот момент), и для каждого — расстояние до ближайшего другого живого. Так метрика
		## отвечает на вопрос пилота «далеко ли до следующего термика».
		var snapshot_every := 12  # раз в 60 с при THERMAL_DT_S = 5
		var neighbor_sum := 0.0
		var neighbor_n := 0
		var t := 0.0
		var step_i := 0
		while t < THERMAL_DURATION_S:
			atmo.set_focus(focus)
			atmo.step(THERMAL_DT_S)
			for id in atmo.field.thermals:
				if seen.has(id):
					continue
				var th: AtmoThermal = atmo.field.thermals[id]
				var ground_h: float = th.src.y
				seen[id] = {
					"strength": th.strength,
					"ceiling_agl": th.top - ground_h,
					"pos": Vector2(th.src.x, th.src.z),
				}
			if step_i % snapshot_every == 0:
				var active: Array = atmo.field.thermals.values()
				var m := active.size()
				for i in m:
					var ti: AtmoThermal = active[i]
					var pi := Vector2(ti.src.x, ti.src.z)
					var best := 1.0e18
					for j in m:
						if j == i:
							continue
						var tj: AtmoThermal = active[j]
						var d: float = pi.distance_to(Vector2(tj.src.x, tj.src.z))
						if d < best:
							best = d
					if best < 1.0e17:
						neighbor_sum += best
						neighbor_n += 1
			t += THERMAL_DT_S
			step_i += 1
		atmo.free()
		terrain.free()

		var n := seen.size()
		var entries: Array = seen.values()
		var mean_strength := 0.0
		var mean_ceiling := 0.0
		for e: Dictionary in entries:
			mean_strength += float(e.strength)
			mean_ceiling += float(e.ceiling_agl)
		if n > 0:
			mean_strength /= n
			mean_ceiling /= n
		var mean_neighbor := 0.0
		if neighbor_n > 0:
			mean_neighbor = neighbor_sum / neighbor_n
		out.append(
			{
				"location": loc_id,
				"count": n,
				"mean_strength_ms": mean_strength,
				"mean_ceiling_agl_m": mean_ceiling,
				"mean_neighbor_dist_m": mean_neighbor,
				"neighbor_samples": neighbor_n,
			}
		)
	return out
