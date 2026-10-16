extends Node
## GL-4: список целей (GoalList) и блок целей на экране итога (ResultScreen.lines_for).

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _item(kind: String, value: float, status := "pending", cur := 0.0, best := 0.0) -> Dictionary:
	return {"kind": kind, "value": value, "task_name": "", "status": status, "current": cur, "best": best, "reason": ""}


func test_rows_icons_and_numbers() -> void:
	var rows := GoalList.rows(
		[
			_item("height", 300.0, "pending", 120.0, 0.0),
			_item("duration", 600.0, "done", 600.0),
			_item("distance", 5000.0, "failed", 0.0, 1200.0),
			_item("landing", 50.0, "unavailable"),
		]
	)
	check(rows.size() == 4, "строка на цель")
	check(rows[0].begins_with("○") and rows[0].contains("300") and rows[0].contains("120"), rows[0])
	check(rows[1].begins_with("✓") and rows[1].contains("10:00"), rows[1])
	check(rows[2].begins_with("✗") and rows[2].contains("5.0") and rows[2].contains("1.2"), rows[2])
	check(rows[3].begins_with("—"), rows[3])


func test_route_progress_and_name() -> void:
	var it := _item("route", 0.0, "pending", 0.0, 8000.0)
	it.task_name = "Тестовый маршрут"
	check(GoalList.row_text(it).contains("Тестовый маршрут"), "имя маршрута")
	check(not GoalList.row_text(it).contains("·"), "маршрут не начат — без остатка")
	var it2 := _item("triangle", 6000.0, "pending", 1.0, 3500.0)
	check(GoalList.row_text(it2).contains("3.5"), "остаток: " + GoalList.row_text(it2))


func test_layer_visibility() -> void:
	var l := GoalList.new()
	add_child(l)
	var tr := GoalTracker.new()
	tr.setup([GoalSpec.make("duration", "custom", 60.0)], {"start_pos": Vector3.ZERO})
	l.set_tracker(tr)
	check(not l.is_shown(), "до set_active скрыт")
	l.set_active(true)
	check(l.is_shown(), "активен — виден")
	check(l.lines().size() == 1, "строка")
	l.set_active(false)
	check(not l.is_shown(), "неактивен — скрыт")
	l.set_tracker(null)
	l.set_active(true)
	check(not l.is_shown(), "без трекера скрыт")
	l.free()


func test_result_lines() -> void:
	var info := {
		"grade": "soft",
		"goals":
		{
			"done": 1,
			"total": 2,
			"goals": [_item("duration", 60.0, "done", 61.0), _item("distance", 5000.0, "failed", 0.0, 800.0)],
			"route": {},
		},
		"new_records": {"flight_time_s": {"value": 125.0, "previous": 90.0}, "distance_m": {"value": 2500.0, "previous": null}},
	}
	var text := "\n".join(ResultScreen.lines_for("landed", info))
	check(text.contains("1") and text.contains("2"), "итог n из m")
	check(text.contains("✓") and text.contains("✗"), "значки целей")
	check(text.contains("2:05") and text.contains("1:30"), "рекорд времени и прошлое: " + text)
	check(text.contains("2.5"), "рекорд дальности")
	var plain := ResultScreen.lines_for("landed", {"grade": "soft"})
	check(not "\n".join(plain).contains("✓"), "без целей блока нет")
