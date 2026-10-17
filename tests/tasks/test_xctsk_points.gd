extends Node
## TM-2: XctskImporter.points_latlon — координаты пунктов без push_error для проверки файла.

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_points_latlon() -> void:
	var text := FileAccess.get_file_as_string("res://tests/goals/data/ongudai_sample.xctsk")
	var pts := XctskImporter.points_latlon(text)
	check(pts.size() == 3, "три пункта: %d" % pts.size())
	check(pts.size() == 3 and absf(pts[1].x - 50.82) < 1e-6, "широта второго пункта")


func test_points_latlon_bad() -> void:
	check(XctskImporter.points_latlon("XCTSK:abc").is_empty(), "QR-формат не разбирается")
	check(XctskImporter.points_latlon('{"turnpoints": []}').is_empty(), "нет пунктов")
	check(XctskImporter.points_latlon('{"turnpoints": [{"radius": 1}]}').is_empty(), "нет waypoint")
