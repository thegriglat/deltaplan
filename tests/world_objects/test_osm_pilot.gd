extends TestCase
## OsmPilot (OT-10): подписи вершин и перевалов общим помощником NameTag («<имя> <ele> м», без имени —
## нет подписи), вид подписи бота не изменился, ЛЭП (PowerLinePlanner, провода, препятствия),
## мачты/башни/ветряки, канатки, аэродромы. На фикстуре (Бохинь — Блед, 3x3) число подписей =
## числу вершин и перевалов с именем.

const FIX := "res://tests/fixtures/osm_tiles"


func _flat(_x: float, _z: float) -> float:
	return 500.0


func _root() -> Node:
	var tree_root := (Engine.get_main_loop() as SceneTree).root
	return tree_root.get_child(tree_root.get_child_count() - 1)


func test_peak_text() -> void:
	check(NameTag.peak_text("Триглав", 2864.0) == "Триглав 2864 м", "имя и высота")
	check(NameTag.peak_text("", 2864.0) == "", "без имени подписи нет")
	check(NameTag.peak_text("Мост", NAN) == "Мост", "без высоты — одно имя")
	check(NameTag.peak_text("Х", 1234.6) == "Х 1235 м", "округление")


func test_bot_tag_look_unchanged() -> void:
	var root := _root()
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.make_current()
	var a := BotAgent.new()
	a.pilot_name = "Саша"
	a.state = BotAgent.State.FLY
	var g := BotGlider.new()
	g.agent = a
	root.add_child(g)
	g.position = Vector3(0, 0, -100)
	g.call("_build_name_tag")
	var nc: Dictionary = Config.get_config("bots").get("names", {}).duplicate()
	nc.show = true
	g.set_name_config(nc)
	g.call("_update_name_tag", cam, 100.0, true)
	var t: Label3D = g.name_tag
	check(t.top_level and t.billboard == BaseMaterial3D.BILLBOARD_ENABLED and t.fixed_size, "billboard, постоянный размер")
	check(t.alpha_cut == Label3D.ALPHA_CUT_DISCARD and not t.no_depth_test and not t.shaded and t.double_sided, "отсечка по альфе, глубина")
	check(t.font_size == 48 and t.vertical_alignment == VERTICAL_ALIGNMENT_BOTTOM, "кегль и привязка")
	approx(t.pixel_size, float(nc.font_px) / 1080.0 * 2.0 * tan(deg_to_rad(cam.fov) * 0.5) / 48.0, 1e-7, "pixel_size")
	var k := float(nc.alpha) * NameTag.fade(100.0, float(nc.fade_start_m), float(nc.fade_end_m))
	approx(t.modulate.a, k, 1e-6, "прозрачность")
	approx(t.outline_modulate.a, 0.8 * k, 1e-6, "прозрачность обводки")
	check(t.outline_size == int(nc.outline_px), "обводка")
	var up: float = g._hang_h + float(nc.height_m)
	approx(t.global_position.y, g.global_position.y + up, 1e-4, "высота над ботом")
	g.queue_free()
	cam.queue_free()


