extends Node
## TM-3: кадры шлюза режимов тренировки (PNG 1920x1080). Игру не меняет.
## Нужно окно (не headless), профиль — своей копии:
##   XDG_DATA_HOME=~/.cache/dp-xdg/$(basename "$PWD") godot --path . --audio-driver Dummy \
##     --resolution 1920x1080 res://tools/shots/training_modes_shot.tscn -- --stage=<стадия> --out=<каталог>
## Стадии: window — окно «Тренировка»; goals — вкладка «Цели» окна «Полёт…» (Онгудай), загружено
##   tools/shots/training_modes.xctsk, кнопка «Загрузить задание…» и задание выбрано;
##   flight — полёт по карточке «ridge» (склон), список цели в углу.
## Пишет <out>/<стадия>.png.

const MAIN_SCENE := preload("res://scenes/main.tscn")
const TIMEOUT_S := 300.0
const XCTSK := "res://tools/shots/training_modes.xctsk"
const CARD_ID := "ridge"

var _stage := ""
var _out := ""
var _main: Node = null


## Настройки полёта карточки тренировки: как после клика по ней в окне «Тренировка».
class CardOpts:
	extends LaunchOptions
	var card: Dictionary = {}

	func apply_to(s: FlightSettings) -> FlightSettings:
		return TrainingMenu.settings_for(card, super.apply_to(s))


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--stage="):
			_stage = a.substr(8)
		elif a.begins_with("--out="):
			_out = a.substr(6)
	if _stage == "" or _out == "":
		push_error("training_modes_shot: нужны --stage= и --out=")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	get_tree().create_timer(TIMEOUT_S, true, false, true).timeout.connect(_fail.bind("таймаут"))
	_run()


func _fail(why: String) -> void:
	print("training_modes_shot: FAIL (%s)" % why)
	await _quit(1)


func _quit(code: int) -> void:
	if is_instance_valid(_main):
		_main.queue_free()
	for i in 2:
		await get_tree().process_frame
	get_tree().quit(code)


func _snap(name: String) -> void:
	for i in 8:
		await RenderingServer.frame_post_draw
	var path := _out.path_join(name + ".png")
	var img := get_viewport().get_texture().get_image()
	print("training_modes_shot: %s (%s)" % [path, error_string(img.save_png(path))])


func _card(id: String) -> Dictionary:
	for g: Dictionary in TrainingMenu.load_cards().get("groups", []):
		for c: Dictionary in g.get("cards", []):
			if String(c.id) == id:
				return c
	return {}


func _run() -> void:
	Language.select("ru")
	match _stage:
		"window":
			await _stage_window()
		"goals":
			await _stage_goals()
		"flight":
			await _stage_flight()
		_:
			await _fail("неизвестная стадия " + _stage)
			return
	print("training_modes_shot: OK %s" % _stage)
	await _quit(0)


func _stage_window() -> void:
	var m: StartMenu = (load("res://scenes/ui/start_menu.tscn") as PackedScene).instantiate()
	m.favorites_path = "user://training_modes_shot_fav.json"
	add_child(m)
	_main = m
	await get_tree().process_frame
	for b in m.find_children("*", "Button", true, false):
		if (b as Button).text == tr("menu_training"):
			(b as Button).pressed.emit()
	for i in 20:
		await get_tree().process_frame
	await _snap("window")


func _stage_goals() -> void:
	var o := LaunchOptions.new()
	o.overrides = {"location": "ongudai", "site": "kayancha_south"}
	_main = MAIN_SCENE.instantiate()
	_main.set("opts", o)
	add_child(_main)
	for i in 30:
		await get_tree().process_frame
	_main.set("flight", o.apply_to(FlightSettings.defaults()))
	_main.call("_open_flight_setup")
	var screen: FlightSetupScreen = _main.get_node("UI/FlightSetupScreen")
	var tabs: TabContainer = screen.get("_tabs")
	for i in tabs.get_tab_count():
		if tabs.get_tab_title(i) == TranslationServer.translate("setup_tab_goals"):
			tabs.current_tab = i
	for i in 30:
		await get_tree().process_frame
	var tab := _find_goals_tab(screen)
	if tab == null:
		await _fail("нет GoalsTab")
		return
	var dest: String = tab.import_task_file(ProjectSettings.globalize_path(XCTSK))
	print("training_modes_shot: копия задания %s" % dest)
	if dest == "":
		await _fail("задание не загрузилось")
		return
	for i in 5:
		await get_tree().process_frame
	# Прокрутить к кнопке «Загрузить задание…», чтобы она и выбранное задание были в кадре.
	var sc: ScrollContainer = null
	var n: Node = tab
	while n != null and not (n is ScrollContainer):
		n = n.get_parent()
	sc = n as ScrollContainer
	for b in tab.find_children("*", "Button", true, false):
		if (b as Button).text == tr("goals_task_load") and sc != null:
			sc.ensure_control_visible(b)
			sc.scroll_vertical = maxi(sc.scroll_vertical + 120, 0)
	for i in 20:
		await get_tree().process_frame
	await _snap("goals")


func _find_goals_tab(n: Node) -> GoalsTab:
	if n is GoalsTab:
		return n
	for ch in n.get_children():
		var r := _find_goals_tab(ch)
		if r != null:
			return r
	return null


func _stage_flight() -> void:
	var card := _card(CARD_ID)
	if card.is_empty():
		await _fail("нет карточки " + CARD_ID)
		return
	card["location"] = String(card.get("location", "training_island"))
	var o := CardOpts.new()
	o.card = card
	o.autostart = true
	o.bots = 0
	o.seed = 4711
	o.air_start_m = 0.0
	o.air_start_agl_m = 150.0
	_main = MAIN_SCENE.instantiate()
	_main.set("opts", o)
	add_child(_main)
	for i in 6000:
		if int(_main.get("state")) == 2:  # State.FLYING
			break
		await get_tree().process_frame
	if int(_main.get("state")) != 2:
		await _fail("не долетели до FLYING")
		return
	var g: Game = _main.get_node("Game")
	if g.goals == null:
		await _fail("цель не создана")
		return
	for i in 120:
		await get_tree().process_frame
	await _snap("flight")
