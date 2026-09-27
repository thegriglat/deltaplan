extends Node
## «Густота травы» в настройках: по умолчанию — из пресета графики, слайдер переопределяет,
## пишется в vegetation.json → grass.density_pct. Настройки пишутся во временный каталог
## (SettingsPanel.config_dir), настоящий user://configs не трогаем.

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_grass_density_saved_and_applied() -> void:
	var dir := ProjectSettings.globalize_path(
		"res://.godot/test_grass_density_%d" % OS.get_process_id()
	)
	DirAccess.make_dir_recursive_absolute(dir)
	var sp: SettingsPanel = (
		(load("res://scenes/ui/settings_panel.tscn") as PackedScene).instantiate()
	)
	sp.config_dir = dir
	add_child(sp)
	var slider: HSlider = sp.get("_grass")
	var graphics: OptionButton = sp.get("_graphics")
	check(slider != null, "в настройках есть «Густота травы»")
	check(slider.min_value == 0.0 and slider.max_value == 200.0, "0–200 %")
	check(is_equal_approx(slider.step, 10.0), "шаг 10 %")
	# выбор пресета показывает его густоту
	var names: PackedStringArray = sp.get("_graphics_names")
	for p: String in {"low": 0.0, "medium": 100.0, "high": 150.0}:
		var i := names.find(p)
		graphics.select(i)
		graphics.item_selected.emit(i)
		var want: float = {"low": 0.0, "medium": 100.0, "high": 150.0}[p]
		check(is_equal_approx(slider.value, want), "пресет %s → %.0f%%" % [p, slider.value])
	# слайдер переопределяет пресет
	slider.value = 70.0
	check(sp.save(), "сохранилось")
	var saved := UserSettings.read_json(dir.path_join("vegetation.json"))
	var pct := float(saved.get("grass", {}).get("density_pct", -1.0))
	check(is_equal_approx(pct, 70.0), "density_pct записан: %s" % pct)
	# применение: конфиг травы с правкой пилота → шаг пучков 1/√0,7
	var cfg: Dictionary = Config._deep_merge(
		Config.get_config("vegetation").get("grass", {}), saved.get("grass", {})
	)
	var k := GrassField.density_k(cfg)
	check(is_equal_approx(k, 0.7), "густота 0,7")
	var s := GrassField.spacing_for_density(float(cfg.clump_spacing_m), k)
	check(absf(s - float(cfg.clump_spacing_m) / sqrt(0.7)) < 1e-4, "шаг %.3f" % s)
	# 0 % — трава выключена
	slider.value = 0.0
	check(sp.save(), "сохранилось (0 %)")
	saved = UserSettings.read_json(dir.path_join("vegetation.json"))
	cfg = Config._deep_merge(cfg, saved.get("grass", {}))
	check(not GrassField.is_enabled(cfg), "0 % — трава выключена")
	sp.queue_free()
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir)
	Config.reload()
