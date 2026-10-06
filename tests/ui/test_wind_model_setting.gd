extends Node
## Пункт настроек «Ветер над рельефом» (air-phase P12 v3: на GPU / без GPU): пишется в
## atmosphere.json → air_model.enabled (auto / cpu); «без GPU» — фазы на CPU, RenderingDevice не
## берётся, но поле есть и атмосфера его использует (аналитика — не пункт меню). Настройки пишутся
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


## Тексты пунктов, как их видит пилот: после перевода (локаль ru и en), порядок и подписи.
func test_wind_model_item_texts_ui() -> void:
	var dir := ProjectSettings.globalize_path("res://.godot/test_wind_model_texts")
	DirAccess.make_dir_recursive_absolute(dir)
	var old := TranslationServer.get_locale()
	var want := {
		"ru":
		[
			"Расчёт на GPU (фазы + Пикар)",
			"Без GPU (фазы на CPU)"
		],
		"en":
		[
			"GPU computation (phases + Picard)",
			"Without GPU (phases on CPU)"
		],
	}
	for loc in want:
		TranslationServer.set_locale(loc)
		var sp := _panel(dir)
		var opt: OptionButton = sp.get("_wind_model")
		var got: Array = []
		for i in opt.item_count:
			got.append(opt.get_item_text(i))
		check(got == want[loc], "UI %s: %s" % [loc, got])
		sp.queue_free()
	TranslationServer.set_locale(old)
	DirAccess.remove_absolute(dir)


func test_setting_saved_and_applied() -> void:
	var dir := ProjectSettings.globalize_path(
		"res://.godot/test_wind_model_%d" % OS.get_process_id()
	)
	DirAccess.make_dir_recursive_absolute(dir)
	var sp := _panel(dir)
	var opt: OptionButton = sp.get("_wind_model")
	check(opt != null and opt.item_count == 2, "в настройках два варианта модели ветра")
	var want := ["Расчёт на GPU (фазы + Пикар)", "Без GPU (фазы на CPU)"]
	var got: Array = []
	for i in opt.item_count:
		got.append(opt.get_item_text(i))
	check(got == want, "порядок и тексты: %s" % [got])
	check(opt.get_item_id(0) == 0 and opt.get_item_id(1) == 1, "id пунктов")
	check(opt.get_selected_id() == 0 and opt.selected == 0, "по умолчанию — расчёт, первый пункт")
	# без GPU
	opt.select(opt.get_item_index(1))
	check(sp.save(), "сохранилось (без GPU)")
	var saved := UserSettings.read_json(UserSettings.local_dir(dir).path_join("atmosphere.json"))
	check(saved.get("air_model", {}).get("enabled") == "cpu", "записан enabled=cpu")
	_check_mode(_atmo_cfg(saved), false)
	# расчёт
	opt.select(opt.get_item_index(0))
	check(sp.save(), "сохранилось (расчёт)")
	saved = UserSettings.read_json(UserSettings.local_dir(dir).path_join("atmosphere.json"))
	check(saved.get("air_model", {}).get("enabled") == "auto", "записан enabled=auto")
	check(not saved.get("air_model", {}).has("engine"), "ключа engine нет (P12)")
	_check_mode(_atmo_cfg(saved), true)
	sp.queue_free()
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir)
	# машинные ключи (S7) лежат в соседнем local/configs
	var ld := UserSettings.local_dir(dir)
	DirAccess.remove_absolute(ld.path_join("atmosphere.json"))
	Config.reload()


## Панель показывает значение из Config.
func test_panel_shows_saved_value() -> void:
	var dir := ProjectSettings.globalize_path("res://.godot/test_wind_model_show")
	DirAccess.make_dir_recursive_absolute(dir)
	Config._cache["atmosphere"] = _atmo_cfg({"air_model": {"enabled": "cpu"}})
	var sp := _panel(dir)
	check((sp.get("_wind_model") as OptionButton).get_selected_id() == 1, "cpu → «без GPU»")
	sp.queue_free()
	Config.reload()
	sp = _panel(dir)
	check((sp.get("_wind_model") as OptionButton).get_selected_id() == 0, "по умолчанию → «расчёт»")
	sp.queue_free()
	DirAccess.remove_absolute(dir)


## cfg — конфиг атмосферы с правкой пилота; gpu — «на GPU» (иначе фазы на CPU, GPU не берётся).
func _check_mode(cfg: Dictionary, gpu: bool) -> void:
	Config._cache["atmosphere"] = cfg
	var rt := AirRuntime.new()
	var why := rt.unavailable_reason()
	check(why != "air_model.enabled = off", "поле не отключено настройкой (%s)" % why)
	if not gpu:
		check(rt.gpu_reason() == "air_model.enabled = cpu", "без GPU: Пикара нет (%s)" % rt.gpu_reason())
		check(rt._device() == null, "без GPU: RenderingDevice не берётся")
		check(rt._gpu == null, "без GPU: решатель не создан")
	rt.free()
	# атмосфера: поле используется в обоих режимах
	var f := WindField.load_file(FIXTURE)
	check(f != null, "фикстура читается")
	if f != null:
		var a := Atmosphere.new()
		a.visuals_enabled = false
		a.configure(cfg, Config.get_config("weather/medium"))
		a.set_air_field(f, 0.0)
		check(a.is_air_field_on(), "поле используется")
		a.free()
	Config.reload()
