extends Node
## PD-38: таблица пиков удельной силы пилота на касании (оба режима) → out/peaks.txt и stdout.
## Запуск — peaks.sh. Сценарии: ровная земля, горизонтальная 2 м/с, вертикальная 1, 2, 3,5, 5,5 м/с
## и «на брюхо»/авария (8 м/с). Расчёт — tests/flight/landing_peaks.gd.

const LP := preload("res://tests/flight/landing_peaks.gd")
const CASES := [[1.0, "1.0"], [2.0, "2.0"], [3.5, "3.5"], [5.5, "5.5"], [8.0, "belly"]]


func _ready() -> void:
	var out := PackedStringArray()
	for mode: String in ["ws", "pend"]:
		for c: Array in CASES:
			var s := LP.line(mode, c[1], LP.run(mode, c[0]))
			print(s)
			out.append(s)
	var path := OS.get_environment("PD38_OUT")
	if path == "":
		path = ProjectSettings.globalize_path("res://tools/research/pendulum/pd38/out/peaks.txt")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("\n".join(out) + "\n")
	f.close()
	get_tree().quit(0)