func test_synthetic_layer() -> void:
	var d := OsmData.new()
	d.peaks = [
		{"x": 1000.0, "z": 0.0, "ele": 2000.0, "name": "Альфа"},
		{"x": 2000.0, "z": 0.0, "ele": NAN, "name": "Бета"},
		{"x": 3000.0, "z": 0.0, "ele": 1500.0, "name": ""},
	]
	d.passes = [{"x": 0.0, "z": 1000.0, "ele": 1200.0, "name": "Седло"}]
	d.power = [
		{"minor": false, "p": PackedVector2Array([Vector2(0, 0), Vector2(300, 0), Vector2(600, 100)])},
		{"minor": true, "p": PackedVector2Array([Vector2(0, 500), Vector2(100, 500)])},
	]
	d.verticals = [
		{"t": "wind", "comm": false, "x": 500.0, "z": 500.0, "h": 90.0},
		{"t": "chimney", "comm": false, "x": 600.0, "z": 500.0, "h": 0.0},
		{"t": "mast", "comm": true, "x": 700.0, "z": 500.0, "h": 40.0},
	]
	d.aerialways = [{"t": "gondola", "p": PackedVector2Array([Vector2(0, 0), Vector2(0, 400)])},
		{"t": "t-bar", "p": PackedVector2Array([Vector2(50, 0), Vector2(50, 200)])}]
	d.aeroways = [
		{"t": "runway", "kind": "line", "p": PackedVector2Array([Vector2(0, 2000), Vector2(900, 2000)])},
		{"t": "aerodrome", "kind": "area", "p": PackedVector2Array([Vector2(0, 0), Vector2(100, 0), Vector2(100, 100)])},
		{"t": "helipad", "kind": "point", "p": PackedVector2Array([Vector2(300, 2100)])},
	]
	var obs := ObstacleIndex.new()
	var cfg := WorldObjects.load_config()
	var node := OsmPilot.build(d, cfg, _flat, obs)
	check(node != null, "слой создан")
	var st := OsmPilot.stats
	check(int(st.peak_labels) == 2 and int(st.pass_labels) == 1, "подписи: 2 вершины и перевал: %s" % [st])
	check(int(st.supports) >= 4 and int(st.wires) >= 8, "ЛЭП: опоры и провода: %s" % [st])
	check(int(st.verticals) == 3 and int(st.aerialway_poles) >= 4 and int(st.aeroway_strips) == 2 and int(st.aeroway_points) == 1, "остальное: %s" % [st])
	# ветряк — препятствие
	var tower_hit := obs.hit(Vector3(500.0, 510.0, 480.0), Vector3(500.0, 510.0, 520.0))
	check(not tower_hit.is_empty(), "ветряк — препятствие")
	# подписи
	var root := _root()
	var cam := Camera3D.new()
	root.add_child(cam)
	root.add_child(node)
	cam.make_current()
	cam.global_position = Vector3(0, 600, 0)
	var labels := node.get_node("PeakLabels")
	check(labels.get_child_count() == 3, "три Label3D")
	var shown: int = labels.refresh(cam)
	check(shown == 3, "вблизи видны все: %d" % shown)
	var texts := []
	for c in labels.get_children():
		texts.append((c as Label3D).text)
	check("Альфа 2000 м" in texts and "Бета" in texts and "Седло 1200 м" in texts, "тексты: %s" % [texts])
	cam.global_position = Vector3(0, 600, 1.0e6)
	check(labels.refresh(cam) == 0, "далеко — не видны")
	cam.global_position = Vector3(0, 600, 0)
	labels.show_labels = false
	check(labels.refresh(cam) == 0, "флаг выключен — подписи скрыты")
	labels.show_labels = true
	check(labels.refresh(cam) == 3, "флаг включён — видны")
	node.queue_free()
	cam.queue_free()


func test_fixture_peaks_equal_labels() -> void:
	var fx: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(FIX + "/fixture.json"))
	var base := ProjectSettings.globalize_path(FIX)
	OsmTilesStage.cache_root_override = "user://test_osm_pilot/v1"
	LocationCache.remove_dir("user://test_osm_pilot")
	var ctx := LocationBuildContext.new()
	ctx.center_lat = float(fx.center_lat)
	ctx.center_lon = float(fx.center_lon)
	ctx.host = _root()
	ctx.dir = "user://test_osm_pilot/place"
	DirAccess.make_dir_recursive_absolute(ctx.dir)
	var stage := OsmTilesStage.new()
	stage.cfg_override = {"base_url": base}
	var err: int = await stage.run(ctx)
	check(err == OK, "стадия OK (%d)" % err)
	var d := OsmData.load_for(ctx.dir, ctx.center_lat, ctx.center_lon, 20000.0)
	OsmTilesStage.cache_root_override = ""
	var named_peaks := 0
	var named_passes := 0
	for p: Dictionary in d.peaks:
		named_peaks += 1 if String(p.name) != "" else 0
	for p: Dictionary in d.passes:
		named_passes += 1 if String(p.name) != "" else 0
	var obs := ObstacleIndex.new()
	var t0 := Time.get_ticks_usec()
	var node := OsmPilot.build(d, WorldObjects.load_config(), _flat, obs)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	var st := OsmPilot.stats
	print("OT-10 фикстура: вершин %d (с именем %d), перевалов %d (с именем %d); подписей %d+%d; ЛЭП линий %d, опор %d, проводов %d; вертикалей %d; канаток %d (опор %d); аэро %d+%d; препятствий %d; сборка %.0f мс" % [
		d.peaks.size(), named_peaks, d.passes.size(), named_passes, int(st.get("peak_labels", 0)),
		int(st.get("pass_labels", 0)), d.power.size(), int(st.get("supports", 0)), int(st.get("wires", 0)),
		int(st.get("verticals", 0)), d.aerialways.size(), int(st.get("aerialway_poles", 0)),
		int(st.get("aeroway_strips", 0)), int(st.get("aeroway_points", 0)), obs.size(), ms])
	check(named_peaks > 0, "на фикстуре есть вершины с именем")
	check(int(st.get("peak_labels", 0)) == named_peaks, "подписей вершин = вершинам с именем")
	check(int(st.get("pass_labels", 0)) == named_passes, "подписей перевалов = перевалам с именем")
	if node != null:
		node.free()
	LocationCache.remove_dir("user://test_osm_pilot")
