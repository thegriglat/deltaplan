extends Node
## «Масштаб рендера» (настройки, независимо от пресета) и пресет «Низкое» — FSR 1:
## пишутся в user://configs/game.json, применяются к viewport (scaling_3d_mode/scaling_3d_scale)
## сразу через GraphicsPresets.apply_viewport (game.gd вызывает это при закрытии настроек).
## Пишем в настоящий user://configs (Config читает только его) — как test_helmet_fov.gd — но
## КАЖДЫЙ раз полностью перезаписываем game.json (не патчим поверх старого), чтобы тест не зависел
## от того, что там уже сохранил пилот (например render_scale_auto=false с прошлого раза), и
## восстанавливаем исходное содержимое в конце.

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_low_preset_uses_fsr_0_75() -> void:
	var path := UserSettings.DEFAULT_DIR.path_join("game.json")
	var backup := FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""

	# Полная перезапись (не патч): только сам пресет, render_scale_auto — по умолчанию (true),
	# чтобы не зависеть от того, что уже могло быть сохранено в реальном user-конфиге.
	_write(path, {"graphics": "low"})
	Config.reload()

	var vp := SubViewport.new()
	add_child(vp)
	GraphicsPresets.apply_viewport(vp)
	check(vp.scaling_3d_mode == Viewport.SCALING_3D_MODE_FSR, "низкое: режим FSR")
	check(
		is_equal_approx(vp.scaling_3d_scale, 0.75),
		"низкое: масштаб 0.75, был %.3f" % vp.scaling_3d_scale
	)
	vp.queue_free()

	_restore(path, backup)
	Config.reload()


func test_render_scale_saved_and_applied_over_preset() -> void:
	var path := UserSettings.DEFAULT_DIR.path_join("game.json")
	var backup := FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""

	# Полная перезапись: пресет без масштабирования и render_scale_auto=true — чтобы проверить
	# именно независимый оверрайд, без влияния прежних значений в реальном user-конфиге.
	_write(path, {"graphics": "medium"})
	Config.reload()

	var sp: SettingsPanel = (
		(load("res://scenes/ui/settings_panel.tscn") as PackedScene).instantiate()
	)
	add_child(sp)
	var auto: CheckBox = sp.get("_render_scale_auto")
	var slider: HSlider = sp.get("_render_scale")
	check(auto != null and slider != null, "в настройках есть «Масштаб рендера»")
	auto.button_pressed = false
	slider.value = 50.0
	check(sp.save(), "сохранилось")

	var gj := UserSettings.read_json(path)
	check(not bool(gj.get("render_scale_auto", true)), "render_scale_auto записан")
	check(
		is_equal_approx(float(gj.get("render_scale_pct", 0.0)), 50.0),
		"render_scale_pct записан: %s" % gj.get("render_scale_pct")
	)

	var vp := SubViewport.new()
	add_child(vp)
	GraphicsPresets.apply_viewport(vp)
	check(vp.scaling_3d_mode == Viewport.SCALING_3D_MODE_FSR, "масштаб рендера: режим FSR")
	check(
		is_equal_approx(vp.scaling_3d_scale, 0.5),
		"масштаб рендера: 50%%, был %.3f" % vp.scaling_3d_scale
	)
	vp.queue_free()

	# 100% — без масштабирования (native), даже если пресет масштабирует.
	_write(path, {"graphics": "low"})
	Config.reload()
	slider.value = 100.0
	check(sp.save(), "сохранилось (100%)")
	var vp2 := SubViewport.new()
	add_child(vp2)
	GraphicsPresets.apply_viewport(vp2)
	check(
		vp2.scaling_3d_mode == Viewport.SCALING_3D_MODE_BILINEAR,
		"100%%: без масштабирования (bilinear)"
	)
	check(is_equal_approx(vp2.scaling_3d_scale, 1.0), "100%%: масштаб 1.0")
	vp2.queue_free()

	sp.queue_free()
	_restore(path, backup)
	Config.reload()


## Полностью перезаписать конфиг (не патч поверх старого — тест не зависит от того, что там было).
func _write(path: String, data: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(data, "  "))
		f.close()


func _restore(path: String, content: String) -> void:
	if content == "":
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
		return
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(content)
		f.close()
