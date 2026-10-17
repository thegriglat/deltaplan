extends TestCase
## FL-10: порядок загрузки места — старт и поле воздуха до объектов мира (поле считается, пока строятся объекты).
## Прежний порядок (объекты → выбор старта → снимок поверхности для поля) и новый (выбор старта → снимок
## поверхности → объекты, общие данные места и маска просек — в рабочих потоках) на Онгудае со стартом с карты
## в лесу (пустырь у старта меняет карту поверхности): тот же старт, тот же снимок поверхности, тот же ключ кеша
## поля (AirFieldCache.name_of), та же маска просек и те же объекты (перепись узлов, преобразований, экземпляров
## MultiMesh и препятствий), план домов и препятствия у старта для ботов.
## godot --headless --path . res://tests/run_tests.tscn -- --filter=load_order

const ID := "ongudai"
## Перепись поддерева (хеш преобразований, буферов MultiMesh, мешей) и препятствий — как в тесте FL-6.
const Census := preload("res://tests/world_objects/test_osm_threaded.gd")
## Условия поля (как AirRuntime.conditions_of по умолчанию автостарта: 12:00, 3 м/с, ясно, 26 °C).
const COND := {hour = 12.0, u10 = 3.0, wdir = 270.0, t_max = 26.0, sky = "clear", wind_ref = "start"}

static var _pick := Vector2(NAN, NAN)


func _root() -> Node:
	var tree_root := (Engine.get_main_loop() as SceneTree).root
	return tree_root.get_child(tree_root.get_child_count() - 1)


static func _load() -> Terrain:
	var t := Terrain.new()
	t.location_id = ""
	t.load_location(ID)
	return t


## Точка «с карты» в лесу (пригодный склон), вдали от встроенных стартов — как Game._choose_start её примет.
static func _forest_pick(t: Terrain) -> Vector2:
	var cfg: Dictionary = Config.get_config("game").start_search
	var r := Terrain.start_clearing_radius_m()
	var b := t.detail_bounds().grow(-3.0 * r)
	var step := 300.0
	for j in int(b.size.y / step):
		for i in int(b.size.x / step):
			var x := b.position.x + i * step
			var z := b.position.y + j * step
			if t.forest_at(x, z) < 0.5:
				continue
			var near := false
			for s in t.get_start_sites():
				near = near or Vector2(s.position.x, s.position.z).distance_to(Vector2(x, z)) < 3.0 * r
			if not near and bool(StartPlacement.evaluate(t.height_at, x, z, cfg).ok):
				return Vector2(x, z)
	return Vector2(NAN, NAN)


## Одна загрузка: new_order — старт и снимок поля до объектов (FL-10), иначе — после (как было).
func _run(new_order: bool) -> Dictionary:
	var t := _load()
	if is_nan(_pick.x):
		_pick = _forest_pick(t)
	var wl := WorldLink.new()
	_root().add_child(wl)
	var air := Node.new()
	var pilot := Node3D.new()
	if not new_order:
		wl.link(t, air, pilot)  # прежний порядок: всё в одном кадре до выбора старта
	# Game._choose_start, ветка «точка с карты»
	var cfg: Dictionary = Config.get_config("game").start_search
	var e := StartPlacement.evaluate(t.height_at, _pick.x, _pick.y, cfg)
	var start: Vector3 = e.position
	t.add_start_clearing(start.x, start.z, float(cfg.clearing_radius_m))
	var ar := AirRuntime.new()
	var cond := COND.duplicate()
	ar.setup(null, AirRuntime.place_of(t, 6.0, 7, 15), func() -> Dictionary: return cond)
	ar.set_focus(null, start)
	ar._wait_surface()
	var key := ar.cache_key(cond)
	var out := {
		"start": start,
		"heading": float(e.heading_deg),
		"key": AirFieldCache.name_of(key) if not key.is_empty() else "",
		"key_empty": key.is_empty(),
		"surface": ar._surface_key(),
	}
	if new_order:
		await wl.link_async(t, air, pilot)  # объекты — после, порциями; данные места и маска — в потоках
	var mask: Image = t._clearings[0] if t._clearings.size() > 0 else null
	out["mask"] = hash(mask.get_data()) if mask != null else 0
	var world := {}
	if wl.objects != null:
		for ch in wl.objects.get_children():
			world[String(ch.name)] = Census.census(ch)
		world["obstacles"] = Census.obstacle_census(wl.objects.get(&"obstacles"))
		out["houses"] = hash(wl.objects.get(&"houses"))
	out["objects"] = JSON.stringify(world, "", true)
	# камни, кусты и деревья у старта — препятствия мест ожидания ботов (BotPilots.start_obstacles)
	out["bot_obstacles"] = hash(BotPilots.obstacles_near(t, Vector2(start.x, start.z), 110.0))
	out["place_plan"] = hash(PlaceData.for_terrain(t).house_plan)
	ar.free()
	wl.queue_free()
	air.free()
	pilot.free()
	t.free()
	await (Engine.get_main_loop() as SceneTree).process_frame
	return out


func test_same_start_key_and_world() -> void:
	var old := await _run(false)
	check(not is_nan(_pick.x), "нашлась точка старта в лесу")
	var now := await _run(true)
	print("FL-10 порядок: прежний %s ключ %s поверхность %s; новый %s ключ %s поверхность %s" % [
		old.start, old.key, old.surface, now.start, now.key, now.surface])
	check(old.start == now.start, "тот же старт: %s / %s" % [old.start, now.start])
	check(old.heading == now.heading, "тот же курс: %.2f / %.2f" % [old.heading, now.heading])
	check(old.surface != "" and old.surface == now.surface, "тот же снимок поверхности поля")
	check(not old.key_empty, "ключ кеша есть (данные места на диске)")
	check(old.key == now.key, "тот же ключ кеша поля: %s / %s" % [old.key, now.key])
	check(old.mask != 0 and old.mask == now.mask, "та же маска просек")
	check(old.objects.length() > 100 and old.objects == now.objects, "те же объекты (узлы, преобразования, экземпляры, препятствия): %s / %s" % [old.objects, now.objects])
	check(old.get("houses", -1) == now.get("houses", -2), "те же дома (позиции, размеры, высоты)")
	check(old.place_plan == now.place_plan, "тот же план домов")
	check(old.bot_obstacles == now.bot_obstacles, "те же препятствия у старта для ботов")
