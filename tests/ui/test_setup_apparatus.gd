extends Node
## PD-К3 v2: вкладка «Аппарат» — значения по крылу; смена крыла показывает его значения.

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_apparatus_per_wing() -> void:
	var m: FlightSetupScreen = (load("res://scenes/ui/flight_setup_screen.tscn") as PackedScene).instantiate()
	add_child(m)
	var s := FlightSettings.defaults()
	s.wing = "wings/sport"
	s.apparatus = {"sport": {"hang_shift_cm": 2.0}}
	m.set_settings(s)
	var app: Dictionary = m.get("_apparatus")
	check(is_equal_approx((app.hang_shift_cm as HSlider).value, 2.0), "sport: сохранённое значение")
	check(is_equal_approx((app.dihedral_eff_deg as HSlider).max_value, 6.0), "Поперечное V до +6")
	# пилот двигает ползунок sport
	(app.hang_length_m as HSlider).value = 1.3
	# другое крыло: свои значения (не sport-овые)
	var other := "wings/training"
	m.call("_select_wing", other)
	check(is_equal_approx((app.hang_shift_cm as HSlider).value, FlightSettings.apparatus_defaults("training").hang_shift_cm), "training: умолчание крыла")
	(app.sail_flex as HSlider).value = 0.9
	# обратно на sport — его значения
	m.call("_select_wing", "wings/sport")
	check(is_equal_approx((app.hang_shift_cm as HSlider).value, 2.0), "sport: вернулось 2.0")
	check(is_equal_approx((app.hang_length_m as HSlider).value, 1.3), "sport: вернулось 1.3")
	var r: FlightSettings = m.call("_collect")
	if true:
		check(r.apparatus.get("training", {}).get("sail_flex", 0.0) == 0.9, "training: записано 0.9")
		check(not r.apparatus.get("training", {}).has("hang_shift_cm"), "training: нетронутое не записано")
	m.queue_free()
