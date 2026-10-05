extends TestCase
## Форма стыков S3 (docs/contracts/steam.md): Activity, SteamPresence, автозагрузка.


func test_s3_activity_interface() -> void:
	var script: Script = load("res://scripts/core/activity.gd")
	var names: PackedStringArray = []
	for m in script.get_script_method_list():
		names.append(String(m.name))
	check(names.has("set_state") and names.has("state"), "set_state/state")
	var sigs: PackedStringArray = []
	for sg in script.get_script_signal_list():
		sigs.append(String(sg.name))
	check(sigs.has("changed"), "сигнал changed")
	for k in ["mode", "place", "net", "zone_code", "peers", "alt_msl"]:
		check(Activity.state().has(k), "ключ " + k)


func test_s3_presence_interface() -> void:
	var script: Script = load("res://scripts/steam/steam_presence.gd")
	var names: PackedStringArray = []
	for m in script.get_script_method_list():
		names.append(String(m.name))
	check(names.has("set_lobby"), "set_lobby(lobby_id)")
	check(SteamPresence.has_method("set_lobby"), "автозагрузка SteamPresence")


func test_s3_autoloads() -> void:
	var text := FileAccess.get_file_as_string("res://project.godot")
	check(text.contains("Activity=\"*res://scripts/core/activity.gd\""), "Activity")
	check(text.contains("SteamPresence=\"*res://scripts/steam/steam_presence.gd\""), "SteamPresence")
