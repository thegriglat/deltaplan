extends TestCase
## Локальные рекорды (FR-37): новые рекорды, сохранение и чтение.

const PATH := "user://test_tasks_tmp/records.json"


func _fresh() -> FlightRecords:
	if FileAccess.file_exists(PATH):
		DirAccess.remove_absolute(PATH)
	return FlightRecords.new(PATH)


func _flight(time_s: float, dist_m: float, alt_m: float) -> Dictionary:
	return {
		"location": "altai",
		"wing": "sport",
		"flight_time_s": time_s,
		"distance_m": dist_m,
		"max_altitude_msl_m": alt_m
	}


func test_first_flight_sets_all_records() -> void:
	var rec := _fresh()
	var got := rec.add_flight(_flight(600.0, 5000.0, 1500.0))
	check(
		got.has("flight_time_s") and got.has("distance_m") and got.has("max_altitude_msl_m"),
		"все три рекорда: %s" % [got.keys()]
	)
	check(got.flight_time_s.previous == null, "прошлого рекорда нет")


func test_only_improvements_count() -> void:
	var rec := _fresh()
	rec.add_flight(_flight(600.0, 5000.0, 1500.0))
	var got := rec.add_flight(_flight(500.0, 7000.0, 1400.0))
	check(got.keys() == ["distance_m"], "только дальность: %s" % [got.keys()])
	approx(float(got.distance_m.previous), 5000.0, 0.01, "прошлый рекорд")
	var other := rec.add_flight(
		{
			"location": "altai",
			"wing": "training",
			"flight_time_s": 100.0,
			"distance_m": 100.0,
			"max_altitude_msl_m": 100.0
		}
	)
	check(other.size() == 3, "другое крыло — свои рекорды")


func test_saved_and_loaded() -> void:
	var rec := _fresh()
	rec.add_flight(_flight(600.0, 5000.0, 1500.0))
	var again := FlightRecords.new(PATH)
	var r := again.free_records("altai", "sport")
	approx(float(r.distance_m.value), 5000.0, 0.01, "дальность прочитана")
	approx(float(again.get_record("free|altai|sport", "flight_time_s").value), 600.0, 0.01, "время")


func test_short_flight_ignored() -> void:
	var rec := _fresh()
	check(rec.add_flight(_flight(3.0, 50.0, 1100.0)).is_empty(), "срыв на старте — не рекорд")


func test_task_records() -> void:
	var rec := _fresh()
	var f := _flight(3600.0, 4000.0, 1600.0)
	var task := {
		"task_id": "ongudai_demo",
		"made_goal": true,
		"speed_section_time_s": 3000.0,
		"distance_m": 27000.0,
	}
	f["task"] = task
	var got := rec.add_flight(f)
	check(got.has("task_speed_section_time_s") and got.has("task_distance_m"), "рекорды задания")
	approx(
		float(rec.free_records("altai", "sport").distance_m.value),
		4000.0,
		0.01,
		"дальность свободного полёта не путается с дистанцией задания"
	)
	task.speed_section_time_s = 3200.0
	check(not rec.add_flight(f).has("task_speed_section_time_s"), "медленнее — не рекорд")
	task.speed_section_time_s = 2800.0
	check(rec.add_flight(f).has("task_speed_section_time_s"), "быстрее — рекорд")
	task.speed_section_time_s = 100.0
	task.made_goal = false
	check(not rec.add_flight(f).has("task_speed_section_time_s"), "без гоула время не идёт")
	var best: Dictionary = rec.task_records("ongudai_demo", "sport")
	approx(float(best.speed_section_time_s.value), 2800.0, 0.01, "лучшее время")
