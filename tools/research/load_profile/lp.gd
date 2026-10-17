class_name LP
extends RefCounted
## Замер загрузки (tools/research/load_profile): метки времени вокруг вызовов во временной копии.
## Строка лога: [lp] <метка> <мс> @<с от старта процесса>.


static func t() -> int:
	return Time.get_ticks_usec()


static func e(label: String, t0: int) -> void:
	var now := Time.get_ticks_usec()
	print("[lp] %s %.1f @%.3f" % [label, (now - t0) / 1000.0, now / 1e6])


## Вызвать c и замерить; вернуть результат.
static func w(label: String, c: Callable) -> Variant:
	var t0 := Time.get_ticks_usec()
	var r: Variant = c.call()
	e(label, t0)
	return r


static func n(label: String, value: Variant) -> void:
	print("[lpn] %s %s" % [label, str(value)])
