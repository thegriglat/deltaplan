extends TestCase
## Форма стыка S6 (docs/contracts/steam.md): конфиг ачивок, автозагрузка, файл для кабинета.


func _defs() -> Array:
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://configs/achievements.json"))
	check(data is Dictionary and data.get("version") == 1.0, "version 1")
	return data.get("achievements", []) if data is Dictionary else []


func test_s6_config_shape() -> void:
	var re := RegEx.create_from_string("^ACH_[A-Z0-9_]+$")
	var seen := {}
	var defs := _defs()
	check(defs.size() == 37, "37 ачивок: %d" % defs.size())
	for d: Dictionary in defs:
		check(re.search(d.api) != null and not seen.has(d.api), "api " + d.api)
		seen[d.api] = true
		for k in ["name", "desc"]:
			check(String(d[k].get("ru", "")) != "" and String(d[k].get("en", "")) != "", "%s.%s ru/en" % [d.api, k])
		check(d.hidden is bool and d.rule is Dictionary and d.rule.has("type"), "hidden/rule " + d.api)


func test_s6_rule_types_known() -> void:
	var src := FileAccess.get_file_as_string("res://scripts/steam/achievement_rules.gd")
	for d: Dictionary in _defs():
		check(src.contains("\"%s\"" % d.rule.type), "тип правила %s (%s)" % [d.rule.type, d.api])


func test_s6_autoload_after_steam_service() -> void:
	var text := FileAccess.get_file_as_string("res://project.godot")
	var s := text.find("SteamService=\"*res://scripts/steam/steam_service.gd\"")
	var a := text.find("Achievements=\"*res://scripts/steam/achievements.gd\"")
	check(s >= 0 and a > s, "Achievements после SteamService")


func test_s6_autoload_interface() -> void:
	for m in ["on_flight_started", "on_flight_sample", "on_flight_finished", "is_unlocked", "sync_steam"]:
		check(Achievements.has_method(m), "метод " + m)
	check(Achievements.has_signal("unlocked"), "сигнал unlocked")


func test_s6_partner_csv_matches_config() -> void:
	var lines := FileAccess.get_file_as_string("res://steam/partner/achievements.csv").strip_edges().split("\n")
	check(lines[0] == "api,name_en,desc_en,name_ru,desc_ru,hidden", "заголовок csv")
	var defs := _defs()
	check(lines.size() == defs.size() + 1, "строк csv: %d" % lines.size())
	for i in defs.size():
		check(lines[i + 1].begins_with(String(defs[i].api) + ","), "порядок csv " + defs[i].api)
