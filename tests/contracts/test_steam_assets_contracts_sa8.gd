extends TestCase
## Контракт SM-К1 v3 (docs/contracts/start-map.md), правила серверов тайлов: User-Agent, max_parallel,
## паузы после ошибок. Без сети и GPU.


func _mp() -> Dictionary:
	return Config.get_config("world").get("map_picker", {})


func test_user_agent_template() -> void:
	var ua := String(_mp().get("user_agent", ""))
	check(ua.contains("{version}"), "шаблон {version}: " + ua)
	check(ua.contains("https://github.com/thegriglat/deltaplan"), "адрес проекта")
	check(not ua.to_lower().contains("non-commercial"), "без non-commercial")


func test_osm_max_parallel() -> void:
	var osm: Dictionary = _mp().basemaps[0]
	check(osm.id == "osm" and int(osm.get("max_parallel", 0)) == 2, "osm.max_parallel == 2")


func test_pause_keys() -> void:
	check(float(_mp().get("retry_after_s", 0.0)) == 60.0, "retry_after_s 60")
	check(float(_mp().get("blocked_backoff_s", 0.0)) == 600.0, "blocked_backoff_s 600")


func test_loader_has_policy_seams() -> void:
	var l := RasterTileLoader.new()
	check(l.has_method("user_agent"), "user_agent()")
	check("http_hook" in l and "clock_hook" in l, "швы http_hook/clock_hook")
	l.free()
