extends TestCase
## Смена места (CR-17): узлы мира прошлого места держат Callable на PlaceData.height_at. PlaceData — RefCounted,
## Callable хранит лишь ObjectID: после сброса внешних ссылок узлы обязаны сами удерживать владельца,
## иначе _process зовёт освобождённый объект (в релизе — вылет). Ловец ошибок — ни одной за несколько кадров.


func _road(pts: Array) -> Dictionary:
	var p := PackedVector2Array()
	for q: Vector2 in pts:
		p.append(q)
	return {"t": "primary", "p": p}


func test_osm_traffic_keeps_place() -> void:
	var catcher := ErrorCatcher.new()
	OS.add_logger(catcher)
	var pd := PlaceData.new()
	var wr: WeakRef = weakref(pd)
	var cfg: Dictionary = Config.get_config("world_objects").duplicate(true)
	var t := OsmTraffic.make_for_test([_road([Vector2(0, 0), Vector2(300, 0)])], cfg, pd.height_at)
	t.auto = false
	var c: Variant = t.spawn_at(0, 0, 1, 50.0, 10.0, 15.0)
	check(c != null, "машина создана")
	pd = null  # как при смене места: внешних ссылок нет
	check(wr.get_ref() != null, "PlaceData жив, пока жив трафик")
	for i in 20:
		t.advance(0.05, Vector3.ZERO)
	t.free()
	check(wr.get_ref() == null, "после удаления узла PlaceData освобождён")
	OS.remove_logger(catcher)
	check(catcher.errors.is_empty(), "нет ошибок: %s" % [catcher.errors])


func test_city_trees_keeps_place() -> void:
	var catcher := ErrorCatcher.new()
	OS.add_logger(catcher)
	var pd := PlaceData.new()
	var wr: WeakRef = weakref(pd)
	var houses: Array = []
	for i in 6:
		houses.append([i * 30.0, 0.0, 8.0, 10.0, 0.0, 3.0, 1])
	var n: CityTrees = CityTrees.build_gardens(houses, Config.get_config("world_objects").duplicate(true), pd.height_at)
	check(n != null, "деревья города собраны")
	if n == null:
		OS.remove_logger(catcher)
		return
	var cam := Camera3D.new()
	n.camera = cam
	n.add_child(cam)
	(Engine.get_main_loop() as SceneTree).root.add_child.call_deferred(n)
	await (Engine.get_main_loop() as SceneTree).process_frame
	cam.position = Vector3(50, 100, 0)
	pd = null
	check(wr.get_ref() != null, "PlaceData жив, пока живы деревья")
	for i in 5:
		n._process(0.05)
	n.osm_wind(func(_p: Vector3) -> Vector3: return Vector3.ZERO, cam.global_position)
	n.queue_free()
	await (Engine.get_main_loop() as SceneTree).process_frame
	check(wr.get_ref() == null, "после удаления узла PlaceData освобождён")
	OS.remove_logger(catcher)
	check(catcher.errors.is_empty(), "нет ошибок: %s" % [catcher.errors])


func test_osm_layer_and_plan_keep_place() -> void:
	var pd := PlaceData.new()
	var wr: WeakRef = weakref(pd)
	var p := CityTreePlan.new()
	var wc: Dictionary = Config.get_config("world_objects")
	p.setup(wc.city_trees, [], [], [], [[0.0, 0.0, 8.0, 10.0, 0.0, 3.0, 1]], wc.roads, wc.city_ground, 200.0, pd.height_at, pd.height_at)
	pd = null
	check(wr.get_ref() != null, "план держит PlaceData")
	p = null
	check(wr.get_ref() == null, "план освобождён — PlaceData тоже")
	var pd2 := PlaceData.new()
	var wr2: WeakRef = weakref(pd2)
	var layer := OsmLayer.new()
	layer.start(OsmData.new(), wc, pd2.height_at, null, pd2.height_at, false)
	pd2 = null
	check(wr2.get_ref() != null, "слой OSM держит PlaceData")
	layer.free()
	check(wr2.get_ref() == null, "слой удалён — PlaceData освобождён")
