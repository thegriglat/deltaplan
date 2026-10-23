extends Node
## Контракт TA-К2 (docs/contracts/trike-anywhere.md): дельталёт и буксировка в любом месте без проверки рельефа.
## Только что старт собирается и не падает; лётных проверок нет.

const DOC := "res://docs/contracts/trike-anywhere.md"
const VERSION := 1
const MAIN_SCENE := preload("res://scenes/main.tscn")
const DT := 1.0 / 120.0

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_doc_heading() -> void:
	var text := FileAccess.get_file_as_string(DOC)
	if text.is_empty():
		text = FileAccess.get_file_as_string(ProjectSettings.globalize_path(DOC))
	check(not text.is_empty(), "контракт читается")
	var re := RegEx.create_from_string("(?m)^## (TA-К\\d) v(\\d+)\\.")
	var found := {}
	for m in re.search_all(text):
		found[m.get_string(1)] = int(m.get_string(2))
	check(found.get("TA-К2", 0) == VERSION, "TA-К2 (v%d) в заголовках: %s" % [VERSION, found])


func _site_heading(loc: String, id: String) -> float:
	for st: Dictionary in Locations.config(loc).get("start_sites", []):
		if String(st.get("id", "")) == id:
			return float(st.heading_deg)
	return NAN


func _start(args: Array) -> Node:
	var main: Node = MAIN_SCENE.instantiate()
	main.set("opts", LaunchOptions.parse(PackedStringArray(["--autostart"] + args)))
	add_child(main)
	for i in 6000:
		if main.get("state") == 2:
			break
		await get_tree().process_frame
	return main


func _trike_case(loc: String, site: String) -> void:
	var tag := "%s/%s: " % [loc, site]
	var main: Node = await _start(["--location=" + loc, "--site=" + site, "--vehicle=trike"])
	var game: Game = main.get_node("Game")
	check(main.get("state") == 2, tag + "в полёте (state %s)" % main.get("state"))
	game.process_mode = Node.PROCESS_MODE_DISABLED
	check(game.glider.is_trike(), tag + "Glider - дельталёт")
	check(game.glider.phase() == "wheels", tag + "на колёсах: %s" % game.glider.phase())
	check(game.input_controller.vehicle == "trike", tag + "input_controller.vehicle")
	check(game.tow_session == null, tag + "TowSession нет")
	check(game.glider.engine.state == "off", tag + "двигатель заглушен")
	var st := game.get_start()
	check(game.glider.model.position.distance_to(st.position) <= 3.0, tag + "у площадки: %s против %s" % [game.glider.model.position, st.position])
	check(absf(angle_difference(deg_to_rad(float(st.heading_deg)), deg_to_rad(_site_heading(loc, site)))) < deg_to_rad(1.0), tag + "курс площадки: %s" % st.heading_deg)
	game.restart()
	check(game.glider.phase() == "wheels" and game.glider.model.position.distance_to(st.position) <= 3.0, tag + "«Ещё раз» - снова на колёсах")
	main.queue_free()


func test_trike_altai() -> void:
	await _trike_case("altai", "sinyukha_west")


func test_trike_aushkul() -> void:
	await _trike_case("aushkul", "aushtau_east")


func _tow_case(kind: String) -> void:
	var tag := kind + ": "
	var main: Node = await _start(["--location=altai", "--site=sinyukha_west", "--tow=" + kind])
	var game: Game = main.get_node("Game")
	check(main.get("state") == 2, tag + "в полёте (state %s)" % main.get("state"))
	game.process_mode = Node.PROCESS_MODE_DISABLED
	check(game.tow_session != null, tag + "TowSession есть")
	var st := game.get_start()
	check(game.glider.model.position.distance_to(st.position) <= 3.0, tag + "у площадки: %s против %s" % [game.glider.model.position, st.position])
	for i in 240:
		game.tick(DT)
	var p: Vector3 = game.glider.model.position
	check(is_finite(p.x) and is_finite(p.y) and is_finite(p.z), tag + "положение без NaN: %s" % p)
	main.queue_free()


func test_tow_winch() -> void:
	await _tow_case("winch_static")


func test_tow_aerotow() -> void:
	await _tow_case("aerotow")
