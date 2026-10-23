class_name GpuLossLogger
extends Logger
## Журнал движка как второй источник отказа видеокарты (CR-К2 v2): сообщение с признаком потери
## устройства (D3D12 0x887a0005/6/7, VK_ERROR_DEVICE_LOST, отчёт VK_EXT_device_fault) →
## GpuHealth.report_failure("engine", …) и при первом срабатывании одна строка «[gpu-loss] …»
## (чтобы факт потери не терялся в хвосте лога после каскада ошибок). Вызывается из любых потоков:
## запись под Mutex, UI не трогает. Классификатор — из прототипа CR-11
## (tools/research/crash-reports/cr-11/device_loss_classifier.gd; коды DXGI — Microsoft Learn,
## тексты — drivers/d3d12 и drivers/vulkan Godot 4.7.2). Причину потери движок не запрашивает
## (на D3D12 — никогда), поэтому reason=unknown, пока не пришёл код HUNG/RESET/INTERNAL_ERROR
## или отчёт драйвера.

## Свои строки не разбираем — иначе printerr из логгера вызвал бы его самого.
const OWN_PREFIXES: PackedStringArray = ["[gpu-loss]", "GPU: отказ ресурса"]

## код -> [имя, причина известна?, смысл]
const HRESULTS := {
	"0x887a0005": ["DXGI_ERROR_DEVICE_REMOVED", false, "устройство удалено; причину даёт только GetDeviceRemovedReason"],
	"0x887a0006": ["DXGI_ERROR_DEVICE_HUNG", true, "зависание GPU (таймаут TDR или сбой команды)"],
	"0x887a0007": ["DXGI_ERROR_DEVICE_RESET", true, "устройство сброшено (ошибка команд / TDR)"],
	"0x887a0020": ["DXGI_ERROR_DRIVER_INTERNAL_ERROR", true, "внутренняя ошибка драйвера"],
}
## Следствия потери (Reset/Close на удалённом устройстве) — не причина.
const AFTERMATH: PackedStringArray = ["0x80070057", "0x80004005"]

static var _installed: GpuLossLogger
static var _mutex := Mutex.new()
static var _announced := false


## Подключить к журналу движка (один раз за процесс).
static func install() -> void:
	if _installed == null:
		_installed = GpuLossLogger.new()
		OS.add_logger(_installed)


## Для тестов: забыть, что строка «[gpu-loss]» уже была.
static func reset() -> void:
	_mutex.lock()
	_announced = false
	_mutex.unlock()


## Строка журнала -> {} (не про потерю) или {api, code, name, reason_known, loss, note}.
## loss=false — строка про диагностику (расширение недоступно), потерей не считается.
static func classify_line(line: String) -> Dictionary:
	var low := line.to_lower()
	for code: String in HRESULTS:
		if low.contains(code):
			var h: Array = HRESULTS[code]
			return {"api": "d3d12", "code": code, "name": h[0], "reason_known": h[1], "loss": true, "note": h[2]}
	if low.contains("vk_error_device_lost") or low.contains("device was lost"):
		return {"api": "vulkan", "code": "VK_ERROR_DEVICE_LOST", "name": "VK_ERROR_DEVICE_LOST",
			"reason_known": false, "loss": true, "note": "потеря устройства Vulkan"}
	if low.contains("report from vk_ext_device_fault"):
		return {"api": "vulkan", "code": "VK_EXT_device_fault", "name": "device_fault_report",
			"reason_known": true, "loss": true, "note": "драйвер дал отчёт о сбое"}
	if low.contains("vk_ext_device_fault not available"):
		return {"api": "vulkan", "code": "no_device_fault", "name": "device_fault_unavailable",
			"reason_known": false, "loss": false, "note": "драйвер не поддерживает VK_EXT_device_fault"}
	return {}


## Весь журнал -> {lost, api, first, reason_known, aftermath, line}.
static func summarize(log_text: String) -> Dictionary:
	var out := {"lost": false, "api": "", "first": {}, "reason_known": false, "aftermath": 0, "line": ""}
	for raw in log_text.split("\n"):
		if _is_own(raw):
			continue
		var c := classify_line(raw)
		if not c.is_empty() and c.loss:
			if not out.lost:
				out.lost = true
				out.api = c.api
				out.first = c
			if c.reason_known:
				out.reason_known = true
				if not out.first.reason_known:
					out.first = c
		elif c.is_empty():
			for a in AFTERMATH:
				if raw.to_lower().contains(a):
					out.aftermath += 1
					break
	if out.lost:
		out.line = "GPU потерян (%s): %s%s" % [
			out.api, out.first.name, "" if out.reason_known else " — причина не получена"]
	return out


static func _is_own(line: String) -> bool:
	for p in OWN_PREFIXES:
		if line.begins_with(p):
			return true
	return false


## Обработать одно сообщение движка; true — признак потери найден.
static func handle(text: String) -> bool:
	if text == "" or _is_own(text):
		return false
	var c := classify_line(text)
	if c.is_empty() or not c.loss:
		return false
	_mutex.lock()
	var first := not _announced
	_announced = true
	_mutex.unlock()
	var first_line := text.get_slice("\n", 0).strip_edges()
	GpuHealth.report_failure("engine", first_line)
	if first:
		printerr(
			"[gpu-loss] api=%s code=%s name=%s reason=%s"
			% [c.api, c.code, c.name, "known" if c.reason_known else "unknown"]
		)
	return true


func _log_error(
	_function: String, _file: String, _line: int, code: String, rationale: String,
	_editor_notify: bool, _error_type: int, _script_backtraces: Array
) -> void:
	if not handle(rationale):
		handle(code)


func _log_message(message: String, _error: bool) -> void:
	handle(message)
