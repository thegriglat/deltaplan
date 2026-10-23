class_name DeviceLossClassifier
extends RefCounted
## Прототип CR-11: по строкам журнала движка (Godot 4.7.2) определить, что устройство GPU потеряно,
## и что известно о причине. Чистая логика, без доступа к GPU. Для CR-К2 v2 (GpuLossLogger).
## Коды HRESULT — DXGI (Microsoft Learn, "DXGI_ERROR"); тексты — drivers/d3d12, drivers/vulkan 4.7.2-stable.

## код -> [имя, причина известна?, смысл]
const HRESULTS := {
	"0x887a0005": ["DXGI_ERROR_DEVICE_REMOVED", false, "состояние «устройство удалено»; причину даёт только GetDeviceRemovedReason"],
	"0x887a0006": ["DXGI_ERROR_DEVICE_HUNG", true, "зависание GPU (таймаут TDR или сбой команды)"],
	"0x887a0007": ["DXGI_ERROR_DEVICE_RESET", true, "устройство сброшено (ошибка выполнения команд / TDR)"],
	"0x887a0020": ["DXGI_ERROR_DRIVER_INTERNAL_ERROR", true, "внутренняя ошибка драйвера"],
	"0x887a0001": ["DXGI_ERROR_INVALID_CALL", true, "неверный вызов приложения (не потеря устройства сама по себе)"],
}
## Следствия потери (на удалённом устройстве Reset/Close возвращают E_INVALIDARG/E_FAIL) — не причина.
const AFTERMATH := ["0x80070057", "0x80004005"]


## Строка журнала -> {} (не про потерю) или {api, code, name, reason_known, note}.
static func classify_line(line: String) -> Dictionary:
	var low := line.to_lower()
	for code in HRESULTS:
		if low.contains(code):
			var h: Array = HRESULTS[code]
			if code == "0x887a0001":
				continue
			return {"api": "d3d12", "code": code, "name": h[0], "reason_known": h[1], "note": h[2]}
	if low.contains("vk_error_device_lost") or low.contains("vulkan device was lost"):
		return {"api": "vulkan", "code": "VK_ERROR_DEVICE_LOST", "name": "VK_ERROR_DEVICE_LOST", "reason_known": false,
			"note": "потеря устройства Vulkan (TDR, сбой драйвера или железа); детали — только из VK_EXT_device_fault"}
	if low.contains("report from vk_ext_device_fault"):
		return {"api": "vulkan", "code": "VK_EXT_device_fault", "name": "device_fault_report", "reason_known": true,
			"note": "драйвер дал отчёт о сбое (Description/Vendor infos/Addresses)"}
	if low.contains("vk_ext_device_fault not available"):
		return {"api": "vulkan", "code": "no_device_fault", "name": "device_fault_unavailable", "reason_known": false,
			"note": "драйвер не поддерживает VK_EXT_device_fault"}
	return {}


## Весь журнал -> итог: {lost, api, first, reason_known, aftermath, line}. line — одна строка для отчёта.
static func summarize(log_text: String) -> Dictionary:
	var out := {"lost": false, "api": "", "first": {}, "reason_known": false, "aftermath": 0, "line": ""}
	for raw in log_text.split("\n"):
		var c := classify_line(raw)
		if not c.is_empty():
			if not out["lost"]:
				out["lost"] = true
				out["api"] = c["api"]
				out["first"] = c
			if c["reason_known"]:
				out["reason_known"] = true
				if not out["first"].get("reason_known", false):
					out["first"] = c
		else:
			for a in AFTERMATH:
				if raw.to_lower().contains(a):
					out["aftermath"] += 1
					break
	if out["lost"]:
		var f: Dictionary = out["first"]
		out["line"] = "GPU потерян (%s): %s%s" % [
			out["api"], f["name"], "" if out["reason_known"] else " — причина не получена"]
	return out
