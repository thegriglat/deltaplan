class_name GpuHealth
extends RefCounted
## Признак отказа видеокарты (контракт CR-К2, docs/contracts/crash-reports.md). Только статика.
## report_failure — пустой RID из RenderingDevice (буфер, набор uniform, конвейер, шейдер) или
## отказ sync/submit в расчёте ветра. Первый вызов — одна строка в лог, остальные — счётчик.
## Сам ничего не отключает и UI не показывает. Штатное отсутствие GPU (headless) — не отказ.

static var _mutex := Mutex.new()
static var _failed := false
static var _source := ""
static var _detail := ""
static var _count := 0
static var _time_msec := 0


static func report_failure(source: String, detail: String) -> void:
	_mutex.lock()
	_count += 1
	var first := not _failed
	if first:
		_failed = true
		_source = source
		_detail = detail
		_time_msec = Time.get_ticks_msec()
	_mutex.unlock()
	if first:
		printerr("GPU: отказ ресурса: %s: %s" % [source, detail])


static func is_failed() -> bool:
	return _failed


static func source() -> String:
	return _source


static func detail() -> String:
	return _detail


static func count() -> int:
	return _count


## Время первого отказа, Time.get_ticks_msec().
static func time_msec() -> int:
	return _time_msec


## Только для тестов.
static func reset() -> void:
	_mutex.lock()
	_failed = false
	_source = ""
	_detail = ""
	_count = 0
	_time_msec = 0
	_mutex.unlock()
