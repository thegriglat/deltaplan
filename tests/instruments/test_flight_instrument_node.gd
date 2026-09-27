extends Node
## Планшет: 4 страницы, сигналы page_changed и settings_requested, текстура нужного размера.

var failures: PackedStringArray = []
var _pages: Array[int] = []
var _settings: Array = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_pages_and_signals() -> void:
	var fi: FlightInstrument = load("res://scenes/instruments/flight_instrument.tscn").instantiate()
	add_child(fi)
	check(fi.page_count() == 5, "5 страниц")
	fi.page_changed.connect(func(p: int) -> void: _pages.append(p))
	fi.settings_requested.connect(func(k: String, v: Variant) -> void: _settings.append([k, v]))
	for i in 5:
		fi.set_page(i)
	fi.set_page(1)
	fi.set_page(1)
	check(_pages == [1, 2, 3, 4, 1], "page_changed только при смене: %s" % str(_pages))
	fi.set_page(6)
	check(fi.get_page() == 1, "номер по модулю числа страниц")
	fi.request_setting("vario_volume_db", -3.0)
	check(_settings.size() == 1 and _settings[0][0] == "vario_volume_db", "settings_requested")
	var scr: Dictionary = Config.get_config("instruments").screen
	var sz := fi.viewport.size
	check(sz == Vector2i(int(scr.width_px), int(scr.height_px)), "разрешение из конфига: %s" % sz)
	fi.set_task([{"name": "А", "position": Vector3(1000, 0, 0), "radius_m": 200.0}])
	check(fi.get_task().has_target(), "задание выставлено")
	fi.set_task_state({"phase": "pre_start", "instrument_active": 0, "time_to_start_s": 300.0})
	check(fi.get_task().is_race(), "состояние гонки принято")
	fi.set_task_state({})
	check(not fi.get_task().is_race(), "пустое состояние — гонки нет")
	var t := Telemetry.new()
	fi.update(t, 1.0 / 120.0)
	fi.free()


func test_instrument_3d_screen() -> void:
	var i3: Instrument3D = load("res://scenes/instruments/instrument_3d.tscn").instantiate()
	add_child(i3)
	check(i3.screen_mesh != null, "меш экрана найден (модель или примитив)")
	var mat := i3.screen_mesh.material_override as StandardMaterial3D
	if mat == null:
		mat = (i3.screen_mesh.mesh as QuadMesh).material as StandardMaterial3D
	check(mat != null and mat.albedo_texture != null, "текстура экрана назначена")
	i3.free()


func test_vario_90s_display() -> void:
	var v9: VarioDisplay90s = load("res://scenes/instruments/vario_90s.tscn").instantiate()
	add_child(v9)
	var c: Dictionary = Config.get_config("instruments").vario90s
	check(v9.viewport.size == Vector2i(int(c.width_px), int(c.height_px)), "размер экрана 90-х")
	check(v9.get_texture() != null, "текстура есть")
	check(
		(
			absf(
				v9.get_vario().get_filter_time_constant_s() - float(c.vario.filter_time_constant_s)
			)
			< 1e-6
		),
		"свой фильтр датчика"
	)
	var t := Telemetry.new()
	t.vario = 2.0
	for i in 240:
		v9.update(t, 1.0 / 120.0)
	check(v9.get_vario().vario_ms > 1.0, "показания обновляются")
	v9.free()


func test_vario_audio_presets() -> void:
	var va := VarioAudio.new()
	add_child(va)
	check(va.get_preset() == "classic_90s", "по умолчанию — классический")
	va.set_volume_db(-12.0)
	va.set_vario(1.5)
	va.set_preset("xctracer")
	check(va.get_preset() == "xctracer", "пресет сменился")
	check(absf(va.player.volume_db + 12.0) < 1e-3, "громкость сохранилась")
	check(absf(va.synth.get_target_vario() - 1.5) < 1e-6, "показание сохранилось")
	check(va.get_preset_names().size() >= 2, "список пресетов")
	va.set_thresholds(0.3, -2.0)
	check(absf(float(va.get_settings().climb_on_ms) - 0.3) < 1e-6, "порог писка изменён")
	va.free()
