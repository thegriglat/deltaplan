extends TestCase
## Контракт S7: Steam Auto-Cloud — машинные настройки отдельно, описание для кабинета.

const CLOUD := "res://steam/partner/auto_cloud.json"
## Пути, которые игра пишет в user:// (кроме кэшей и local/), — как их видит Auto-Cloud.
const WRITTEN := [
	"configs/game.json", "configs/audio.json", "configs/controls.json",
	"recent_places.json", "records.json", "achievements.json", "last_flight.json",
	"tasks/my.xctsk",
]
## Не должны попадать в облако.
const EXCLUDED := [
	"terrain_cache/a.png", "map_cache/a.png",
	"local/configs/game.json", "atmo_fingerprint.txt",
]


func _cloud() -> Dictionary:
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(CLOUD))
	return d if d is Dictionary else {}


func _covered(rel: String, patterns: Array) -> bool:
	for p: Dictionary in patterns:
		var dir := String(p["path"])
		var base := rel.get_file()
		var rdir := rel.get_base_dir()
		var in_dir := rdir == dir or (bool(p["recursive"]) and dir != "" and rdir.begins_with(dir + "/"))
		if in_dir and base.match(String(p["pattern"])):
			return true
	return false


func test_cloud_json_shape() -> void:
	var d := _cloud()
	check(d.get("root_subdir") == "Deltaplan", "root_subdir")
	var roots: Dictionary = d.get("roots", {})
	check(roots.size() == 3 and roots.has("windows") and roots.has("linux") and roots.has("macos"), "три корня")
	check(int(d.get("quota_files", 0)) > 0 and int(d.get("quota_bytes", 0)) > 0, "квоты")
	check((d.get("local_keys", []) as Array).size() > 0, "local_keys не пусты")


func test_patterns_cover_written_paths() -> void:
	var pats: Array = _cloud().get("patterns", [])
	for rel: String in WRITTEN:
		check(_covered(rel, pats), "покрыт: " + rel)
	for rel: String in EXCLUDED:
		check(not _covered(rel, pats), "не в облаке: " + rel)


func test_local_keys_match_code() -> void:
	var keys: Array = _cloud().get("local_keys", [])
	var code := Array(UserSettings.LOCAL_KEYS)
	keys.sort()
	code.sort()
	check(keys == code, "local_keys == UserSettings.LOCAL_KEYS")


func test_save_patch_splits_local_keys() -> void:
	var root := OS.get_user_data_dir().path_join("st9_test_%d" % Time.get_ticks_usec())
	var dir := root.path_join("configs")
	var ok := UserSettings.save_patch("game", {
		"language": "ru", "graphics": "low", "render_scale_pct": 80.0,
		"net": {"pilot_name": "Ivan"}}, dir)
	check(ok, "записано")
	var cloud := UserSettings.read_json(dir.path_join("game.json"))
	var local := UserSettings.read_json(root.path_join("local/configs/game.json"))
	check(cloud.get("language") == "ru" and cloud.get("net", {}).get("pilot_name") == "Ivan", "общее в configs")
	check(not cloud.has("graphics") and not cloud.has("render_scale_pct"), "машинные не в configs")
	check(local.get("graphics") == "low" and local.get("render_scale_pct") == 80.0, "машинные в local")
	check(not local.has("language"), "общее не в local")
	# вложенный: облака машинные, остальное общее
	UserSettings.save_patch("atmosphere", {"clouds": {"max_clouds": 90}, "air_model": {"engine": "nn"}}, dir)
	UserSettings.save_patch("world", {"trees": {"radius_m": 250}, "time": {"speed": 2.0}}, dir)
	var w := UserSettings.read_json(dir.path_join("world.json"))
	check(w.has("time") and not w.has("trees"), "world: time общее, trees машинное")
	check(not FileAccess.file_exists(dir.path_join("atmosphere.json")), "atmosphere целиком машинный")
	for k in UserSettings.LOCAL_KEYS:
		var parts := (k as String).split(".")
		var c := UserSettings.read_json(dir.path_join(parts[0] + ".json"))
		var node: Variant = c
		for i in range(1, parts.size()):
			node = node.get(parts[i]) if node is Dictionary else null
		check(node == null, "в configs нет " + k)
	for f in ["game", "atmosphere", "world"]:
		DirAccess.remove_absolute(dir.path_join(f + ".json"))
		DirAccess.remove_absolute(root.path_join("local/configs/" + f + ".json"))


func test_config_search_dirs_overlay_order() -> void:
	var d := Config.search_dirs()
	check(d[0] == "res://configs", "res первый")
	check(d[d.size() - 2] == "user://configs" and d[d.size() - 1] == "user://local/configs", "local последний")


func test_user_dir_name() -> void:
	check(OS.get_user_data_dir().ends_with("/Deltaplan") or OS.get_user_data_dir().ends_with("\\Deltaplan"),
		"user:// кончается на Deltaplan: " + OS.get_user_data_dir())
