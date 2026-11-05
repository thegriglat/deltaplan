extends Node
## SCP-К3 v3: настройки после выбора красивого места → Game ставит крыло в воздухе над точкой на agl_m
## по курсу места (ASM-К2). Рельеф — локальный, без сети: точка места подставляется на карту игры.

const MAIN_SCENE := preload("res://scenes/main.tscn")
const FIXTURE := "res://tests/ui/fixtures/scenic_places_test.json"

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_scenic_choice_to_air_start() -> void:
	var main: Node = MAIN_SCENE.instantiate()
	main.set("opts", LaunchOptions.parse(PackedStringArray(["--autostart", "--bots=0"])))
	add_child(main)
	for i in 900:
		if main.get("state") == 2:
			break
		await get_tree().process_frame
	var game: Game = main.get_node("Game")
	game.process_mode = Node.PROCESS_MODE_DISABLED
	var b := game.terrain.detail_bounds()
	var c := b.get_center()
	var ll := game.terrain.local_to_latlon(c.x, c.y)
	var host := Control.new()
	add_child(host)
	var row := PlacePickRow.new()
	row.settings = FlightSettings.defaults()
	host.add_child(row)
	row.build(host, "", true, FIXTURE)
	var place: Dictionary = (ScenicPlaces.load_catalog(FIXTURE).places[0] as Dictionary).duplicate()
	place.lat = ll.x
	place.lon = ll.y
	row.choose_scenic(place)
	var s := row.settings
	check(s.has_air_start() and s.vehicle == "glider", "настройки: старт в воздухе")
	game.settings = s
	game._choose_air_start()
	game._choose_start()
	check(game.air_start_m == 0.0 and game._exact_start, "в воздухе, точный старт принят")
	check(absf(angle_difference(deg_to_rad(float(game.get_start().heading_deg)), deg_to_rad(float(place.heading_deg)))) < deg_to_rad(0.5), "курс места")
	game.restart()
	var tel := game.glider.get_telemetry()
	var st := game.get_start()
	check(Vector2(tel.position.x - st.position.x, tel.position.z - st.position.z).length() < 1.0, "над точкой места")
	check(absf(tel.altitude_agl - float(place.agl_m)) < 1.0, "высота над рельефом %.1f / %.1f" % [tel.altitude_agl, place.agl_m])
	check(game.glider.phase() == "flying", "фаза flying: %s" % game.glider.phase())
	host.queue_free()
	main.queue_free()
	for i in 2:
		await get_tree().process_frame
