extends TestCase
## Логика активации SteamService (S1.2) на подставном синглтоне, без расширения GodotSteam.

const Fake := preload("res://tests/steam/fake_steam.gd")
const Service := preload("res://scripts/steam/steam_service.gd")


func _svc() -> Node:
	return Service.new()


func test_plain_build_is_inactive_no_feature() -> void:
	var s := _svc()
	var f := Fake.new()
	s.configure([], [], false, f)
	check(not s.is_active() and s.inactive_reason() == "no_feature", "без признака: " + s.inactive_reason())
	check(f.init_calls == 0, "Steam не трогали")
	check(s.api() == null and s.steam_id() == 0 and s.persona_name() == "" and s.language() == "", "пустые значения")
	check(s.app_id() == 480, "app_id из конфига и неактивным")
	s.free()
	f.free()


func test_steam_arg_without_extension() -> void:
	var s := _svc()
	s.configure(["--steam"], [], false, null)
	check(s.inactive_reason() == "no_extension", s.inactive_reason())
	s.free()


func test_no_steam_and_feature_disabled() -> void:
	var s := _svc()
	var f := Fake.new()
	s.configure(["--steam", "--no-steam"], [], true, f)
	check(s.inactive_reason() == "disabled" and f.init_calls == 0, "--no-steam сильнее: " + s.inactive_reason())
	s.free()
	f.free()


func test_feature_without_arg_activates() -> void:
	var s := _svc()
	var f := Fake.new()
	s.configure([], [], true, f)
	check(s.is_active() and s.inactive_reason() == "", "сборка Steam активна")
	check(f.init_app_id == 480, "app_id передан: %d" % f.init_app_id)
	check(s.persona_name() == "Steam Eagle" and s.language() == "russian" and s.steam_id() > 0, "значения")
	check(s.api() == f, "api()")
	s.free()
	f.free()


func test_init_failed_reason() -> void:
	var s := _svc()
	var f := Fake.new()
	f.init_status = 2
	s.configure(["--steam"], [], false, f)
	check(not s.is_active() and s.inactive_reason().begins_with("init_failed"), s.inactive_reason())
	check(s.api() == null and s.persona_name() == "", "неактивен после отказа")
	s.free()
	f.free()


func test_activated_signal_and_callbacks() -> void:
	var s := _svc()
	var f := Fake.new()
	var hits := [0]
	s.activated.connect(func(): hits[0] += 1)
	s.configure(["--steam"], [], false, f)
	check(hits[0] == 1, "activated один раз")
	s._process(0.016)
	s._process(0.016)
	check(f.callbacks == 2, "run_callbacks каждый кадр")
	s.free()
	f.free()


func test_connect_lobby_from_plain_args() -> void:
	var s := _svc()
	s.configure([], ["godot", "+connect_lobby", "109775241000000"], false, null)
	check(s.launch_lobby_id() == 109775241000000, "лобби из обычных аргументов")
	s.configure(["+connect_lobby", "5"], [], false, null)
	check(s.launch_lobby_id() == 0, "из пользовательских не берём")
	s.configure([], ["+connect_lobby"], false, null)
	check(s.launch_lobby_id() == 0, "без значения")
	s.configure([], ["+connect_lobby", "abc"], false, null)
	check(s.launch_lobby_id() == 0, "не число")
	s.free()


func test_pilot_name_default_from_steam() -> void:
	var f := Fake.new()
	f.persona = "Очень длинный ник пилота из Steam"
	SteamService.configure(["--steam"], [], false, f)
	var path := UserSettings.DEFAULT_DIR.path_join("game.json")
	var backup := FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""
	UserSettings.save_pilot_name("")
	Config.reload()
	check(UserSettings.pilot_name() == f.persona.substr(0, UserSettings.PILOT_NAME_MAX), "ник Steam обрезан: " + UserSettings.pilot_name())
	UserSettings.save_pilot_name("Свой")
	Config.reload()
	check(UserSettings.pilot_name() == "Свой", "своё имя главнее")
	check(String(Config.value("game", "net.pilot_name", "")) == "Свой", "ник не записан")
	UserSettings.save_pilot_name("")
	Config.reload()
	f.persona = "  "
	check(UserSettings.pilot_name() == String(TranslationServer.translate("net_pilot_name_default")), "пустой ник — умолчание")
	if backup == "":
		DirAccess.remove_absolute(path)
	else:
		var w := FileAccess.open(path, FileAccess.WRITE)
		w.store_string(backup)
		w.close()
	Config.reload()
	SteamService.configure([], [], false, null)
	f.free()
