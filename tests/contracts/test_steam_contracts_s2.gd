extends Node
## Контракт S2 (поток событий полёта для ачивок, docs/contracts/steam.md): форма словарей
## flight_started / flight_sample / flight_finished на коротком полёте Game без вывода на экран.
## Ровно один flight_finished на полёт; выход в меню из полёта — без него.

const DT := 1.0 / 120.0
const MAIN_SCENE := preload("res://scenes/main.tscn")

const CTX_KEYS := {
	"place_key": TYPE_STRING,
	"wing": TYPE_STRING,
	"net": TYPE_BOOL,
	"launch_pos": TYPE_VECTOR3,
	"launch_alt_msl": TYPE_FLOAT,
	"wind_ms": TYPE_FLOAT,
	"wind_from_deg": TYPE_FLOAT,
	"lat": TYPE_FLOAT,
	"lon": TYPE_FLOAT,
	"temp_c": TYPE_FLOAT,
	"cb_chance": TYPE_FLOAT,
	"sky": TYPE_STRING,
}
const SAMPLE_KEYS := {
	"t": TYPE_FLOAT,
	"pos": TYPE_VECTOR3,
	"alt_msl": TYPE_FLOAT,
	"agl": TYPE_FLOAT,
	"vario": TYPE_FLOAT,
	"circling": TYPE_BOOL,
	"cloud_base_msl": TYPE_FLOAT,
	"sun_elev_deg": TYPE_FLOAT,
	"others_airborne": TYPE_INT,
	"eggs": TYPE_DICTIONARY,
	"near_climbing_live": TYPE_INT,
}
const FIN_KEYS := {
	"kind": TYPE_STRING,
	"land_pos": TYPE_VECTOR3,
	"land_alt_msl": TYPE_FLOAT,
	"others_total": TYPE_INT,
	"others_airborne": TYPE_INT,
	"live_peers": TYPE_INT,
	"grade": TYPE_STRING,
	"vertical_speed_ms": TYPE_FLOAT,
	"flight_time_s": TYPE_FLOAT,
	"distance_m": TYPE_FLOAT,
	"finish_reason": TYPE_STRING,
}

var failures: PackedStringArray = []
var events: Array = []  # [имя, словарь] в порядке прихода


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _shape(d: Dictionary, spec: Dictionary, label: String) -> void:
	for k: String in spec:
		check(d.has(k), "%s: нет ключа %s" % [label, k])
		if d.has(k):
			check(typeof(d[k]) == int(spec[k]), "%s.%s: тип %d, нужен %d" % [label, k, typeof(d[k]), spec[k]])


func _count(name: String) -> int:
	var n := 0
	for e in events:
		if e[0] == name:
			n += 1
	return n


func _fly(game: Game, seconds: float) -> void:
	for i in int(seconds / DT):
		game.tick(DT)


func test_s2_flight_feed() -> void:
	var main: Node = MAIN_SCENE.instantiate()
	(main as Node).set("opts", LaunchOptions.parse(PackedStringArray(["--autostart"])))
	add_child(main)
	var game: Game = main.get_node("Game")
	for i in 600:
		if main.get("state") == 2:
			break
		await get_tree().process_frame
	check(main.get("state") == 2, "автостарт — в полёте")
	game.process_mode = Node.PROCESS_MODE_DISABLED
	var feed := game.feed
	check(feed != null, "у Game есть feed")
	feed.flight_started.connect(func(d: Dictionary) -> void: events.append(["started", d]))
	feed.flight_sample.connect(func(d: Dictionary) -> void: events.append(["sample", d]))
	feed.flight_finished.connect(func(d: Dictionary) -> void: events.append(["finished", d]))

	# Полёт 1: в воздухе 12 с, выход в меню — без flight_finished.
	var st := game.get_start()
	var p: Vector3 = st.position
	p.y = game.terrain.height_at(p.x, p.z) + 150.0
	game.glider.reset_in_air(p, float(st.heading_deg))
	_fly(game, 12.0)
	check(_count("started") == 1, "один flight_started")
	check(events.size() > 0 and events[0][0] == "started", "flight_started раньше samples")
	var samples := _count("sample")
	check(samples >= 10 and samples <= 13, "1 Гц: %d выборок за 12 с" % samples)
	if _count("started") > 0:
		_shape(events[0][1], CTX_KEYS, "ctx")
		var ctx: Dictionary = events[0][1]
		check(String(ctx.place_key).contains("/"), "place_key '%s'" % ctx.place_key)
		check(not bool(ctx.net), "не сеть")
		check(not is_nan(float(ctx.lat)) and absf(float(ctx.lat)) <= 90.0, "lat %s" % ctx.lat)
		check(not is_nan(float(ctx.temp_c)), "temp_c известна")
		check(ctx.sky in ["clear", "partly", "overcast", ""], "sky '%s'" % ctx.sky)
	for e in events:
		if e[0] == "sample":
			_shape(e[1], SAMPLE_KEYS, "sample")
			check(float(e[1].near_climbing_live) == 0.0, "не сеть — near_climbing_live 0")
	if samples > 1:
		check(float(events[2][1].t) > float(events[1][1].t), "t растёт")
	game.set_flying(false)
	check(not feed.active, "выход в меню гасит поток")
	_fly(game, 1.0)
	check(_count("finished") == 0, "выход в меню — без flight_finished")
	game.set_flying(true)

	# Полёт 2: низко носом в гору — посадка, ровно один flight_finished.
	events.clear()
	game.restart()
	p.y = game.terrain.height_at(p.x, p.z) + 3.0
	game.glider.reset_in_air(p, float(st.heading_deg) + 180.0)
	var ended: Array = []
	game.flight_ended.connect(func(k: String, _i: Dictionary) -> void: ended.append(k))
	for i in 120 * 20:
		game.tick(DT)
		if not ended.is_empty():
			break
	_fly(game, 2.0)
	check(ended.size() == 1, "flight_ended один раз: %s" % [ended])
	check(_count("started") == 1, "второй полёт: один flight_started")
	check(_count("finished") == 1, "ровно один flight_finished (%d)" % _count("finished"))
	game.stats.armed = true
	game._emit_end("landed", {})
	check(_count("finished") == 1, "повторный итог не дублируется")
	for e in events:
		if e[0] == "finished":
			_shape(e[1], FIN_KEYS, "fin")
			check(String(e[1].kind) == "landed", "kind landed")
			check(int(e[1].live_peers) == 0, "не сеть — live_peers 0")
	main.queue_free()
	get_tree().paused = false
	await get_tree().process_frame


func test_s2_place_key() -> void:
	var s := FlightSettings.new()
	s.location_id = "altai"
	s.site_id = "x"
	check(AchievementFeed.place_key(s) == "altai/x", "место со склона")
	s.pick_lat = 50.12345
	s.pick_lon = 8.5
	check(AchievementFeed.place_key(s) == "pick/50.123,8.500", "точка с карты: %s" % AchievementFeed.place_key(s))
