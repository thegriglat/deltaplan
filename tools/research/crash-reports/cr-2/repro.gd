extends Node
## CR-2: повторная загрузка места в одной сессии (меню → «Лететь» → меню → …), как в отчётах #11–#15.
## Запуск: run.sh. Параметры: --loc=<id> --cycles=N --fly=<с игровых> --wind=<км/ч> --skip-fly (без полёта между загрузками)
const MAIN_SCENE := preload("res://scenes/main.tscn")


func _arg(name: String, def: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % name):
			return a.substr(name.length() + 3)
	return def


func _ready() -> void:
	var loc := _arg("loc", "askarovo")
	var cycles := int(_arg("cycles", "6"))
	var fly_s := float(_arg("fly", "20"))
	var wind := float(_arg("wind", "18"))
	var main: Node = MAIN_SCENE.instantiate()
	add_child(main)
	var game: Game = main.get_node("Game")
	await main.call("load_menu_world")
	for i in cycles:
		var s := FlightSettings.new()
		s.location_id = loc
		s.wing = "wings/sport"
		s.wind_speed_kmh = wind
		s.wind_into_launch = true
		var t0 := Time.get_ticks_msec()
		print("CR2 cycle %d: start" % i)
		await main.call("_fly", s)
		print("CR2 cycle %d: loaded in %.1f s state=%d" % [i, (Time.get_ticks_msec() - t0) / 1000.0, int(main.get("state"))])
		var t := 0.0
		while t < fly_s:
			await get_tree().process_frame
			game.tick(1.0 / 60.0)
			t += 1.0 / 60.0
		main.call("_show_menu")
		await get_tree().create_timer(1.0).timeout
	print("CR2 done: %d cycles without crash" % cycles)
	get_tree().quit(0)
