extends Node
## Рубильники GPU-нагрузки (CR-К4): display.gpu.* читает GraphicsPresets.gpu_effect; тень солнца и
## свечение — в SkyEnvironment; панель настроек показывает галочки и пишет их в машинные настройки
## (во временный каталог SettingsPanel.config_dir, настоящий user:// не трогаем).

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _panel(dir: String) -> SettingsPanel:
	var sp: SettingsPanel = (
		(load("res://scenes/ui/settings_panel.tscn") as PackedScene).instantiate()
	)
	sp.config_dir = dir
	add_child(sp)
	return sp


func _clean(dir: String) -> void:
	for d: String in [dir, UserSettings.local_dir(dir)]:
		if not DirAccess.dir_exists_absolute(d):
			continue
		for f in DirAccess.get_files_at(d):
			DirAccess.remove_absolute(d.path_join(f))
		DirAccess.remove_absolute(d)
	Config.reload()


func test_defaults_on() -> void:
	var keys: Dictionary = Config.get_config("game").display.gpu
	for k: String in ["sun_shadows", "cloud_shadows", "glow"]:
		check(keys.get(k) == true, "в конфиге по умолчанию включено: " + k)
		check(GraphicsPresets.gpu_effect(k), "gpu_effect: " + k)
	var env := SkyEnvironment.new()
	env.apply_config()
	check(env.sun.shadow_enabled, "по умолчанию тень солнца есть")
	env.free()


func test_sky_follows_toggles() -> void:
	var saved: Dictionary = Config._cache.get("game", {}).duplicate(true)
	Config._cache["game"] = Config._deep_merge(
		Config.get_config("game"), {"display": {"gpu": {"sun_shadows": false, "glow": false}}}
	)
	check(not GraphicsPresets.gpu_effect("sun_shadows"), "sun_shadows выключен")
	check(GraphicsPresets.gpu_effect("cloud_shadows"), "остальные не затронуты")
	var env := SkyEnvironment.new()
	env.apply_config()
	check(not env.sun.shadow_enabled, "тени солнца нет")
	check(not env.world_env.environment.glow_enabled, "свечения нет")
	env.free()
	Config._cache["game"] = saved


func test_panel_saves_toggles() -> void:
	var dir := ProjectSettings.globalize_path("res://.godot/test_gpu_toggles_%d" % OS.get_process_id())
	DirAccess.make_dir_recursive_absolute(dir)
	var sp := _panel(dir)
	var tg: Dictionary = sp.get("_gpu_toggles")
	var simple: CheckBox = sp.get("_simple_clouds")
	for k: String in ["sun_shadows", "cloud_shadows", "glow"]:
		check(tg.has(k) and (tg[k] as CheckBox).button_pressed, "галочка есть и включена: " + k)
	check(not simple.button_pressed, "простые облака по умолчанию выключены")
	(tg["sun_shadows"] as CheckBox).button_pressed = false
	simple.button_pressed = true
	check(sp.save(), "сохранилось")
	var g := UserSettings.read_json(UserSettings.local_dir(dir).path_join("game.json"))
	var gpu: Dictionary = g.get("display", {}).get("gpu", {})
	check(gpu.get("sun_shadows") == false, "записан sun_shadows=false: %s" % [gpu])
	check(gpu.get("cloud_shadows") == true and gpu.get("glow") == true, "остальные true")
	var a := UserSettings.read_json(UserSettings.local_dir(dir).path_join("atmosphere.json"))
	check(a.get("clouds", {}).get("renderer") == "boxes", "clouds.renderer=boxes")
	# снять галочку — обратно auto
	simple.button_pressed = false
	check(sp.save(), "сохранилось (облака обычные)")
	a = UserSettings.read_json(UserSettings.local_dir(dir).path_join("atmosphere.json"))
	check(a.get("clouds", {}).get("renderer") == "auto", "clouds.renderer=auto")
	sp.queue_free()
	_clean(dir)


func test_panel_shows_saved() -> void:
	var dir := ProjectSettings.globalize_path("res://.godot/test_gpu_toggles_show")
	DirAccess.make_dir_recursive_absolute(dir)
	var saved: Dictionary = Config._cache.get("game", {}).duplicate(true)
	Config._cache["game"] = Config._deep_merge(
		Config.get_config("game"), {"display": {"gpu": {"glow": false}}}
	)
	Config._cache["atmosphere"] = Config._deep_merge(
		Config.get_config("atmosphere"), {"clouds": {"renderer": "boxes"}}
	)
	var sp := _panel(dir)
	var tg: Dictionary = sp.get("_gpu_toggles")
	check(not (tg["glow"] as CheckBox).button_pressed, "glow=false показан")
	check((tg["sun_shadows"] as CheckBox).button_pressed, "sun_shadows=true показан")
	check((sp.get("_simple_clouds") as CheckBox).button_pressed, "boxes → простые облака включены")
	sp.queue_free()
	Config._cache["game"] = saved
	_clean(dir)
