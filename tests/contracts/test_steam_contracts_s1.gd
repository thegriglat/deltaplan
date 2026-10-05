extends TestCase
## Форма стыков S1 (docs/contracts/steam.md): интерфейс SteamService, конфиг, автозагрузка.

const API := ["is_active", "inactive_reason", "api", "app_id", "steam_id", "persona_name", "language", "launch_lobby_id"]


func test_s1_service_interface() -> void:
	var script: Script = load("res://scripts/steam/steam_service.gd")
	check(script != null, "скрипт разбирается без расширения")
	var names: PackedStringArray = []
	for m in script.get_script_method_list():
		names.append(String(m.name))
	for n in API:
		check(names.has(n), "метод " + n)
	var sigs: PackedStringArray = []
	for sg in script.get_script_signal_list():
		sigs.append(String(sg.name))
	check(sigs.has("activated"), "сигнал activated")


func test_s1_inactive_defaults() -> void:
	check(not SteamService.is_active(), "в тестах Steam неактивен")
	check(SteamService.api() == null and SteamService.steam_id() == 0, "api/steam_id пусты")
	check(SteamService.persona_name() == "" and SteamService.language() == "", "ник/язык пусты")
	check(SteamService.launch_lobby_id() == 0, "лобби 0")
	check(["no_feature", "disabled", "no_extension"].has(SteamService.inactive_reason()), SteamService.inactive_reason())


func test_s1_config() -> void:
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://configs/steam.json"))
	check(data is Dictionary, "configs/steam.json")
	check(data.get("enabled") is bool and int(data.get("app_id", 0)) > 0, "enabled и app_id")
	check(SteamService.app_id() == int(data.get("app_id", -1)), "app_id() из конфига")


func test_s1_autoload_after_config() -> void:
	var text := FileAccess.get_file_as_string("res://project.godot")
	var c := text.find("Config=\"*res://scripts/core/config.gd\"")
	var s := text.find("SteamService=\"*res://scripts/steam/steam_service.gd\"")
	check(c >= 0 and s > c, "SteamService зарегистрирован после Config")
