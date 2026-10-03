extends Node
## Пункт настроек «Ветер над рельефом» (расчёт / упрощённый): пишется в atmosphere.json →
## air_model.enabled (auto / off); «упрощённый» — решатель не создаётся (AirRuntime, RenderingDevice
## не берётся), поле не используется атмосферой; «расчёт» — прежнее поведение. Настройки пишутся
## во временный каталог (SettingsPanel.config_dir), настоящий user://configs не трогаем.

var failures: PackedStringArray = []

const FIXTURE := "res://tests/atmosphere/fixtures/air_model/field/kayancha_w100_h13_U3_d180"


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


func _atmo_cfg(saved: Dictionary) -> Dictionary:
	return Config._deep_merge(Config.get_config("atmosphere"), saved)


func test_setting_saved_and_applied() -> void:
	var dir := ProjectSettings.globalize_path(
		"res://.godot/test_wind_model_%d" % OS.get_process_id()
	)
	DirAccess.make_dir_recursive_absolute(dir)
	var sp := _panel(dir)
	var opt: OptionButton = sp.get("_wind_model")
	check(opt != null and opt.item_count == 3, "в настройках три варианта модели ветра")
	check(opt.selected == 0, "по умолчанию — расчёт")
	# упрощённый
	opt.select(1)
	check(sp.save(), "сохранилось (упрощённый)")
	var saved := UserSettings.read_json(dir.path_join("atmosphere.json"))
	check(saved.get("air_model", {}).get("enabled") == "off", "записан enabled=off")
	_check_mode(_atmo_cfg(saved), false)
	# нейросеть
	opt.select(2)
	check(sp.save(), "сохранилось (нейросеть)")
	saved = UserSettings.read_json(dir.path_join("atmosphere.json"))
	var am: Dictionary = saved.get("air_model", {})
	check(am.get("enabled") == "auto" and am.get("engine") == "nn", "записаны auto + nn")
	Config._cache["atmosphere"] = _atmo_cfg(saved)
	var rt := AirRuntime.new()
	check(rt.engine() == "nn", "AirRuntime: engine nn")
	check(rt.unavailable_reason() != "air_model.enabled = off", "нейросеть: не отключена")
	check(rt._device() == null, "нейросеть: GPU не берётся")
	rt.free()
	Config.reload()
	# расчёт
	opt.select(0)
	check(sp.save(), "сохранилось (расчёт)")
	saved = UserSettings.read_json(dir.path_join("atmosphere.json"))
	check(saved.get("air_model", {}).get("enabled") == "auto", "записан enabled=auto")
	check(saved.get("air_model", {}).get("engine") == "solver", "записан engine=solver")
	_check_mode(_atmo_cfg(saved), true)
	sp.queue_free()
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir)
	Config.reload()


## Панель показывает значение из Config.
func test_panel_shows_saved_value() -> void:
	var dir := ProjectSettings.globalize_path("res://.godot/test_wind_model_show")
	DirAccess.make_dir_recursive_absolute(dir)
	Config._cache["atmosphere"] = _atmo_cfg({"air_model": {"enabled": "off"}})
	var sp := _panel(dir)
	check((sp.get("_wind_model") as OptionButton).selected == 1, "off → «упрощённый»")
	sp.queue_free()
	Config._cache["atmosphere"] = _atmo_cfg({"air_model": {"enabled": "auto", "engine": "nn"}})
	sp = _panel(dir)
	check((sp.get("_wind_model") as OptionButton).selected == 2, "nn → «нейросеть»")
	sp.queue_free()
	Config.reload()
	sp = _panel(dir)
	check((sp.get("_wind_model") as OptionButton).selected == 0, "по умолчанию → «расчёт»")
	sp.queue_free()
	DirAccess.remove_absolute(dir)


## cfg — конфиг атмосферы с правкой пилота; calc — «расчёт» (иначе решатель не создаётся).
func _check_mode(cfg: Dictionary, calc: bool) -> void:
	Config._cache["atmosphere"] = cfg
	var rt := AirRuntime.new()
	var why := rt.unavailable_reason()
	if calc:
		check(why != "air_model.enabled = off", "расчёт: не отключён настройкой (%s)" % why)
	else:
		check(why == "air_model.enabled = off", "упрощённый: решатель отключён (%s)" % why)
		check(rt._device() == null, "упрощённый: RenderingDevice не берётся")
		check(rt._gpu == null, "упрощённый: решатель не создан")
	rt.free()
	# атмосфера: поле используется только в режиме «расчёт»
	var f := WindField.load_file(FIXTURE)
	check(f != null, "фикстура читается")
	if f != null:
		var a := Atmosphere.new()
		a.visuals_enabled = false
		a.configure(cfg, Config.get_config("weather/medium"))
		a.set_air_field(f, 0.0)
		check(a.is_air_field_on() == calc, "поле используется: %s" % calc)
		a.free()
	Config.reload()
