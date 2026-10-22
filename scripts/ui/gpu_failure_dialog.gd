class_name GpuFailureDialog
extends ConfirmationDialog
## Окно «видеокарта перестала отвечать» (CR-К3 v2): после обрыва на стадии wind или отказа GPU.
## Варианты по порядку: сменить драйвер и перезапустить (рекомендуется; на Linux пункта нет),
## «Безопасная графика» (GpuSafety), попробовать снова (ничего не меняет). Выбор сохраняется.

signal choice_made(choice: String)

const SWITCH := "switch"
const SAFE := "safe"
const RETRY := "retry"

var _driver: String
var _alt: String
var _config_dir: String
var _chosen := false


## driver — текущий драйвер, alt — предлагаемый ("" — нет), dir — каталог user-конфигов.
func setup(driver: String, alt: String, dir: String = UserSettings.DEFAULT_DIR) -> void:
	_driver = driver
	_alt = alt
	_config_dir = dir
	title = tr("gpu_fail_title")
	dialog_autowrap = true
	min_size = Vector2i(560, 0)
	dialog_text = text_for(driver, alt)
	exclusive = true
	get_ok_button().hide()  # свои кнопки: порядок и подписи задаём сами
	get_cancel_button().hide()
	if alt != "":
		var b := add_button(tr("gpu_fail_switch") % _label(alt), false, SWITCH)
		b.grab_focus()
	add_button(tr("gpu_fail_safe"), false, SAFE)
	add_button(tr("gpu_fail_retry"), false, RETRY)
	custom_action.connect(_on_action)
	canceled.connect(_finish.bind(RETRY))


static func text_for(driver: String, alt: String) -> String:
	var t: String = TranslationServer.translate("gpu_fail_text") % _label(driver)
	if alt != "":
		return t + "\n\n" + TranslationServer.translate("gpu_fail_recommend") % _label(alt)
	return t + "\n\n" + TranslationServer.translate("gpu_fail_update")


static func _label(driver: String) -> String:
	return {"vulkan": "Vulkan", "d3d12": "DirectX 12", "metal": "Metal", "opengl3": "OpenGL"}.get(
		driver, driver
	)


func _on_action(action: StringName) -> void:
	_finish(String(action))


func _finish(choice: String) -> void:
	if _chosen:
		return
	_chosen = true
	match choice:
		SWITCH:
			RenderDriver.save(_alt, _config_dir)
			RenderDriver.restart(get_tree())
		SAFE:
			GpuSafety.apply_safe(GpuSafety.CRASH, _config_dir)
	choice_made.emit(choice)
	hide()
	queue_free()
